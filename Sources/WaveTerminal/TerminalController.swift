// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveTerminal — the terminal block controller. Implements PROTOCOL.md §4
// end-to-end and encodes GUARDS §T:
//   - ControllerResync on mount (with termsize, default 25x80).
//   - Subscribe to `blockfile` (scope `block:<id>`) BEFORE the backfill GET.
//   - Reconcile backfill + buffered/live appends by absolute offset (no dup/gap).
//   - fileop=truncate -> clear + reset; circular start clamp via the reconciler.
//   - Feed decoded (std base64) bytes into the sink (libghostty); send the sink's
//     key output back via ControllerInputCommand (std base64).
//   - Forward resize via ControllerInputCommand.termsize.
//   - Reconnect catch-up: re-backfill from the last consumed offset.
//
// Sources of truth: `controllerresync`/`controllerinput` (`pkg/wshrpc/wshclient/
// wshclient.go:170-178`), backfill `pkg/web/web.go:150-210`, append/truncate
// events `pkg/blockcontroller/blockcontroller.go:369-389`, FE order
// `frontend/app/view/term/termwrap.ts:382-448, 502-558`.

import Foundation
import WaveCore
import WaveProtocol
import WaveStore

/// Block-level constants for terminal blocks.
public enum TerminalBlockConst {
    /// `meta["view"]` value for a terminal block (`pkg/waveobj/metaconsts.go:9`).
    public static let viewType = "term"
}

/// wshrpc command names for the terminal controller (PROTOCOL.md §4).
public enum TerminalCommand {
    /// Start / create / restart the block's PTY controller
    /// (`wshclient.go:176`, `CommandControllerResyncData`).
    public static let resync = "controllerresync"
    /// Keystrokes / signals / resize (`wshclient.go:170`, `CommandBlockInputData`).
    public static let input = "controllerinput"
    /// Tear down the controller (`wshclient.go:164`, takes a blockid string).
    public static let destroy = "controllerdestroy"
    /// Persist block meta (`wshrpctypes.go` SetMetaCommand). Used to write `cmd:cwd` so a
    /// full restart respawns the durable shell in the last working directory.
    public static let setMeta = "setmeta"
    /// Full on-disk scrollback substring search (`wshserver_term.go`).
    public static let searchScrollback = "termsearchscrollback"
}

/// Where the live sink's coverage of the term file begins, recorded at mount.
/// The virtualized-history layer covers [fileStartIdx, sinkBaseOffset) plus —
/// once the sink starts pruning — a content-anchored seam past sinkBaseOffset.
public struct TermHistoryAnchor: Equatable, Sendable {
    /// First retained byte of the term file (`DataStartIdx`) at mount time.
    public let fileStartIdx: Int64
    /// Absolute byte offset the tail backfill began at — the initial seam.
    public let sinkBaseOffset: Int64
    /// Term-file size at mount time.
    public let fileSize: Int64
    /// Retained-relative logical line number at `sinkBaseOffset` (nil when the
    /// server had no line index for the file). Lines [0, sinkBaseLine) are the
    /// history layer's initial coverage.
    public let sinkBaseLine: Int64?
    /// Total flushed logical lines in the file at mount time.
    public let totalLines: Int64?

    public init(fileStartIdx: Int64, sinkBaseOffset: Int64, fileSize: Int64,
                sinkBaseLine: Int64? = nil, totalLines: Int64? = nil) {
        self.fileStartIdx = fileStartIdx
        self.sinkBaseOffset = sinkBaseOffset
        self.fileSize = fileSize
        self.sinkBaseLine = sinkBaseLine
        self.totalLines = totalLines
    }
}

/// Drives one terminal block: lifecycle, output reconciliation, and input.
///
/// Thread-safety: live `blockfile` events arrive on the transport's delivery
/// thread while `mount()`/`resize()`/`sendInput()` may be called from the UI.
/// A single lock serializes the reconciler AND the sink feeds so the merged byte
/// stream stays strictly ordered (GUARDS §T).
public final class TerminalController: @unchecked Sendable {
    public let blockId: String
    public let tabId: String

