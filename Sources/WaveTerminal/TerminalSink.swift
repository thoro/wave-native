// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveTerminal — the sink seam (PROTOCOL.md §4 "What libghostty replaces vs what
// we wire"). The reconciler produces an ordered byte stream; a `TerminalSink`
// consumes it. The real sink feeds libghostty (escape-sequence parsing + grid
// render); the capturing sink records bytes so the reconciler is unit-testable
// WITHOUT libghostty (GUARDS §T "[CHECK]: assert the rendered byte stream equals
// the shell's actual output stream exactly").

import Foundation

/// Decodes a terminal "current working directory" report into a filesystem path.
///
/// Kept OUTSIDE the `#if canImport(CGhostty)` block (and free of any libghostty
/// types) so the parsing is unit-testable without the native VT library.
public enum TerminalPwd {
    /// Turn a raw pwd report (as emitted by the shell) into an absolute path, or nil
    /// when there is nothing usable.
    ///
    /// OSC 7 reports a `file://host/path` URI (RFC 8089): an authority (host) names the
    /// machine and the path is percent-encoded. We strip the scheme + authority and
    /// percent-decode the path. OSC 9 / OSC 1337 report a bare path, which we pass
    /// through. A cleared pwd (empty report, e.g. an empty OSC 7) yields nil so callers
    /// simply keep the previous value / fall back to the default cwd.
    public static func path(fromReport raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let schemeSep = trimmed.range(of: "://"),
           trimmed[trimmed.startIndex..<schemeSep.lowerBound].lowercased() == "file" {
            let afterScheme = trimmed[schemeSep.upperBound...]
            // Everything up to the first '/' is the authority (host) — often empty or
            // "localhost"; the path begins at that slash. `file:///p` → authority empty,
            // path "/p"; `file://host/p` → authority "host", path "/p".
            guard let slash = afterScheme.firstIndex(of: "/") else { return nil }
            let encodedPath = String(afterScheme[slash...])
            return encodedPath.removingPercentEncoding ?? encodedPath
        }
        // Bare path (OSC 9 / OSC 1337) — only trust an absolute path.
        guard trimmed.hasPrefix("/") else { return nil }
        return trimmed
    }
}

/// Consumes reconciled terminal bytes and resize/clear notifications.
///
/// All calls are serialized by `TerminalController` (single ordered stream), so
/// implementations do not need internal locking for ordering.
public protocol TerminalSink: AnyObject {
    /// Feed decoded VT bytes (in absolute order, no gaps/dups — GUARDS §T).
    func feed(_ bytes: Data)
    /// Feed REPLAYED history (backfill). Same byte path as `feed`, but conformers that
    /// produce outward effects must suppress them here (query responses, bells) — see
    /// `GhosttySink.replaying`. Defaults to `feed` for sinks with no such effects.
    func feedBackfill(_ bytes: Data)
    /// Clear the screen/scrollback (handles `fileop == "truncate"`, GUARDS §T).
    func clear()
    /// Notify a grid resize (paired with `ControllerInputCommand.termsize`).
    func setSize(cols: Int, rows: Int)
}

public extension TerminalSink {
    func feedBackfill(_ bytes: Data) { feed(bytes) }
}

/// Test/headless sink: accumulates everything fed to it so a test can assert the
/// merged byte stream equals the shell's actual output exactly (GUARDS §T).
public final class CapturingTerminalSink: TerminalSink {
    public private(set) var received = Data()
    public private(set) var clearCount = 0
    public private(set) var lastSize: TermGridSize?

    public init() {}

    public func feed(_ bytes: Data) { received.append(bytes) }

    public func clear() {
        received.removeAll(keepingCapacity: true)
        clearCount += 1
    }

    public func setSize(cols: Int, rows: Int) {
        lastSize = TermGridSize(cols: cols, rows: rows)
    }
}

/// Plain value type for `CapturingTerminalSink.lastSize` (avoids importing
/// WaveCore.TermSize here; the controller maps between them).
public struct TermGridSize: Equatable, Sendable {
    public let cols: Int
    public let rows: Int
    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }
}

#if canImport(CGhostty)
import CGhostty

