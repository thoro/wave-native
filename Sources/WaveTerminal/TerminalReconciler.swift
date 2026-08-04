// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveTerminal — the absolute-byte-offset reconciler. This is the keystone of
// PROTOCOL.md §4 ("Output + backfill") and GUARDS §T ("Terminal output
// reconciliation", the highest-risk guard).
//
// The terminal "term" file is a circular 2 MB buffer. Output reaches the client
// by two paths that MUST merge into ONE ordered byte stream with no gaps and no
// duplicates:
//   1. HTTP backfill:  GET /wave/file?zoneid=<blockid>&name=term&offset=N
//      returns the file from max(N, DataStartIdx) up to Size (the file size at
//      request time, reported via the X-ZoneFileInfo `WaveFile`).
//      (`pkg/web/web.go:150-210`, clamp `pkg/filestore/blockstore.go:78-83`).
//   2. Live `blockfile` "append" events (`pkg/wps/wpstypes.go:79-92`).
//
// GUARDS §T authoritative rule, encoded below:
//   "apply the backfill bytes up to Size, then apply only buffered/live `append`
//    events whose cumulative absolute offset >= Size; discard the overlap."
//
// This type is deliberately PURE (no transport, no libghostty) so it can be
// unit-tested exhaustively with a capturing sink (see TerminalSink.swift) for
// subscribe-before-backfill overlap, >2 MB wrap, truncate, reconnect catch-up.

import Foundation
import WaveCore

/// Terminal-related constants shared across this module.
public enum TerminalConst {
    /// Legacy circular term-file size; still used by reconciler unit tests that
    /// exercise the circular clamp. The live backend now creates SEGMENTED,
    /// zstd-compressed term files with a 256MB (or unbounded) retention window
    /// (`pkg/blockcontroller/blockcontroller.go DefaultTermMaxFileSize`).
    public static let termFileMaxSize: Int64 = 2 * 1024 * 1024

    /// Bytes fetched by the mount-time TAIL backfill. Sized to overfill the
    /// ~15k-line sink at typical line lengths; the rest of the (potentially
    /// multi-hundred-MB) file is paged in on demand by the history layer.
    public static let tailBackfillBytes: Int64 = 2 * 1024 * 1024

    /// Reconnect catch-up retry budget. A catch-up that fails leaves the fresh
    /// reconciler UNLOADED, which silently buffers every future append — a
    /// permanently frozen pane — so the catch-up must retry until it loads.
    /// Bounded so a dead transport doesn't retry (and retain the controller)
    /// forever; a later reconnect starts a fresh catch-up anyway.
    public static let catchUpMaxAttempts = 20
    public static let catchUpRetryBaseMs: UInt64 = 250
    public static let catchUpRetryCapMs: UInt64 = 15_000
}

/// Merges HTTP backfill with buffered/live `blockfile` appends into a single
/// ordered byte stream, tracking an absolute byte offset (GUARDS §T).
///
/// Lifecycle (mirrors PROTOCOL.md §4 "FE order"):
///   1. Subscribe to `blockfile` FIRST. Feed every live append into `append(_:)`
///      — while `!loaded` they are buffered.
///   2. Issue the backfill GET from `startOffset`, then call
///      `applyBackfill(data:info:)`. It emits the deduplicated bytes to feed and
///      flips `loaded = true`.
///   3. Subsequent live appends through `append(_:)` are delivered contiguously.
///
/// A fresh reconciler is created per (re)connect: on reconnect, seed it with the
/// last consumed offset so the backfill catches up from exactly where we left off.
public struct TerminalReconciler {
    /// True once `applyBackfill` has run; before that, appends are buffered.
    public private(set) var loaded = false

    /// Absolute offset of the next byte to deliver to the sink. After backfill
    /// this equals the live file tail. The reconnect catch-up GET uses this.
    public private(set) var absOffset: Int64

    /// The offset we will (or did) request the backfill from. The buffered region
    /// is modeled as beginning here — see `applyBackfill` for the rationale.
    private let requestedOffset: Int64

    private var buffered: [Data] = []

    /// - Parameter startOffset: the absolute offset to backfill from. `0` for a
    ///   fresh mount; the last consumed offset for a reconnect catch-up.
    public init(startOffset: Int64 = 0) {
        precondition(startOffset >= 0, "startOffset must be non-negative (GUARDS §T)")
        self.requestedOffset = startOffset
        self.absOffset = startOffset
    }

    /// Ingest one `blockfile` "append" payload (already base64-decoded).
    ///
    /// While buffering (pre-backfill) the bytes are queued and `[]` is returned.
    /// Once loaded, the bytes are contiguous with the live tail and returned
    /// verbatim (advancing `absOffset`).
    public mutating func append(_ data: Data) -> Data {
        if data.isEmpty { return Data() }
        if !loaded {
            buffered.append(data)
            return Data()
        }
        absOffset += Int64(data.count)
        return data
    }