    /// Raised when this block's terminal rings the bell. Carries (blockId, tabId) so the
    /// coordinator can resolve the affected tab. Already on the main queue (the sink
    /// defers it off the vt_write/lock stack).
    public var onBell: ((_ blockId: String, _ tabId: String) -> Void)?

    /// Raised when this block emits an OSC 9 / OSC 777 desktop notification. Carries
    /// (blockId, tabId, title, body). Already on the main queue.
    public var onNotification: ((_ blockId: String, _ tabId: String, _ title: String?, _ body: String) -> Void)?

    /// Raised when this block emits an OSC 52 clipboard WRITE: the decoded contents to
    /// place on the pasteboard. Already on the main queue.
    public var onClipboardCopy: ((Data) -> Void)?

    /// The shell's last-reported working directory (OSC 7 / OSC 9 / OSC 1337), absolute
    /// path. nil until the shell first reports one. A split reads this so the new pane
    /// can start in the same directory. Updated on the main queue (the sink defers the
    /// PWD effect off the vt_write/lock stack); the property is read on the main thread
    /// by the composition root, so no extra locking is needed.
    public private(set) var currentCwd: String?

    /// Raised (on the main queue) when the history anchor is established after the
    /// mount-time tail backfill, or cleared by a truncate. The terminal view feeds
    /// this into its virtualized-history layer.
    public var onHistoryAnchorChanged: ((TermHistoryAnchor?) -> Void)?

    private let transport: WaveTransport
    private let sink: TerminalSink

    private let lock = NSLock()
    private var reconciler: TerminalReconciler
    /// Monotonic id of the latest catch-up (or unmount). A catch-up retry loop
    /// exits when a newer catch-up supersedes it. Guarded by `lock`.
    private var catchUpGen = 0
    /// True when a catch-up exhausted its retry budget with the reconciler still
    /// unloaded. In that state every live append buffers invisibly — a frozen
    /// pane with no recovery signal (no reconnect ever comes if the transport
    /// stayed up). The next live append rearms ONE fresh catch-up cycle, so the
    /// pane self-heals as soon as the shell produces output. Guarded by `lock`.
    private var catchUpAbandoned = false
    /// Catch-up retry budget/backoff; instance-level (defaults from
    /// `TerminalConst`) so tests can shrink them to milliseconds.
    var catchUpMaxAttempts = TerminalConst.catchUpMaxAttempts
    var catchUpRetryBaseMs = TerminalConst.catchUpRetryBaseMs
    var catchUpRetryCapMs = TerminalConst.catchUpRetryCapMs
    private var currentSize: TermSize
    /// Set once the view reports a real (laid-out) grid size via `resize`. The backfill
    /// MUST replay at the view's real width: a redrawing (\r-only) prompt fed at the wrong
    /// default width wraps differently, so each carriage-return lands on a wrapped
    /// continuation row instead of the line start and the redraws cascade into duplicated
    /// lines. So `mount()` waits for this before resync + backfill.
    private var haveRealSize = false
    private var subToken: SubscriptionToken?

    // Input coalescing: wavesrv dispatches each ControllerInput RPC in its own
    // goroutine and assigns the pty input sequence number INSIDE that goroutine
    // (`durableshellcontroller.go` getNextInputSeq), so near-simultaneous input
    // messages race and the bytes reach the pty out of order. Coalescing bursts
    // (a paste, or fast keystrokes that land in one runloop turn) into ONE message
    // keeps them ordered — the same thing xterm.js does (one onData per paste).
    private var inputBuffer = Data()
    private var inputFlushScheduled = false

    /// The history/live seam recorded by the mount-time tail backfill; nil until
    /// mount completes or after a truncate. Guarded by `lock`.
    private var _historyAnchor: TermHistoryAnchor?