/// libghostty-vt-backed sink. Owns a `GhosttyTerminal` (the headless VT core that
/// parses escape sequences and maintains grid + scrollback state). The reconciler
/// feeds the merged byte stream in via `feed`; a renderer reads the grid back out
/// via `withTerminal` + the render-state API. Query responses the terminal must
/// write to the pty (DSR/DA/etc.) are routed out through `onOutput`, which
/// `TerminalController` wires to `sendInput`.
///
/// PROTOCOL.md §4: libghostty owns escape parsing + state; WaveTerminal moves
/// bytes between it and `ControllerInputCommand`, and renders the grid natively.
///
/// Thread-safety: `feed`/`clear`/`setSize` are serialized by `TerminalController`,
/// but a renderer reads the terminal from the UI thread. A single `lock`
/// guards every libghostty-vt call so terminal access stays exclusive (the
/// render-state API requires exclusive access during its update, render.h §"Dirty
/// Tracking").
public final class GhosttySink: TerminalSink, @unchecked Sendable {
    private let lock = NSLock()
    private var terminal: GhosttyTerminal?

    /// Invoked with bytes the terminal needs to write back to the pty (query
    /// responses). `TerminalController` wires this to `sendInput`.
    public var onOutput: ((Data) -> Void)?

    /// Fired after any state mutation (feed/clear/resize) so the renderer can mark
    /// itself dirty and redraw. Hops to the main thread in the renderer.
    public var onRender: (() -> Void)?

    /// Fired when the terminal rings the bell (BEL, 0x07) via the libghostty BELL
    /// effect. ALREADY hopped to the main queue (see `ghosttyBellCallback`), so the
    /// handler must not assume it runs under the sink/controller lock.
    public var onBell: (() -> Void)?

    /// Fired when an OSC 9 / OSC 777 desktop-notification sequence is parsed out of the
    /// fed byte stream. ALREADY hopped to the main queue. `title` is nil for OSC 9.
    public var onNotification: ((_ title: String?, _ body: String) -> Void)?

    /// Fired when an OSC 52 clipboard WRITE is parsed out of the fed byte stream: the
    /// decoded contents to place on the pasteboard (empty = clear). ALREADY hopped to the
    /// main queue. Not fired for replayed history or OSC 52 read queries.
    public var onClipboardCopy: ((Data) -> Void)?

    /// Fired when the shell reports a new working directory (OSC 7 / OSC 9 / OSC 1337)
    /// via the libghostty PWD-changed effect. The argument is an absolute filesystem
    /// path (the `file://` URI is already decoded — see `TerminalPwd`). ALREADY hopped
    /// to the main queue (see `ghosttyPwdChangedCallback`), so the handler must not
    /// assume it runs under the sink/controller lock.
    public var onPwdChanged: ((String) -> Void)?

    /// Recognizes OSC desktop-notification sequences in the fed bytes. Only touched
    /// from `feed` (the controller-serialized stream), so it needs no extra locking.
    private var notificationScanner = OSCNotificationScanner()

    /// Cell pixel metrics, used by `ghostty_terminal_resize` for in-band size
    /// reports + image protocols. The renderer sets these from its font metrics.
    private var cellWidthPx: UInt32 = 0
    private var cellHeightPx: UInt32 = 0

    /// True ONLY while replaying historical (backfilled) bytes through `vt_write`. The
    /// write-pty and bell callbacks fire synchronously inside `vt_write` under `lock`, so
    /// they read this on the same stack that set it. While replaying we drop those outward
    /// effects: query responses (DA/DSR/XTVERSION/DECRPM) must NOT reach the live pty — the
    /// programs that sent those queries are long gone, so answering them injects garbage at
    /// the shell prompt (the floating `libghostty^[\^[[?62;22c…` reports) — and stale bells
    /// must not re-ring.
    fileprivate var replaying = false

    /// Approximate per-cell page memory in libghostty's PageList, used to
    /// convert a line budget into the byte budget `max_scrollback` actually is.
    /// Empirical: ~3.5 bytes/cell; 4 with headroom.
    public static let scrollbackBytesPerCell = 4

    /// Convert a scrollback LINE budget to the byte budget libghostty expects.
    /// max_scrollback is a page-memory byte cap (PageList max_size, see
    /// vendor/ghostty/src/terminal/Screen.zig: "amount of scrollback to keep in
    /// bytes") -- the vt.h comment saying "lines" is misleading. Rows store
    /// full-width cells, so bytes ~= lines x cols x cellMem.
    public static func scrollbackBytes(lines: Int, cols: Int) -> Int {
        lines * max(80, cols) * scrollbackBytesPerCell
    }

    /// The byte budget this sink's terminal was created with (creation-only).
    public let maxScrollback: Int

