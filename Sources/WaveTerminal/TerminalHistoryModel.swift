// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// The virtualized history layer above the live sink: the on-disk term file is
// addressed as fixed-size LOGICAL LINE chunks (the backend line index resolves
// line ranges to byte ranges without decompressing), fetched on demand, parsed
// off-main in a scratch VT terminal (HistoryChunkParser), and cached with LRU
// eviction. Visual-row counts are exact for parsed chunks and estimated (lines
// x rolling wrap factor) for unparsed ones; estimates never shift content on
// resolve because the view re-anchors by (chunk, rowInChunk) positions.
//
// Coverage: logical lines [0, coverageEndLine) render as history; the live sink
// renders everything after the seam. Initially coverageEndLine is the mount
// anchor's sinkBaseLine (the tail backfill starts at a server-aligned line
// start). Once the sink prunes, the content-anchored re-anchor advances the
// coverage and installs a row-precise seam cut.

import Foundation
#if canImport(CGhostty)
import CGhostty
#endif

#if canImport(CGhostty)

/// Row-precise seam: history rendering stops at `rowInChunk` of `chunkIndex`
/// (that row and everything after it duplicates the sink's retained rows).
public struct TermSeamCut: Equatable, Sendable {
    public var chunkIndex: Int
    public var rowInChunk: Int
    public init(chunkIndex: Int, rowInChunk: Int) {
        self.chunkIndex = chunkIndex
        self.rowInChunk = rowInChunk
    }
}

/// What the view reads (one withTerminal block) from the live sink so the seam
/// can be content-anchored against parsed history.
public struct SinkTopSnapshot: Sendable {
    /// Plain text of the sink's oldest K retained SCREEN rows (trailing-space
    /// trimmed; padded with "" when the sink holds fewer rows).
    public var signature: [String]
    /// The sink's total row count (scrollback + active area).
    public var totalRows: Int
    /// True once the sink has pruned (total rows reached max_scrollback) --
    /// only then can the initial seam be stale.
    public var pruned: Bool
    /// The live end's logical line number (controller.currentEndLine).
    public var currentEndLine: Int64?
    public var cols: Int

    public init(signature: [String], totalRows: Int, pruned: Bool, currentEndLine: Int64?, cols: Int) {
        self.signature = signature
        self.totalRows = totalRows
        self.pruned = pruned
        self.currentEndLine = currentEndLine
        self.cols = cols
    }
}

/// Result of a seam (re)anchor: whether the seam is exact (content-matched or
/// unpruned-by-construction) and the K-row signature it was anchored against.
public struct TermSeamState: Equatable, Sendable {
    public var signature: [String]
    /// controller.currentOffset at anchor time -- a cheap staleness probe.
    public var anchoredAtOffset: Int64
    public var exact: Bool
}

@MainActor
public final class TerminalHistoryModel {
    public static let linesPerChunk: Int64 = 10_000
    /// Leading logical lines parsed for VT state (SGR/charset) and discarded.
    public static let warmupLines = 200
    /// Parsed chunks kept resident (rows arrays); counts survive eviction.
    public static let maxParsedChunks = 4

    public struct ParsedChunk {
        public var rows: [TermHistoryRow]
        /// First logical line of the chunk (== chunkIndex * linesPerChunk).
        public var startLine: Int64
        /// Absolute byte offset of the chunk body start.
        public var startOffset: Int64
        /// Row index (within `rows`) where each logical line starts.
        public var lineStartRows: [Int]
        var lastAccess: UInt64
    }

    private weak var controller: TerminalController?
    private let parser = HistoryChunkParser()

    private(set) var anchor: TermHistoryAnchor?
    private(set) var cols = 80
    /// Logical lines [0, coverageEndLine) belong to the history layer.
    private(set) var coverageEndLine: Int64 = 0
    /// Row-precise cut inside the last covered chunk (nil = cut exactly at
    /// coverageEndLine's line start).
    private(set) var seamCut: TermSeamCut?

    private var chunks: [Int: ParsedChunk] = [:]
    private var exactRowCounts: [Int: Int] = [:]
    private var loading: Set<Int> = []
    private var accessTick: UInt64 = 0
    /// Bumped on reset (anchor/cols change); in-flight parses of an older
    /// generation are dropped.
    private var generation = 0