    /// Raw newline bytes fed to the sink since the mount anchor (backfill +
    /// live appends). `sinkBaseLine + _newlinesFed` tracks the live end line in
    /// the same raw-\n line space as the backend line index. Guarded by `lock`.
    private var _newlinesFed: Int64 = 0

    /// - Parameters:
    ///   - initialSize: the size sent on the initial Resync; defaults to the
    ///     backend default `{rows:25, cols:80}` (GUARDS §T, `blockcontroller.go:358`).
    public init(
        blockId: String,
        tabId: String,
        transport: WaveTransport,
        sink: TerminalSink,
        initialSize: TermSize = .default
    ) {
        self.blockId = blockId
        self.tabId = tabId
        self.transport = transport
        self.sink = sink
        self.currentSize = initialSize
        self.reconciler = TerminalReconciler(startOffset: 0)
    }

    /// Forward a bell from the sink, stamping this controller's block/tab ids. Wired
    /// from `sink.onBell` in the composition root (like `sink.onOutput`).
    public func handleBell() {
        onBell?(blockId, tabId)
    }

    /// Forward an OSC desktop notification from the sink, stamping block/tab ids.
    public func handleNotification(title: String?, body: String) {
        onNotification?(blockId, tabId, title, body)
    }

    /// Forward an OSC 52 clipboard write from the sink. Wired from `sink.onClipboardCopy`
    /// in the composition root. Already on the main queue.
    public func handleClipboardCopy(_ data: Data) {
        onClipboardCopy?(data)
    }

    /// Record the shell's reported working directory (wired from `sink.onPwdChanged`).
    /// Already on the main queue. Also PERSIST it to the block's `cmd:cwd` meta so a full
    /// restart (which respawns a fresh durable shell from that meta) reopens in the same
    /// directory rather than $HOME. Deduped to the prompts where the cwd actually changes
    /// so we don't write meta on every prompt redraw.
    public func handlePwdChanged(_ cwd: String) {
        guard cwd != currentCwd else { return }
        currentCwd = cwd
        let data = CommandSetMetaData(oref: ORef.block(blockId), meta: ["cmd:cwd": .string(cwd)])
        Task { [transport] in try? await transport.callVoid(command: TerminalCommand.setMeta, data: data) }
    }

    /// The block's term-file zone id is the block id (PROTOCOL.md §4).
    private var zoneId: String { blockId }

    /// The blockfile subscription scope is the block oref string (GUARDS §T / §B).
    private var blockScope: String { ORef.block(blockId).string }

    /// Absolute offset of the next byte we expect — the reconnect catch-up anchor.
    public var currentOffset: Int64 {
        lock.lock(); defer { lock.unlock() }
        return reconciler.absOffset
    }

    /// The history/live seam recorded at mount (nil before mount / after truncate).
    public var historyAnchor: TermHistoryAnchor? {
        lock.lock(); defer { lock.unlock() }
        return _historyAnchor
    }

    /// The live end's logical line number (raw-\n space, matching the backend
    /// line index): the anchor's seam line plus every newline fed since. nil
    /// until the anchor exists or when the server had no line index.
    public var currentEndLine: Int64? {
        lock.lock(); defer { lock.unlock() }
        guard let base = _historyAnchor?.sinkBaseLine else { return nil }
        return base + _newlinesFed
    }

    // MARK: - History layer support (virtualized scrollback)

    /// Fetch raw term-file bytes for a history chunk by logical line range.
    /// Returns the body plus the absolute byte offset / line number it starts at.
    public func fetchHistoryLines(startLine: Int64, numLines: Int64) async throws -> FileFetchResult {
        try await transport.fetchFileRange(
            zoneId: zoneId, name: WaveProtocolConst.blockFileTerm,
            range: .lines(start: startLine, count: numLines))
    }