    /// - Parameters:
    ///   - cols/rows: the initial grid size (GUARDS §T default 80x25).
    ///   - maxScrollback: scrollback page-memory budget in BYTES (see
    ///     `scrollbackBytes(lines:cols:)`).
    public init(cols: Int, rows: Int, maxScrollback: Int = 6_000_000) {
        self.maxScrollback = maxScrollback
        var opts = GhosttyTerminalOptions()
        opts.cols = UInt16(max(1, cols))
        opts.rows = UInt16(max(1, rows))
        opts.max_scrollback = maxScrollback
        var t: GhosttyTerminal?
        let rc = ghostty_terminal_new(nil, &t, opts)
        precondition(rc == GHOSTTY_SUCCESS && t != nil, "ghostty_terminal_new failed (rc=\(rc.rawValue))")
        terminal = t
        // Recover `self` in the C write-pty callback, then route responses out.
        ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque())
        let cb: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = ghosttyWritePtyCallback
        ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(cb, to: UnsafeRawPointer.self))
        // BEL effect: libghostty invokes this synchronously inside vt_write (under our
        // lock); the callback only DISPATCHES to the main queue, never re-entering the
        // terminal — same deferral discipline as the write-pty path (freeze fix).
        let bellCb: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?) -> Void = ghosttyBellCallback
        ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bellCb, to: UnsafeRawPointer.self))
        // PWD-changed effect (OSC 7 / OSC 9 / OSC 1337): like BELL, libghostty invokes
        // this synchronously inside vt_write (under our lock). The callback reads + COPIES
        // the borrowed pwd string here, then DISPATCHES to the main queue — never
        // re-entering the terminal / taking the controller lock (preserves the freeze fix).
        let pwdCb: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?) -> Void = ghosttyPwdChangedCallback
        ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, unsafeBitCast(pwdCb, to: UnsafeRawPointer.self))
    }

    deinit {
        if let t = terminal { ghostty_terminal_free(t) }
    }

    /// Apply a `term:theme` palette: override ANSI indices 0–15 plus the default
    /// foreground/background/cursor on the live terminal (`GHOSTTY_TERMINAL_OPT_COLOR_*`).
    /// A `nil` slot keeps libghostty's built-in colour for that entry; an all-nil palette
    /// resets the 16 ANSI colours to the built-in defaults. Takes the sink lock like any
    /// other terminal access — it is invoked from the renderer (main thread), never from
    /// the controller's feed stack, so it cannot re-enter `feed`.
    public func applyPalette(
        ansi: [TermRGB?], foreground: TermRGB?, background: TermRGB?, cursor: TermRGB?
    ) {
        lock.lock(); defer { lock.unlock() }
        guard let t = terminal else { return }

        // Start from the built-in default palette so unset theme slots reset cleanly,
        // then overlay indices 0–15 from the theme.
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        palette.withUnsafeMutableBufferPointer { buf in
            _ = ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, buf.baseAddress)
        }
        for i in 0..<min(16, ansi.count) {
            guard let c = ansi[i] else { continue }
            palette[i] = GhosttyColorRgb(r: c.r, g: c.g, b: c.b)
        }
        palette.withUnsafeBufferPointer { buf in
            _ = ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, buf.baseAddress)
        }

        setColor(t, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, foreground)
        setColor(t, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, background)
        setColor(t, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, cursor)
    }

    private func setColor(_ t: GhosttyTerminal, _ opt: GhosttyTerminalOption, _ rgb: TermRGB?) {
        guard let rgb else { return }
        var c = GhosttyColorRgb(r: rgb.r, g: rgb.g, b: rgb.b)
        withUnsafePointer(to: &c) { _ = ghostty_terminal_set(t, opt, $0) }
    }

    /// Copy of the terminal's CURRENT 256-color palette (theme + OSC overrides).
    /// The history layer hands this to scratch parses so indexed colors resolve
    /// to the same RGB values as the live pane.
    public func snapshotPalette() -> [GhosttyColorRgb]? {
        lock.lock(); defer { lock.unlock() }
        guard let t = terminal else { return nil }
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        let rc = palette.withUnsafeMutableBufferPointer { buf in
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, buf.baseAddress)
        }
        return rc == GHOSTTY_SUCCESS ? palette : nil
    }

    /// Set the renderer's cell size in pixels (used by the next `resize`).
    public func setCellPixelSize(width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        cellWidthPx = UInt32(max(0, width))
        cellHeightPx = UInt32(max(0, height))
    }

    public func feed(_ bytes: Data) { feed(bytes, replaying: false) }

    /// Replay historical (backfilled) bytes WITHOUT producing outward effects — see
    /// `replaying`. Used by the controller's backfill path so a reconnect/restart does not
    /// re-answer old terminal queries into the live pty or re-fire stale bells/notifications.
    public func feedBackfill(_ bytes: Data) { feed(bytes, replaying: true) }

    private func feed(_ bytes: Data, replaying replay: Bool) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        replaying = replay
        if let t = terminal {
            bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                ghostty_terminal_vt_write(t, base.assumingMemoryBound(to: UInt8.self), bytes.count)
            }
        }
        replaying = false
        // Scan for OSC events while still holding the lock (the scanner state is part of
        // the sink, and feed is the only writer), but DEFER firing the closures off this
        // stack — the bytes are decoded into value types first. Skip entirely while
        // replaying history so old OSC 9/777 notifications don't re-fire and an OSC 52 in
        // replayed output doesn't clobber the current clipboard.
        let events = replay ? [] : notificationScanner.scan(bytes)
        lock.unlock()
        onRender?()
        for event in events {
            switch event {
            case .notification(let n):
                DispatchQueue.main.async { [weak self] in self?.onNotification?(n.title, n.body) }
            case .clipboardCopy(let data):
                DispatchQueue.main.async { [weak self] in self?.onClipboardCopy?(data) }
            }
        }
    }

    public func clear() {
        // A `truncate` (circular wrap / clear) maps to a full terminal reset (RIS).
        lock.lock()
        if let t = terminal { ghostty_terminal_reset(t) }
        lock.unlock()
        onRender?()
    }

    public func setSize(cols: Int, rows: Int) {
        lock.lock()
        if let t = terminal {
            _ = ghostty_terminal_resize(t, UInt16(max(1, cols)), UInt16(max(1, rows)), cellWidthPx, cellHeightPx)
        }
        lock.unlock()
        onRender?()
    }

    /// Run `body` with exclusive, locked access to the terminal handle. The
    /// renderer uses this to `ghostty_render_state_update` + read the grid without
    /// racing a live `feed` (render.h requires exclusive access during update).
    public func withTerminal(_ body: (GhosttyTerminal) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if let t = terminal { body(t) }
    }
}