    /// Rolling rows-per-line wrap factor from parsed chunks (>= 1.0).
    private var parsedLines: Int64 = 0
    private var parsedRows: Int64 = 0

    /// The live terminal's current 256-color palette, snapshotted by the view,
    /// so scratch parses resolve indexed colors identically.
    public var paletteProvider: (() -> [GhosttyColorRgb]?)?

    /// Fired on the main actor whenever row counts or parsed content change
    /// (chunk installed/evicted, coverage advanced). The view re-anchors its
    /// scroll position and redraws.
    public var onRowsChanged: (() -> Void)?

    public init() {}

    public func attach(controller: TerminalController) {
        self.controller = controller
    }

    // MARK: - Reset / anchor

    public func setAnchor(_ anchor: TermHistoryAnchor?, cols: Int) {
        self.anchor = anchor
        self.cols = max(2, cols)
        chunks.removeAll()
        exactRowCounts.removeAll()
        loading.removeAll()
        seamCut = nil
        parsedLines = 0
        parsedRows = 0
        generation += 1
        coverageEndLine = anchor?.sinkBaseLine ?? 0
        onRowsChanged?()
    }

    /// Reflow: drop parsed content (rows re-wrap at the new width); exact
    /// counts are width-dependent too, so they reset to estimates.
    public func setCols(_ cols: Int) {
        guard cols != self.cols, cols >= 2 else { return }
        self.cols = cols
        chunks.removeAll()
        exactRowCounts.removeAll()
        loading.removeAll()
        seamCut = nil
        parsedLines = 0
        parsedRows = 0
        generation += 1
        onRowsChanged?()
    }

    // MARK: - Row space

    public var chunkCount: Int {
        guard coverageEndLine > 0 else { return 0 }
        return Int((coverageEndLine + Self.linesPerChunk - 1) / Self.linesPerChunk)
    }

    /// Logical lines covered by chunk `idx` (the last chunk is partial).
    func lineCount(ofChunk idx: Int) -> Int64 {
        let start = Int64(idx) * Self.linesPerChunk
        return Swift.max(0, Swift.min(Self.linesPerChunk, coverageEndLine - start))
    }

    private var wrapFactor: Double {
        guard parsedLines > 0 else { return 1.0 }
        return Swift.max(1.0, Double(parsedRows) / Double(parsedLines))
    }

    /// Visual rows contributed by chunk `idx` (exact when parsed/known,
    /// else lines x wrap factor), honoring the seam cut: the cut chunk stops
    /// at the cut row and every chunk PAST it contributes nothing (those rows
    /// duplicate the live sink).
    public func rowCount(ofChunk idx: Int) -> Int {
        if let cut = seamCut, idx > cut.chunkIndex {
            return 0
        }
        var count: Int
        if let exact = exactRowCounts[idx] {
            count = exact
        } else {
            count = Int((Double(lineCount(ofChunk: idx)) * wrapFactor).rounded())
        }
        if let cut = seamCut, cut.chunkIndex == idx {
            count = Swift.min(count, cut.rowInChunk)
        }
        return count
    }

    /// Total visual rows the history layer contributes above the sink.
    public func totalRows() -> Int {
        var total = 0
        for i in 0..<chunkCount {
            total += rowCount(ofChunk: i)
        }
        return total
    }

    /// Map a global history row index to (chunk, rowInChunk).
    public func position(ofRow index: Int) -> (chunk: Int, row: Int)? {
        var remaining = index
        for i in 0..<chunkCount {
            let count = rowCount(ofChunk: i)
            if remaining < count { return (i, remaining) }
            remaining -= count
        }
        return nil
    }

    /// Inverse of `position(ofRow:)`, clamped to the current counts.
    public func rowIndex(chunk: Int, row: Int) -> Int {
        var total = 0
        for i in 0..<Swift.min(chunk, chunkCount) {
            total += rowCount(ofChunk: i)
        }
        return total + Swift.min(row, Swift.max(0, rowCount(ofChunk: chunk)))
    }