    /// Fetch raw term-file bytes for a history chunk by byte range.
    public func fetchHistoryBytes(offset: Int64, count: Int64) async throws -> FileFetchResult {
        try await transport.fetchFileRange(
            zoneId: zoneId, name: WaveProtocolConst.blockFileTerm,
            range: .bytes(offset: offset, count: count))
    }

    /// The ENTIRE on-disk buffer as ANSI-stripped plain text (one line per
    /// logical line) -- the Cmd-A "copy full buffer" path. Streamed and
    /// stripped server-side, so it works regardless of which history chunks
    /// are parsed locally.
    public func fetchFullPlainText() async throws -> String {
        let result = try await transport.fetchFileRange(
            zoneId: zoneId, name: WaveProtocolConst.blockFileTerm,
            range: FileFetchRange(offset: 0, stripAnsi: true))
        return Self.ensureStripped(result.data)
    }

    /// A logical-line range of the on-disk buffer as ANSI-stripped plain text.
    /// Fallback copy path for huge history selections.
    public func fetchPlainText(startLine: Int64, numLines: Int64) async throws -> String {
        let result = try await transport.fetchFileRange(
            zoneId: zoneId, name: WaveProtocolConst.blockFileTerm,
            range: FileFetchRange(startLine: startLine, numLines: numLines, stripAnsi: true))
        return Self.ensureStripped(result.data)
    }