    /// Handle `fileop == "truncate"`: the circular buffer wrapped / was cleared.
    /// Clears any buffered appends and resets the absolute offset to 0 (GUARDS §T:
    /// "clear the terminal + reset offset"). The caller clears the sink.
    public mutating func truncate() {
        buffered.removeAll(keepingCapacity: true)
        absOffset = 0
        // `loaded` is intentionally preserved: after the initial load a truncate
        // is a live event, and subsequent appends are contiguous from offset 0.
    }

    /// Apply the HTTP backfill and flush the buffered appends, returning the exact
    /// ordered byte sequence to feed to the sink with NO gaps and NO duplicates.
    ///
    /// GUARDS §T encoded here:
    ///  - The server clamps an offset older than `DataStartIdx`, so the backfill
    ///    actually starts at `max(requestedOffset, info.dataStartIdx)`; we recompute
    ///    from the returned `info` rather than assuming our offset was honored.
    ///  - Backfill covers `[actualStart, info.size)`. The buffered appends are a
    ///    contiguous suffix of the file ending at the live tail, but the tail at
    ///    subscribe time may be PAST `requestedOffset` (a remount of a populated
    ///    terminal, or output produced during an outage). Anchoring the buffer at
    ///    `requestedOffset` would silently drop those raced bytes (G1). Instead we
    ///    anchor by CONTENT OVERLAP: find the largest leading run of buffered bytes
    ///    that is byte-identical to the matching tail of the backfill, discard it as
    ///    duplicate, and append the remainder.
    ///
    /// - Throws: `WaveError.terminalReconcile` if the backfill byte count does not
    ///   match the server's `Size - actualStart` contract (`pkg/web/web.go:190`).
    public mutating func applyBackfill(data: Data, info: WaveFile) throws -> Data {
        precondition(!loaded, "applyBackfill called twice on one reconciler (GUARDS §T)")
        let actualStart = Swift.max(requestedOffset, info.dataStartIdx)
        let expectedLen = Swift.max(0, info.size - actualStart)
        guard Int64(data.count) == expectedLen else {
            throw WaveError.terminalReconcile(
                "backfill length \(data.count) != Size(\(info.size)) - start(\(actualStart)) = \(expectedLen)")
        }
        return finishBackfill(data: data, info: info, floorOffset: requestedOffset)
    }

    /// Apply a TAIL backfill (server contract: body = file[size - body.count,
    /// size)). Same gap/dup-free merge as `applyBackfill`, but the body starts
    /// at a server-chosen offset instead of a requested one. Returns the ordered
    /// bytes to feed plus that absolute start offset -- the history/live seam
    /// anchor for the virtualized-scrollback layer.
    public mutating func applyTailBackfill(data: Data, info: WaveFile) throws -> (out: Data, actualStart: Int64) {
        precondition(!loaded, "applyTailBackfill called twice on one reconciler (GUARDS §T)")
        let actualStart = info.size - Int64(data.count)
        guard actualStart >= 0, data.isEmpty || actualStart >= info.dataStartIdx else {
            throw WaveError.terminalReconcile(
                "tail backfill length \(data.count) inconsistent with Size(\(info.size)) / DataStartIdx(\(info.dataStartIdx))")
        }
        let out = finishBackfill(data: data, info: info, floorOffset: actualStart)
        return (out, actualStart)
    }

    private mutating func finishBackfill(data: Data, info: WaveFile, floorOffset: Int64) -> Data {
        let b = [UInt8](flattenedBuffered())
        let d = [UInt8](data)
        let cover = coveredPrefixLength(backfill: d, buffer: b, size: info.size, floorOffset: floorOffset)
        var out = data
        if cover < b.count { out.append(contentsOf: b[cover..<b.count]) }
        absOffset = info.size + Int64(b.count - cover)
        buffered.removeAll(keepingCapacity: true)
        loaded = true
        return out
    }

    private func flattenedBuffered() -> Data {
        var d = Data()
        for chunk in buffered { d.append(chunk) }
        return d
    }

    /// Number of leading buffered bytes already contained in 'backfill' (absolute
    /// offset < size). The buffered run is a contiguous suffix of the file ending
    /// at the live tail; 'backfill' is file[actualStart, size). Pick the LARGEST
    /// prefix length whose bytes are byte-identical to the matching tail of the
    /// backfill, bounded by size - floorOffset (the buffer cannot begin before
    /// the offset the backfill body starts at). This anchors by content, not the
    /// requested offset, so live appends that raced the GET are never dropped (G1).
    private func coveredPrefixLength(backfill d: [UInt8], buffer b: [UInt8], size: Int64, floorOffset: Int64) -> Int {
        if b.isEmpty { return 0 }
        let maxCover = Int(Swift.min(Int64(b.count), Swift.max(0, size - floorOffset)))
        var c = maxCover
        while c > 0 {
            let l = Swift.min(c, d.count)
            var match = true
            var i = 0
            let bStart = c - l
            let dStart = d.count - l
            while i < l { if b[bStart + i] != d[dStart + i] { match = false; break }; i += 1 }
            if match { return c }
            c -= 1
        }
        return 0
    }
}