    /// The row at a global history index. Returns nil (and kicks an async
    /// fetch+parse) while the containing chunk is not resident.
    public func row(at index: Int) -> TermHistoryRow? {
        guard let (chunkIdx, rowIdx) = position(ofRow: index) else { return nil }
        guard var chunk = chunks[chunkIdx] else {
            requestChunk(chunkIdx)
            // prefetch the chunk above (scroll-up direction)
            if chunkIdx > 0 { requestChunk(chunkIdx - 1) }
            return nil
        }
        accessTick += 1
        chunk.lastAccess = accessTick
        chunks[chunkIdx] = chunk
        if chunkIdx > 0, chunks[chunkIdx - 1] == nil { requestChunk(chunkIdx - 1) }
        guard rowIdx < chunk.rows.count else { return nil }
        return chunk.rows[rowIdx]
    }

    public func isParsed(_ chunkIdx: Int) -> Bool {
        chunks[chunkIdx] != nil
    }

    public func parsedChunk(_ chunkIdx: Int) -> ParsedChunk? {
        chunks[chunkIdx]
    }

    // MARK: - Seam (content-anchored)

    public private(set) var seamState: TermSeamState?

    /// First logical line NOT rendered as history — the sink's top line once
    /// the seam is anchored. coverageEndLine can extend PAST the cut (the
    /// anchor search grows it to reach the seam-region chunk), so classification
    /// of "history vs sink" must use this, not coverageEndLine.
    public var historyEndLine: Int64 {
        guard let cut = seamCut else { return coverageEndLine }
        guard let chunk = chunks[cut.chunkIndex] else {
            return Swift.min(coverageEndLine, Int64(cut.chunkIndex) * Self.linesPerChunk + Int64(cut.rowInChunk))
        }
        guard !chunk.rows.isEmpty else { return chunk.startLine }
        let rowIdx = Swift.min(cut.rowInChunk, chunk.rows.count - 1)
        return chunk.startLine + Int64(lineIndexOfRow(chunk, rowIdx))
    }

    /// Extend history coverage to `endLine` and install a row-precise cut.
    public func installSeam(coverageEndLine endLine: Int64, cut: TermSeamCut?) {
        coverageEndLine = Swift.max(coverageEndLine, endLine)
        seamCut = cut
        onRowsChanged?()
    }

    /// True when the current seam can be trusted for entry into history:
    /// either a fresh content anchor, or the unpruned initial seam.
    public func seamFresh(currentOffset: Int64, pruned: Bool) -> Bool {
        if !pruned && seamCut == nil { return true }
        guard let state = seamState else { return false }
        return state.anchoredAtOffset == currentOffset
    }

    /// (Re)anchor the seam. When the sink has NOT pruned, the initial seam
    /// (coverage = mount sinkBaseLine, no cut) is exact by construction (the
    /// tail backfill starts at a server-aligned line boundary). Once pruned,
    /// find the sink's top rows in parsed history content and cut there, so
    /// scrolling up reaches every pruned row with no gap and no duplicate.
    /// Returns true when the seam is exact.
    @discardableResult
    public func reanchorSeam(sinkTop: SinkTopSnapshot, currentOffset: Int64) async -> Bool {
        guard anchor != nil else { return false }
        if !sinkTop.pruned {
            seamCut = nil
            coverageEndLine = anchor?.sinkBaseLine ?? 0
            seamState = TermSeamState(signature: sinkTop.signature, anchoredAtOffset: currentOffset, exact: true)
            onRowsChanged?()
            return true
        }
        // Estimated seam line: live end minus the sink's retained rows
        // de-wrapped by the rolling wrap factor.
        let sinkLines = Int64((Double(sinkTop.totalRows) / wrapFactor).rounded())
        let baseLine = anchor?.sinkBaseLine ?? 0
        var estLine = baseLine
        if let endLine = sinkTop.currentEndLine {
            estLine = Swift.max(baseLine, endLine - sinkLines)
        }
        // Grow coverage so the estimate's chunk exists, then content-match.
        let searchEnd = estLine + Self.linesPerChunk
        coverageEndLine = Swift.max(coverageEndLine, Swift.min(searchEnd, sinkTop.currentEndLine ?? searchEnd))
        let estChunk = Int(estLine / Self.linesPerChunk)
        for candidate in [estChunk, estChunk - 1, estChunk + 1] {
            guard candidate >= 0, candidate < chunkCount else { continue }
            guard await ensureChunk(candidate), let chunk = chunks[candidate] else { continue }
            if let rowIdx = Self.matchSignature(sinkTop.signature, in: chunk.rows,
                                                nearRow: candidate == estChunk ? estimateRowInChunk(chunk, line: estLine) : nil) {
                let endLine = chunk.startLine + Int64(lineIndexOfRow(chunk, rowIdx)) + 1
                coverageEndLine = Swift.max(coverageEndLine, endLine)
                seamCut = TermSeamCut(chunkIndex: candidate, rowInChunk: rowIdx)
                seamState = TermSeamState(signature: sinkTop.signature, anchoredAtOffset: currentOffset, exact: true)
                onRowsChanged?()
                return true
            }
        }
        // Fallback: cut at the estimated line boundary (inexact -- rare:
        // all-blank sink top or content genuinely unmatched).
        let estChunkClamped = Swift.max(0, Swift.min(estChunk, chunkCount - 1))
        if let chunk = chunks[estChunkClamped] {
            let lineInChunk = Int(Swift.max(0, estLine - chunk.startLine))
            let rowIdx = lineInChunk < chunk.lineStartRows.count
                ? chunk.lineStartRows[lineInChunk] : chunk.rows.count
            seamCut = TermSeamCut(chunkIndex: estChunkClamped, rowInChunk: rowIdx)
        } else {
            seamCut = nil
            coverageEndLine = estLine
        }
        seamState = TermSeamState(signature: sinkTop.signature, anchoredAtOffset: currentOffset, exact: false)
        onRowsChanged?()
        return false
    }