/// C write-pty callback: recovers the `GhosttySink` from `userdata` and forwards
/// the terminal's response bytes to `onOutput`. Invoked synchronously inside
/// `ghostty_terminal_vt_write` (under `GhosttySink.lock`); `onOutput` must not
/// re-enter the terminal (it ships the bytes to the pty via the transport).
private func ghosttyWritePtyCallback(
    _ terminal: GhosttyTerminal?,
    _ userdata: UnsafeMutableRawPointer?,
    _ data: UnsafePointer<UInt8>?,
    _ len: Int
) {
    guard let userdata, let data, len > 0 else { return }
    let sink = Unmanaged<GhosttySink>.fromOpaque(userdata).takeUnretainedValue()
    // Drop query responses generated while replaying backfilled history — see `replaying`.
    guard !sink.replaying else { return }
    sink.onOutput?(Data(bytes: data, count: len))
}

/// C bell callback: recovers the `GhosttySink` and DISPATCHES `onBell` to the main
/// queue. Invoked synchronously inside `ghostty_terminal_vt_write` (under
/// `GhosttySink.lock`); deferring off this stack mirrors `respondToPTY` so a bell can
/// never re-enter the terminal or take the controller lock (preserves the freeze fix).
private func ghosttyBellCallback(
    _ terminal: GhosttyTerminal?,
    _ userdata: UnsafeMutableRawPointer?
) {
    guard let userdata else { return }
    let sink = Unmanaged<GhosttySink>.fromOpaque(userdata).takeUnretainedValue()
    // Don't re-ring bells embedded in replayed history — see `replaying`.
    guard !sink.replaying else { return }
    DispatchQueue.main.async { sink.onBell?() }
}

/// C pwd-changed callback: recovers the `GhosttySink`, reads the new pwd via
/// `ghostty_terminal_get` (the terminal is passed in, and the borrowed string is only
/// valid until the next vt_write), decodes it to a path, and DISPATCHES `onPwdChanged`
/// to the main queue. Invoked synchronously inside `ghostty_terminal_vt_write` (under
/// `GhosttySink.lock`); reading is safe under the lock, and deferring the closure off
/// this stack mirrors the bell path so it can never re-enter the terminal / controller
/// lock (preserves the freeze fix).
private func ghosttyPwdChangedCallback(
    _ terminal: GhosttyTerminal?,
    _ userdata: UnsafeMutableRawPointer?
) {
    guard let userdata, let terminal else { return }
    let sink = Unmanaged<GhosttySink>.fromOpaque(userdata).takeUnretainedValue()
    var str = GhosttyString()
    guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_PWD, &str) == GHOSTTY_SUCCESS,
          let ptr = str.ptr, str.len > 0 else { return }
    let raw = String(decoding: UnsafeBufferPointer(start: ptr, count: str.len), as: UTF8.self)
    guard let path = TerminalPwd.path(fromReport: raw) else { return }
    DispatchQueue.main.async { sink.onPwdChanged?(path) }
}
#endif