    /// A wavesrv that predates the `stripansi` param returns RAW VT bytes for
    /// these fetches; pasting those puts invisible ESC bytes + sequence bodies
    /// on the clipboard. Detect leftover escapes and strip client-side
    /// (mirrors pkg/util/ansistrip's state machine, lone-\r line splits incl).
    static func ensureStripped(_ data: Data) -> String {
        guard data.contains(0x1b) || data.contains(0x0d) else {
            return String(decoding: data, as: UTF8.self)
        }
        enum St { case ground, esc, csi, osc, oscEsc, str, strEsc }
        var st = St.ground
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        var sawCR = false
        for b in data {
            switch st {
            case .esc:
                switch b {
                case UInt8(ascii: "["): st = .csi
                case UInt8(ascii: "]"): st = .osc
                case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"): st = .str
                default: st = .ground
                }
                continue
            case .csi:
                if b >= 0x40, b <= 0x7e { st = .ground }
                continue
            case .osc:
                if b == 0x07 { st = .ground } else if b == 0x1b { st = .oscEsc }
                continue
            case .oscEsc:
                st = b == UInt8(ascii: "\\") ? .ground : .osc
                continue
            case .str:
                if b == 0x1b { st = .strEsc }
                continue
            case .strEsc:
                st = b == UInt8(ascii: "\\") ? .ground : .str
                continue
            case .ground:
                break
            }
            switch b {
            case 0x1b:
                st = .esc
                sawCR = false
            case 0x0a:
                if sawCR {
                    sawCR = false
                } else {
                    out.append(0x0a)
                }
            case 0x0d:
                out.append(0x0a)
                sawCR = true
            case 0x09:
                out.append(b)
                sawCR = false
            case 0x20...0x7e, 0x80...:
                out.append(b)
                sawCR = false
            default:
                sawCR = false
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Full on-disk scrollback search (backend `termsearchscrollback`).
    public func searchScrollback(query: String, caseSensitive: Bool = false) async throws -> CommandTermSearchScrollbackRtnData {
        let data = CommandTermSearchScrollbackData(
            blockid: blockId, query: query,
            casesensitive: caseSensitive ? true : nil, maxresults: nil)
        return try await transport.call(command: TerminalCommand.searchScrollback, data: data)
    }

    // MARK: - Mount (PROTOCOL.md §4 lifecycle, GUARDS §T order)

    /// Bring the terminal online:
    ///   1. Subscribe to `blockfile` (scope `block:<id>`) — FIRST, so appends that
    ///      race the backfill are buffered (GUARDS §T).
    ///   2. Wait for the view's first real grid size so the replay width is correct.
    ///   3. ControllerResync to start the PTY (carries the real termsize).
    ///   4. TAIL backfill GET (last ~2MB) and reconcile (replayed at the real
    ///      width). Older history is paged on demand by the history layer, so a
    ///      multi-hundred-MB term file no longer replays through the sink.
    public func mount() async throws {
        subscribeBlockFile()
        // Replay the backfill at the view's REAL width (see `haveRealSize`): otherwise a
        // redrawing prompt's carriage-returns cascade into duplicated lines. Subscribe
        // stays FIRST (GUARDS §T), so appends racing the wait are still buffered.
        await awaitFirstRealSize()
        // The resync fails while the block's remote connection is down (backend:
        // "cannot start shellproc: not connected") — a certainty right after an app
        // restart, since nothing has connected the SSH conn yet. The persisted
        // scrollback must replay regardless, or the restored pane sits black until
        // the shell emits fresh bytes. So: backfill unconditionally, rethrow after.
        var resyncError: Error?
        do {
            try await resync(forceRestart: false)
        } catch {
            resyncError = error
        }
        try await tailBackfill()
        if let resyncError { throw resyncError }
    }

    /// Poll until the view reports its real grid size (`resize`) or a grace timeout
    /// elapses. Polling keeps the lock interaction trivial and always terminates; the
    /// common case resolves within a frame or two. The timeout is a safety net so a
    /// never-laid-out view still loads (at the default width).
    private func awaitFirstRealSize(timeoutMs: Int = 1500) async {
        var waitedMs = 0
        while true {
            lock.lock(); let ready = haveRealSize; lock.unlock()
            if ready || waitedMs >= timeoutMs { return }
            try? await Task.sleep(nanoseconds: 15_000_000)
            waitedMs += 15
        }
    }

    /// Cancel the blockfile subscription. Does NOT destroy the backend controller
    /// (other clients / a remount may reuse it); call `destroy()` for that.
    public func unmount() {
        lock.lock()
        let token = subToken
        subToken = nil
        // Stop any in-flight catch-up retry loop (it checks the generation after
        // each backoff sleep) so a closed pane's controller can deallocate.
        catchUpGen += 1
        // A stale abandoned flag must not survive into a remount: an append racing
        // the next mount's tail backfill would rearm a catch-up that fights the
        // mount path for the reconciler (and drops the history anchor).
        catchUpAbandoned = false
        lock.unlock()
        token?.cancel()
    }

    /// Explicitly tear down the backend PTY controller for this block.
    public func destroy() {
        unmount()
        try? transport.notify(command: TerminalCommand.destroy, data: blockId, route: WaveRoute.defaultRoute)
    }

    /// Force-restart the backend PTY (Electron "Force Restart Controller"). Issues a
    /// `controllerresync` with `forcerestart`; the backend recreates the controller
    /// and truncates the term file, whose `fileop=truncate` event clears the local
    /// sink + reconciler (see `ingestTruncate`), so the screen resets to a fresh pty.
    public func forceRestart() {
        Task { [weak self] in try? await self?.resync(forceRestart: true) }
    }

    // MARK: - Reconnect catch-up (GUARDS §A re-subscribe + §T offset)

    /// After a WS reconnect, the transport re-announces the route and re-registers
    /// our subscription automatically (GUARDS §A). We still must catch up the bytes
    /// produced while the socket was down: re-backfill from our last consumed
    /// offset. The reconciler is reset so appends racing this GET are buffered.
    public func handleReconnect() async throws {
        await catchUp()
    }

    /// Run one catch-up: swap in a fresh reconciler, then backfill — retrying with
    /// backoff until the backfill loads. The retry is NOT optional resilience: a
    /// failed catch-up leaves the fresh reconciler unloaded, which buffers every
    /// future append invisibly (a permanently frozen pane whose shell keeps
    /// running). The loop exits when a newer catch-up / unmount supersedes it
    /// (generation check) or the bounded retry budget runs out — in which case the
    /// next reconnect starts a fresh catch-up from the same (unconsumed) offset.
    private func catchUp() async {
        // Capture the catch-up offset AND swap in a fresh (unloaded) reconciler in a
        // SINGLE critical section. The transport re-subscribes `blockfile` and flips
        // `_connected` before this runs, so a live append can race us here: doing the
        // read+reset atomically guarantees any such append lands in the fresh
        // reconciler's buffer (it is `!loaded`) and is reconciled by content-overlap
        // in `applyBackfill` — never delivered against the stale loaded reconciler at
        // the wrong offset (which would dup or mis-anchor the catch-up).
        let (gen, offset) = beginCatchUp()
        for attempt in 1...catchUpMaxAttempts {
            do {
                try await backfill(from: offset)
                return
            } catch {
                if attempt == catchUpMaxAttempts {
                    markCatchUpAbandoned(gen)
                    return
                }
                let delayMs = min(
                    catchUpRetryBaseMs << (attempt - 1),
                    catchUpRetryCapMs)
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                if Task.isCancelled || isCatchUpSuperseded(gen) { return }
            }
        }
    }

    private func beginCatchUp() -> (gen: Int, offset: Int64) {
        lock.lock(); defer { lock.unlock() }
        catchUpGen += 1
        catchUpAbandoned = false
        let offset = reconciler.absOffset
        reconciler = TerminalReconciler(startOffset: offset)
        return (catchUpGen, offset)
    }

    /// Only the catch-up that is still the CURRENT one may flag abandonment —
    /// a superseded loop's failure says nothing about the successor's state.
    private func markCatchUpAbandoned(_ gen: Int) {
        lock.lock(); defer { lock.unlock() }
        guard gen == catchUpGen, !reconciler.loaded else { return }
        catchUpAbandoned = true
    }

    private func isCatchUpSuperseded(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen != catchUpGen || reconciler.loaded
    }

    /// After the block's REMOTE connection transitions to connected: re-issue the
    /// resync (the mount-time one failed while the conn was down, so no shell ever
    /// started) and catch up bytes appended while the pane wasn't streaming. A
    /// reattached durable job resumes at the term-file's size — only NEW bytes flow —
    /// so without this the restored pane stays stale until the shell prints again.
    public func handleConnectionUp() async throws {
        try await resync(forceRestart: false)
        await catchUp()
    }

    // MARK: - Input (GUARDS §T: std base64)

    /// Ship raw bytes (typically libghostty's key-encoded output) to the PTY.
    /// Bytes are buffered and flushed once per runloop turn so a burst becomes one
    /// ordered ControllerInput (see `inputBuffer` — avoids the server's per-message
    /// input-seq race).
    public func sendInput(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        inputBuffer.append(data)
        let needsSchedule = !inputFlushScheduled
        inputFlushScheduled = true
        lock.unlock()
        guard needsSchedule else { return }
        DispatchQueue.main.async { [weak self] in self?.flushInput() }
    }

    /// Send a VT query response (DA/DSR/cursor-position/size report) back to the pty.
    /// The sink emits these SYNCHRONOUSLY from inside `feed()` while `lock` is held (see
    /// the ingest helpers), so this must NOT re-take `lock` on that stack — NSLock is not
    /// reentrant, and doing so deadlocks the delivery thread and freezes any full-screen
    /// TUI that queries the terminal (vim/top/claude). Deferring the send off the current
    /// stack breaks the reentrancy.
    public func respondToPTY(_ data: Data) {
        guard !data.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in self?.sendInput(data) }
    }

    /// Flush all buffered input as a single ControllerInput frame.
    public func flushInput() {
        lock.lock()
        let data = inputBuffer
        inputBuffer.removeAll(keepingCapacity: true)
        inputFlushScheduled = false
        lock.unlock()
        guard !data.isEmpty else { return }
        sendInputPayload(CommandBlockInputData(blockid: blockId, inputdata64: WaveBase64.encode(data)))
    }

    /// Convenience: send a UTF-8 string.
    public func sendText(_ text: String) { sendInput(Data(text.utf8)) }

    /// Send a signal by name (e.g. `"SIGINT"`).
    public func sendSignal(_ signame: String) {
        sendInputPayload(CommandBlockInputData(blockid: blockId, signame: signame))
    }

    /// Forward a resize: persist `currentSize` (for the next Resync) and notify the
    /// PTY via `ControllerInputCommand.termsize` (PROTOCOL.md §4 "Resize").
    public func resize(_ size: TermSize) {
        lock.lock()
        currentSize = size
        haveRealSize = true
        lock.unlock()
        sink.setSize(cols: size.cols, rows: size.rows)
        sendInputPayload(CommandBlockInputData(blockid: blockId, termsize: size))
    }

    private func sendInputPayload(_ payload: CommandBlockInputData) {
        // Fire-and-forget keeps keystroke latency low and preserves order (a single
        // ws write queue). ControllerInputCommand returns no payload upstream.
        try? transport.notify(command: TerminalCommand.input, data: payload, route: WaveRoute.defaultRoute)
    }

    // MARK: - Internals

    private func snapshotSize() -> TermSize {
        lock.lock(); defer { lock.unlock() }
        return currentSize
    }

    private func resync(forceRestart: Bool) async throws {
        let size = snapshotSize()
        let data = CommandControllerResyncData(
            forcerestart: forceRestart ? true : nil,
            tabid: tabId,
            blockid: blockId,
            rtopts: RuntimeOpts(termsize: size))
        try await transport.callVoid(command: TerminalCommand.resync, data: data)
    }

    private func backfill(from offset: Int64) async throws {
        let (data, info) = try await transport.fetchFile(zoneId: zoneId, name: WaveProtocolConst.blockFileTerm, offset: offset)
        try ingestBackfill(data: data, info: info)
    }

    private func tailBackfill() async throws {
        let result = try await transport.fetchFileRange(
            zoneId: zoneId, name: WaveProtocolConst.blockFileTerm,
            range: .tail(TerminalConst.tailBackfillBytes))
        ingestTailBackfill(result)
    }

    private func subscribeBlockFile() {
        let request = SubscriptionRequest(event: WaveEventName.blockFile, scopes: [blockScope])
        let token = transport.subscribe(request) { [weak self] event in
            self?.handleFileEvent(event)
        }
        lock.lock()
        subToken = token
        lock.unlock()
    }

    private func handleFileEvent(_ event: WaveEvent) {
        guard event.event == WaveEventName.blockFile, let payload = event.data else { return }
        guard let fileEvent = try? payload.decode(WSFileEventData.self) else { return }
        guard fileEvent.zoneid == zoneId, fileEvent.filename == WaveProtocolConst.blockFileTerm else { return }

        switch fileEvent.fileop {
        case FileOp.append:
            guard let bytes = WaveBase64.decode(fileEvent.data64) else {
                assertionFailure("blockfile append data64 was not std base64 (GUARDS §T)")
                return
            }
            ingestAppend(bytes)
        case FileOp.truncate:
            ingestTruncate()
        case FileOp.create:
            // File created; no bytes. Benign — the backfill GET reads contents.
            break
        default:
            // GUARDS §T: unknown fileop is a hard error in debug.
            assertionFailure("unknown blockfile fileop \"\(fileEvent.fileop)\" (GUARDS §T)")
        }
    }

    // The three `ingest*` helpers hold `lock` across BOTH the reconciler mutation
    // and the sink feed, so the byte stream the sink sees is strictly ordered even
    // when a live event races the backfill (GUARDS §T).

    private func ingestAppend(_ data: Data) {
        lock.lock()
        let out = reconciler.append(data)
        if !out.isEmpty {
            _newlinesFed += Int64(out.reduce(0) { $1 == 0x0a ? $0 + 1 : $0 })
            sink.feed(out)
        }
        // Rearm after an abandoned catch-up: this append just buffered invisibly
        // (unloaded reconciler) and no retry loop is coming. One fresh cycle per
        // rearm; `beginCatchUp` clears the flag so a failing backend can't spawn
        // a loop per append.
        let rearm = out.isEmpty && !reconciler.loaded && catchUpAbandoned && subToken != nil
        if rearm { catchUpAbandoned = false }
        lock.unlock()
        guard rearm else { return }
        Task { [weak self] in await self?.catchUp() }
    }

    private func ingestTruncate() {
        lock.lock()
        reconciler.truncate()
        sink.clear()
        _historyAnchor = nil
        _newlinesFed = 0
        let handler = onHistoryAnchorChanged
        lock.unlock()
        DispatchQueue.main.async { handler?(nil) }
    }

    private func ingestBackfill(data: Data, info: WaveFile) throws {
        lock.lock(); defer { lock.unlock() }
        // Overlapping catch-up backfills race here: a second WS reconnect (common on
        // sleep/wake flapping) fires another `handleReconnect` whose `beginCatchUp`
        // resets the reconciler from the SAME unconsumed offset, so both GETs cover
        // the same byte range. Whichever ingest lands first reconciles; the other is a
        // pure duplicate. Drop it — feeding it to `applyBackfill` would trip its
        // single-load precondition and SIGTRAP the app (a silent background crash).
        guard !reconciler.loaded else { return }
        do {
            let out = try reconciler.applyBackfill(data: data, info: info)
            // Replay path: suppress query responses + stale bells so a reconnect/restart
            // doesn't inject DA/DSR/XTVERSION replies at the live shell prompt.
            if !out.isEmpty {
                _newlinesFed += Int64(out.reduce(0) { $1 == 0x0a ? $0 + 1 : $0 })
                sink.feedBackfill(out)
            }
        } catch {
            // A reconcile fault (usually a torn read racing a truncate) must be loud
            // in debug. In release, RETHROW so the catch-up retry re-fetches: the
            // malformed backfill used to be dropped here, which left the reconciler
            // unloaded forever — a permanently frozen pane buffering all output.
            assertionFailure("terminal backfill reconcile failed: \(error)")
            throw error
        }
    }

    private func ingestTailBackfill(_ result: FileFetchResult) {
        lock.lock()
        // A reconnect racing the initial mount can reconcile the reconciler before this
        // mount-time tail backfill lands (see `ingestBackfill`). Applying it now would
        // trip `applyTailBackfill`'s single-load precondition and crash; drop it (the
        // reconnect backfill already fed the bytes — only the history anchor is skipped,
        // and a later remount/truncate re-establishes it).
        guard !reconciler.loaded else { lock.unlock(); return }
        var anchor: TermHistoryAnchor?
        do {
            let (out, actualStart) = try reconciler.applyTailBackfill(data: result.data, info: result.info)
            anchor = TermHistoryAnchor(
                fileStartIdx: result.info.dataStartIdx,
                sinkBaseOffset: actualStart,
                fileSize: result.info.size,
                sinkBaseLine: result.startLine,
                totalLines: result.totalLines)
            _historyAnchor = anchor
            _newlinesFed = Int64(out.reduce(0) { $1 == 0x0a ? $0 + 1 : $0 })
            if !out.isEmpty { sink.feedBackfill(out) }
        } catch {
            assertionFailure("terminal tail backfill reconcile failed: \(error)")
        }
        let handler = onHistoryAnchorChanged
        lock.unlock()
        if let anchor {
            DispatchQueue.main.async { handler?(anchor) }
        }
    }
}