    /// While frozen in history mode, prunes advance the sink top. Detect via a
    /// changed signature and move the cut FORWARD (prunes only move one way)
    /// within already-parsed rows. Returns the number of rows the cut advanced
    /// (the view adds it to its scroll offset so on-screen content stays put),
    /// or nil when no advance was possible.
    public func advanceSeam(sinkTop: SinkTopSnapshot, currentOffset: Int64) -> Int? {
        guard let cut = seamCut, let chunk = chunks[cut.chunkIndex] else { return nil }
        guard let state = seamState, state.signature != sinkTop.signature else {
            seamState?.anchoredAtOffset = currentOffset
            return 0
        }
        let remaining = Array(chunk.rows[Swift.min(cut.rowInChunk, chunk.rows.count)...])
        guard let localIdx = Self.matchSignature(sinkTop.signature, in: remaining, nearRow: nil) else {
            return nil
        }
        let newRow = cut.rowInChunk + localIdx
        let advanced = localIdx
        let endLine = chunk.startLine + Int64(lineIndexOfRow(chunk, newRow)) + 1
        coverageEndLine = Swift.max(coverageEndLine, endLine)
        seamCut = TermSeamCut(chunkIndex: cut.chunkIndex, rowInChunk: newRow)
        seamState = TermSeamState(signature: sinkTop.signature, anchoredAtOffset: currentOffset, exact: true)
        onRowsChanged?()
        return advanced
    }

    /// Row index (within a parsed chunk) estimated for a logical line.
    private func estimateRowInChunk(_ chunk: ParsedChunk, line: Int64) -> Int? {
        let lineInChunk = Int(line - chunk.startLine)
        guard lineInChunk >= 0 else { return nil }
        guard lineInChunk < chunk.lineStartRows.count else { return chunk.rows.count }
        return chunk.lineStartRows[lineInChunk]
    }

    /// Logical line index (within the chunk) containing a row.
    private func lineIndexOfRow(_ chunk: ParsedChunk, _ rowIdx: Int) -> Int {
        // lineStartRows is ascending; find the last entry <= rowIdx
        var lo = 0
        var hi = chunk.lineStartRows.count - 1
        var best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if chunk.lineStartRows[mid] <= rowIdx {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }

    /// Find the row where the sink-top signature begins. Non-empty signature
    /// rows must match exactly (trailing-space trimmed); empty/missing trailing
    /// rows are wildcards. With several full matches (periodic content) the one
    /// nearest `nearRow` wins -- visually identical cuts by construction.
    nonisolated static func matchSignature(_ signature: [String], in rows: [TermHistoryRow], nearRow: Int?) -> Int? {
        let sig = signature.map { trimTrailing($0) }
        guard let first = sig.first(where: { !$0.isEmpty }) else { return nil }
        let firstIdx = sig.firstIndex(of: first) ?? 0
        var candidates: [Int] = []
        for (idx, row) in rows.enumerated() {
            guard trimTrailing(row.plain) == first else { continue }
            // align so signature[firstIdx] sits at idx
            let start = idx - firstIdx
            guard start >= 0 else { continue }
            var ok = true
            for (sigOff, sigRow) in sig.enumerated() {
                guard !sigRow.isEmpty else { continue }
                let rowIdx = start + sigOff
                guard rowIdx < rows.count else { break } // ran past parsed rows: trailing wildcards
                if trimTrailing(rows[rowIdx].plain) != sigRow {
                    ok = false
                    break
                }
            }
            if ok { candidates.append(start) }
        }
        guard !candidates.isEmpty else { return nil }
        guard let nearRow else { return candidates[0] }
        return candidates.min { abs($0 - nearRow) < abs($1 - nearRow) }
    }

    nonisolated static func trimTrailing(_ s: String) -> String {
        var view = Substring(s)
        while view.last == " " { view.removeLast() }
        return String(view)
    }

    // MARK: - Chunk loading

    public func requestChunk(_ idx: Int) {
        guard idx >= 0, idx < chunkCount, chunks[idx] == nil, !loading.contains(idx) else { return }
        guard let controller else { return }
        loading.insert(idx)
        let gen = generation
        let startLine = Int64(idx) * Self.linesPerChunk
        let warmup = idx == 0 ? 0 : Int64(Self.warmupLines)
        let fetchStart = startLine - warmup
        let numLines = lineCount(ofChunk: idx) + warmup
        let cols = self.cols
        let palette = paletteProvider?()
        Task { [weak self, parser] in
            var result: HistoryChunkParser.ParseResult?
            var startOffset: Int64 = 0
            do {
                let fetch = try await controller.fetchHistoryLines(startLine: fetchStart, numLines: numLines)
                startOffset = fetch.startOffset
                let stale: @Sendable () -> Bool = { false }
                result = await withCheckedContinuation { cont in
                    parser.parse(
                        bytes: fetch.data, cols: cols, warmupLines: Int(warmup),
                        palette: palette, isCancelled: stale
                    ) { cont.resume(returning: $0) }
                }
                if result == nil {
                    NSLog("history chunk %d: parse returned nil (bytes=%d cols=%d)", idx, fetch.data.count, cols)
                }
            } catch {
                NSLog("history chunk %d: fetch failed: %@", idx, String(describing: error))
                result = nil
            }
            await MainActor.run {
                guard let self else { return }
                self.loading.remove(idx)
                guard self.generation == gen, let result else { return }
                self.installChunk(idx, rows: result.rows, lineStartRows: result.lineStartRows, startLine: startLine, startOffset: startOffset)
            }
        }
    }

    /// Await a chunk being resident (used by seam re-anchor + match jumps).
    public func ensureChunk(_ idx: Int) async -> Bool {
        guard idx >= 0, idx < chunkCount else { return false }
        if chunks[idx] != nil { return true }
        requestChunk(idx)
        // poll: chunk installation happens on this actor, so brief sleeps are fine
        for _ in 0..<600 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if chunks[idx] != nil { return true }
            if !loading.contains(idx) {
                // load finished without installing (stale generation / error)
                return chunks[idx] != nil
            }
        }
        return chunks[idx] != nil
    }

    private func installChunk(_ idx: Int, rows: [TermHistoryRow], lineStartRows: [Int], startLine: Int64, startOffset: Int64) {
        accessTick += 1
        chunks[idx] = ParsedChunk(
            rows: rows, startLine: startLine, startOffset: startOffset,
            lineStartRows: lineStartRows, lastAccess: accessTick)
        exactRowCounts[idx] = rows.count
        parsedLines += Int64(lineStartRows.count)
        parsedRows += Int64(rows.count)
        evictIfNeeded(keeping: idx)
        onRowsChanged?()
    }

    private func evictIfNeeded(keeping: Int) {
        while chunks.count > Self.maxParsedChunks {
            let victim = chunks
                .filter { $0.key != keeping }
                .min { $0.value.lastAccess < $1.value.lastAccess }
            guard let victim else { return }
            // exactRowCounts survives eviction so the row space never shifts
            chunks.removeValue(forKey: victim.key)
        }
    }

    // MARK: - Search support

    /// Best-effort logical line of a global history row (exact when the
    /// containing chunk is parsed, estimated otherwise). Used by the
    /// line-space scrollbar.
    public func lineOfRow(_ index: Int) -> Int64? {
        guard let (chunkIdx, rowIdx) = position(ofRow: index) else { return nil }
        if let chunk = chunks[chunkIdx] {
            return chunk.startLine + Int64(lineIndexOfRow(chunk, rowIdx))
        }
        let base = Int64(chunkIdx) * Self.linesPerChunk
        return base + Int64((Double(rowIdx) / wrapFactor).rounded())
    }

    /// Rolling rows-per-line factor (>= 1), exposed for sink-side estimates.
    public var rowsPerLine: Double { wrapFactor }

    /// Best-effort global history row for a logical line (exact when the
    /// containing chunk is parsed; estimated otherwise). Lines at/past the
    /// coverage end return nil (they live in the sink).
    public func estimatedRow(forLine line: Int64) -> Int? {
        guard line >= 0, line < historyEndLine else { return nil }
        let chunkIdx = Int(line / Self.linesPerChunk)
        var total = 0
        for i in 0..<chunkIdx {
            total += rowCount(ofChunk: i)
        }
        if let chunk = chunks[chunkIdx] {
            let lineInChunk = Int(line - chunk.startLine)
            if lineInChunk < chunk.lineStartRows.count {
                return total + chunk.lineStartRows[lineInChunk]
            }
            return total + rowCount(ofChunk: chunkIdx)
        }
        let lineInChunk = Double(line - Int64(chunkIdx) * Self.linesPerChunk)
        return total + Int((lineInChunk * wrapFactor).rounded())
    }

    /// Locate a search match precisely: ensure the containing chunk is parsed,
    /// then find the visual row of the match line whose text contains `query`
    /// (the line may wrap across several rows). Returns the global history row
    /// and the matched column range, or nil when the match is past the
    /// coverage end (i.e. in the live sink) or the chunk cannot load.
    public func locateMatch(line: Int64, query: String) async -> (row: Int, cols: Range<Int>)? {
        guard line >= 0, line < historyEndLine else { return nil }
        let chunkIdx = Int(line / Self.linesPerChunk)
        guard await ensureChunk(chunkIdx), let chunk = chunks[chunkIdx] else { return nil }
        let lineInChunk = Int(line - chunk.startLine)
        guard lineInChunk >= 0, lineInChunk < chunk.lineStartRows.count else { return nil }
        let firstRow = chunk.lineStartRows[lineInChunk]
        let endRow = lineInChunk + 1 < chunk.lineStartRows.count
            ? chunk.lineStartRows[lineInChunk + 1]
            : chunk.rows.count
        let needle = query.lowercased()
        var globalBase = 0
        for i in 0..<chunkIdx {
            globalBase += rowCount(ofChunk: i)
        }
        for rowIdx in firstRow..<endRow {
            let row = chunk.rows[rowIdx]
            if let r = row.plain.lowercased().range(of: needle) {
                let lower = row.plain.distance(from: row.plain.startIndex, to: r.lowerBound)
                let upper = row.plain.distance(from: row.plain.startIndex, to: r.upperBound)
                let colRange = Self.columnRange(offsets: row.offsets, plain: row.plain, lower: lower, upper: upper)
                return (globalBase + rowIdx, colRange)
            }
        }
        return (globalBase + firstRow, 0..<Swift.max(1, chunk.rows[firstRow].cells.count))
    }

    /// Map a character range in `plain` to a column range via the per-column
    /// offset table (character positions approximate UTF-16 offsets for the
    /// short strings involved; exact for ASCII).
    nonisolated static func columnRange(offsets: [Int], plain: String, lower: Int, upper: Int) -> Range<Int> {
        var startCol = 0
        var endCol = Swift.max(1, offsets.count)
        for (col, off) in offsets.enumerated() {
            if off <= lower { startCol = col }
            if off < upper { endCol = col + 1 }
        }
        return startCol..<Swift.max(startCol + 1, endCol)
    }
}

#endif
