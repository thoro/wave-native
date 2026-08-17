// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveTerminal tests — exhaustively exercise the terminal output reconciler
// (PROTOCOL.md §4 / GUARDS §T, the keystone guard): subscribe-before-backfill
// overlap, >2 MB circular wrap, truncate, reconnect catch-up, the circular start
// clamp, std-base64 input encoding, resize forwarding, and the
// subscribe-BEFORE-backfill ordering. The reconciler is tested directly with a
// CapturingTerminalSink; the controller is tested against a MockTransport.

import XCTest
import WaveCore
@testable import WaveTerminal

private func termFile(size: Int64, maxsize: Int64 = TerminalConst.termFileMaxSize) -> WaveFile {
    WaveFile(
        zoneid: "zone",
        name: WaveProtocolConst.blockFileTerm,
        opts: FileOpts(maxsize: maxsize, circular: true),
        createdts: 0,
        size: size,
        modts: 0)
}

private func d(_ s: String) -> Data { Data(s.utf8) }
private func s(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

// MARK: - Reconciler (pure, GUARDS §T)

final class TerminalReconcilerTests: XCTestCase {

    func testSimpleBackfillThenLive() throws {
        var r = TerminalReconciler(startOffset: 0)
        let out = try r.applyBackfill(data: d("hello"), info: termFile(size: 5))
        XCTAssertEqual(s(out), "hello")
        XCTAssertTrue(r.loaded)
        XCTAssertEqual(r.absOffset, 5)

        let live = r.append(d("world"))
        XCTAssertEqual(s(live), "world")
        XCTAssertEqual(r.absOffset, 10)
    }

    /// Appends that race the GET: "AB" is already in the backfill (dup, discard),
    /// "CD" landed after the server Stat (new). Result must be exactly "ABCD".
    func testSubscribeBeforeBackfillOverlapNoDupNoGap() throws {
        var r = TerminalReconciler(startOffset: 0)
        XCTAssertTrue(r.append(d("AB")).isEmpty) // buffered while !loaded
        XCTAssertTrue(r.append(d("CD")).isEmpty)

        let out = try r.applyBackfill(data: d("AB"), info: termFile(size: 2))
        XCTAssertEqual(s(out), "ABCD")
        XCTAssertEqual(r.absOffset, 4)
    }

    /// A single buffered append that straddles the Stat boundary: backfill captured
    /// only its first half; the reconciler must drop the overlap and keep the tail.
    func testPartialOverlapStraddlesBoundary() throws {
        var r = TerminalReconciler(startOffset: 0)
        XCTAssertTrue(r.append(d("ABCD")).isEmpty)
        let out = try r.applyBackfill(data: d("AB"), info: termFile(size: 2))
        XCTAssertEqual(s(out), "ABCD")
        XCTAssertEqual(r.absOffset, 4)
    }

    /// >2 MB burst forces a circular wrap: DataStartIdx > 0, a GET from offset 0 is
    /// clamped, and the reconciler recomputes the offset from the returned info
    /// rather than assuming offset 0 was honored (GUARDS §T clamp).
    func testCircularWrapClampRecompute() throws {
        let max = TerminalConst.termFileMaxSize
        let size = max + 1000 // 1000 bytes have scrolled out of the circular buffer
        var r = TerminalReconciler(startOffset: 0)
        let backfill = Data(count: Int(max)) // server returns Size - DataStartIdx == max
        let out = try r.applyBackfill(data: backfill, info: termFile(size: size))
        XCTAssertEqual(out.count, Int(max))
        XCTAssertEqual(r.absOffset, size) // recomputed to Size, not 0 + max

        let live = r.append(d("X"))
        XCTAssertEqual(s(live), "X")
        XCTAssertEqual(r.absOffset, size + 1)
    }

    func testTruncateClearsAndResetsOffset() throws {
        var r = TerminalReconciler(startOffset: 0)
        _ = try r.applyBackfill(data: d("abc"), info: termFile(size: 3))
        XCTAssertEqual(r.absOffset, 3)

        r.truncate()
        XCTAssertEqual(r.absOffset, 0)
        XCTAssertTrue(r.loaded) // still loaded; truncate is a live event

        let live = r.append(d("Z"))
        XCTAssertEqual(s(live), "Z")
        XCTAssertEqual(r.absOffset, 1)
    }

    /// Reconnect: a fresh reconciler seeded at the last consumed offset (10). "b1"
    /// was produced during the outage and is captured by the catch-up GET (dup of
    /// the buffered copy -> discard); "b2" landed after Stat (new).
    func testReconnectCatchUpFromOffset() throws {
        var r = TerminalReconciler(startOffset: 10)
        XCTAssertEqual(r.absOffset, 10)
        XCTAssertTrue(r.append(d("b1")).isEmpty)
        XCTAssertTrue(r.append(d("b2")).isEmpty)

        // GET offset=10 returns [10, 12) == "b1".
        let out = try r.applyBackfill(data: d("b1"), info: termFile(size: 12))
        XCTAssertEqual(s(out), "b1b2")
        XCTAssertEqual(r.absOffset, 14)
    }

    func testBackfillLengthMismatchThrows() {
        var r = TerminalReconciler(startOffset: 0)
        XCTAssertThrowsError(try r.applyBackfill(data: d("abc"), info: termFile(size: 5))) { err in
            guard case WaveError.terminalReconcile = err else {
                return XCTFail("expected terminalReconcile, got \(err)")
            }
        }
    }

    func testStaleOffsetOlderThanStartIsClampedNotDuplicated() throws {
        // GET from an offset (500) older than DataStartIdx (1000): the server
        // serves from DataStartIdx; we must trust the returned info.
        let max = TerminalConst.termFileMaxSize
        let size = max + 1000 // DataStartIdx == 1000
        var r = TerminalReconciler(startOffset: 500)
        let backfill = Data(count: Int(size - 1000)) // Size - max(500, 1000) == Size - 1000
        let out = try r.applyBackfill(data: backfill, info: termFile(size: size))
        XCTAssertEqual(Int64(out.count), size - 1000)
        XCTAssertEqual(r.absOffset, size)
    }
}

// MARK: - Sink

final class TerminalSinkTests: XCTestCase {
    func testCapturingSinkRecordsClearsAndSize() {
        let sink = CapturingTerminalSink()
        sink.feed(d("abc"))
        sink.feed(d("def"))
        XCTAssertEqual(s(sink.received), "abcdef")
        sink.clear()
        XCTAssertEqual(sink.clearCount, 1)
        XCTAssertEqual(sink.received.count, 0)
        sink.setSize(cols: 100, rows: 30)
        XCTAssertEqual(sink.lastSize, TermGridSize(cols: 100, rows: 30))
    }
}

// MARK: - Pwd report parsing (OSC 7 file:// URI → path)
//
// The libghostty PWD-changed effect wiring (GhosttySink registering
// GHOSTTY_TERMINAL_OPT_PWD_CHANGED and dispatching `onPwdChanged`) is integration-only
// — it needs a live `GhosttyTerminal` and real OSC 7 bytes — so it is exercised by the
// app, not here. This covers the PURE decode that the callback applies before dispatch.
final class TerminalPwdTests: XCTestCase {
    func testFileURIWithHostStripsHostAndDecodes() {
        XCTAssertEqual(TerminalPwd.path(fromReport: "file://mymac.local/Users/me/project"),
                       "/Users/me/project")
    }

    func testFileURIEmptyAuthority() {
        XCTAssertEqual(TerminalPwd.path(fromReport: "file:///Users/me/project"),
                       "/Users/me/project")
    }

    func testFileURIPercentDecodesPath() {
        XCTAssertEqual(TerminalPwd.path(fromReport: "file://localhost/Users/me/my%20dir/a%2Bb"),
                       "/Users/me/my dir/a+b")
    }

    func testBareAbsolutePathPassesThrough() {
        // OSC 9 / OSC 1337 report a bare path.
        XCTAssertEqual(TerminalPwd.path(fromReport: "/var/log"), "/var/log")
    }

    func testEmptyOrClearedReportIsNil() {
        XCTAssertNil(TerminalPwd.path(fromReport: ""))
        XCTAssertNil(TerminalPwd.path(fromReport: "   \n"))
    }

    func testNonAbsoluteNonFileReportIsNil() {
        XCTAssertNil(TerminalPwd.path(fromReport: "relative/path"))
        XCTAssertNil(TerminalPwd.path(fromReport: "http://example.com/x"))
    }
}

// MARK: - Controller (against MockTransport)

/// A sink whose `feed` runs a callback synchronously — reproduces a VT query response
/// (DA/DSR) arriving during feed() while the controller lock is held.
final class ReentrantSink: TerminalSink {
    var onFeed: ((Data) -> Void)?
    func feed(_ bytes: Data) { onFeed?(bytes) }
    func clear() {}
    func setSize(cols: Int, rows: Int) {}
}

final class TerminalControllerTests: XCTestCase {

    /// A query response emitted during feed() must NOT deadlock the controller. The sink
    /// fires the response synchronously while `lock` is held; `respondToPTY` must defer
    /// rather than re-take the (non-reentrant) lock. With a direct `sendInput`, the
    /// `fireAppend` below would deadlock the test thread and hang — freezing a real
    /// querying TUI (vim/top/claude). Reaching the assertion proves the fix.
    func testQueryResponseDuringFeedDoesNotDeadlock() async throws {
        let t = MockTransport()
        t.cannedBackfill = (d(""), termFile(size: 0))
        let sink = ReentrantSink()
        let ctrl = TerminalController(blockId: blockId, tabId: tabId, transport: t, sink: sink)
        // Simulate libghostty emitting a DSR cursor-position response (ESC[1;1R) mid-feed.
        sink.onFeed = { [weak ctrl] _ in ctrl?.respondToPTY(Data([0x1b, 0x5b, 0x31, 0x3b, 0x31, 0x52])) }
        ctrl.resize(TermSize.default) // the view sizes the terminal before mount replays
        try await ctrl.mount()

        t.fireAppend("hello") // ingestAppend holds `lock` -> feed -> onFeed -> respondToPTY
        // No deadlock: the lock is free, so this lock-protected accessor returns.
        XCTAssertEqual(ctrl.currentOffset, 5)
    }

    /// Context-menu "Clear" must truncate the buffer (termclearbuffer), NOT
    /// restart the shell (a forcerestart resync kills the running session).
    func testClearBufferSendsTruncateNotRestart() async throws {
        let t = MockTransport()
        let ctrl = TerminalController(blockId: blockId, tabId: tabId, transport: t, sink: CapturingTerminalSink())
        ctrl.clearBuffer()
        for _ in 0..<100 {
            if t.order.contains(TerminalCommand.clearBuffer) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(t.order.contains(TerminalCommand.clearBuffer))
        XCTAssertFalse(t.order.contains("resync"))
    }

    func testMountSubscribesBeforeBackfill() async throws {
        let t = MockTransport()
        t.cannedBackfill = (d(""), termFile(size: 0))
        let ctrl = TerminalController(blockId: blockId, tabId: tabId, transport: t, sink: CapturingTerminalSink())
        ctrl.resize(TermSize.default)
        try await ctrl.mount()
        // GUARDS §T: subscribe must precede the backfill GET; resync starts the PTY.
        XCTAssertEqual(t.order, ["subscribe", "resync", "backfill"])
    }

    func testMountSendsViewSizeOnResync() async throws {
        let t = MockTransport()
        t.cannedBackfill = (d(""), termFile(size: 0))
        let ctrl = TerminalController(blockId: blockId, tabId: tabId, transport: t, sink: CapturingTerminalSink())
        ctrl.resize(TermSize(rows: 50, cols: 120))
        try await ctrl.mount()
        let resync = try XCTUnwrap(t.lastResync?.decode(CommandControllerResyncData.self))
        // Resync carries the view's REAL size — the backfill must replay at that width so a
        // redrawing prompt's carriage-returns collapse instead of cascading (duplicated lines).
        XCTAssertEqual(resync.rtopts?.termsize, TermSize(rows: 50, cols: 120))
        XCTAssertEqual(resync.blockid, blockId)
        XCTAssertEqual(resync.tabid, tabId)
    }

    /// Regression (duplicated/mangled backfill): mount must not resync+replay until the
    /// view reports its real grid size. A resize delivered AFTER mount starts unblocks the
    /// replay, and resync carries that size (so the backfill replays at the real width).
    /// Awaiting the task gives the happens-before edge for reading the transport.
    func testMountWaitsForRealSizeBeforeReplaying() async throws {
        let t = MockTransport()
        t.cannedBackfill = (d(""), termFile(size: 0))
        let ctrl = TerminalController(blockId: blockId, tabId: tabId, transport: t, sink: CapturingTerminalSink())
        let mountTask = Task { try await ctrl.mount() }
        ctrl.resize(TermSize(rows: 40, cols: 110))
        try await mountTask.value
        XCTAssertEqual(t.order, ["subscribe", "resync", "backfill"])
        let resync = try XCTUnwrap(t.lastResync?.decode(CommandControllerResyncData.self))
        XCTAssertEqual(resync.rtopts?.termsize, TermSize(rows: 40, cols: 110))
    }

    /// End-to-end overlap through the controller: appends fire DURING the backfill
    /// fetch (buffered), then a live append after load. The sink's bytes must equal
    /// the shell's stream exactly: "AB" + "CD" (new) + "EF".
    func testControllerOverlapReconcilesToExactStream() async throws {
        let t = MockTransport()
        let sink = CapturingTerminalSink()
        t.cannedBackfill = (d("AB"), termFile(size: 2))
        t.beforeFetchReturn = { [weak t] in
            t?.fireAppend("AB") // already in backfill -> dup
            t?.fireAppend("CD") // after Stat -> new
        }
        let ctrl = TerminalController(blockId: blockId, tabId: tabId, transport: t, sink: sink)
        ctrl.resize(TermSize.default)
        try await ctrl.mount()
        XCTAssertEqual(s(sink.received), "ABCD")

        t.fireAppend("EF") // live, post-load
        XCTAssertEqual(s(sink.received), "ABCDEF")
        XCTAssertEqual(ctrl.currentOffset, 6)
    }

    func testTruncateEventClearsSink() async throws {
        let t = MockTransport()
        let sink = CapturingTerminalSink()
        t.cannedBackfill = (d("hello"), termFile(size: 5))
        let ctrl = TerminalController(blockId: blockId, tabId: tabId, transport: t, sink: sink)
        ctrl.resize(TermSize.default)
        try await ctrl.mount()
        XCTAssertEqual(s(sink.received), "hello")

        t.fireTruncate()
        XCTAssertEqual(sink.clearCount, 1)
        XCTAssertEqual(sink.received.count, 0)
        XCTAssertEqual(ctrl.currentOffset, 0)

        t.fireAppend("new")
        XCTAssertEqual(s(sink.received), "new")
    }

    func testSendInputUsesStdBase64() throws {
        let t = MockTransport()
        let ctrl = TerminalController(blockId: blockId, tabId: tabId, transport: t, sink: CapturingTerminalSink())
        ctrl.sendText("hi")
        ctrl.flushInput() // input is coalesced + flushed on the runloop; force it here
        let n = try XCTUnwrap(t.notifies.last)
        XCTAssertEqual(n.command, TerminalCommand.input)
        let input = try n.data.decode(CommandBlockInputData.self)
        XCTAssertEqual(input.blockid, blockId)
        XCTAssertEqual(input.inputdata64, WaveBase64.encode("hi"))
        XCTAssertEqual(WaveBase64.decode(input.inputdata64 ?? ""), d("hi"))
    }

    func testResizeForwardsTermSizeAndUpdatesSink() throws {
        let t = MockTransport()
        let sink = CapturingTerminalSink()
        let ctrl = TerminalController(blockId: blockId, tabId: tabId, transport: t, sink: sink)
        ctrl.resize(TermSize(rows: 30, cols: 100))
        XCTAssertEqual(sink.lastSize, TermGridSize(cols: 100, rows: 30))
        let n = try XCTUnwrap(t.notifies.last)
        let input = try n.data.decode(CommandBlockInputData.self)
        XCTAssertEqual(input.termsize, TermSize(rows: 30, cols: 100))
    }

    func testReconnectCatchUpThroughController() async throws {
        let t = MockTransport()
        let sink = CapturingTerminalSink()
        t.cannedBackfill = (d("hello"), termFile(size: 5))
        let ctrl = TerminalController(blockId: blockId, tabId: tabId, transport: t, sink: sink)
        ctrl.resize(TermSize.default)
        try await ctrl.mount()
        XCTAssertEqual(ctrl.currentOffset, 5)

        // Simulate an outage: bytes "WORLD" were produced; the catch-up GET from
        // offset 5 returns [5, 10). No duplication of the existing "hello".
        t.cannedBackfill = (d("WORLD"), termFile(size: 10))
        try await ctrl.handleReconnect()
        XCTAssertEqual(s(sink.received), "helloWORLD")
        XCTAssertEqual(ctrl.currentOffset, 10)
    }

    /// An abandoned catch-up (retry budget exhausted with the backend down) used
    /// to freeze the pane FOREVER: the unloaded reconciler buffered every future
    /// append invisibly and nothing ever retried. The next live append must
    /// rearm one fresh catch-up cycle and recover the pane.
    func testAbandonedCatchUpRearmsOnNextAppend() async throws {
        let t = MockTransport()
        let sink = CapturingTerminalSink()
        t.cannedBackfill = (d("hello"), termFile(size: 5))
        let ctrl = TerminalController(blockId: blockId, tabId: tabId, transport: t, sink: sink)
        ctrl.catchUpMaxAttempts = 2
        ctrl.catchUpRetryBaseMs = 1
        ctrl.catchUpRetryCapMs = 1
        ctrl.resize(TermSize.default)
        try await ctrl.mount()
        XCTAssertEqual(ctrl.currentOffset, 5)

        // Outage: every backfill attempt fails, the budget exhausts, the
        // reconciler stays unloaded — the historical permanent-freeze state.
        t.fetchError = WaveError.transport("backend down")
        try await ctrl.handleReconnect()
        XCTAssertEqual(s(sink.received), "hello")
        XCTAssertEqual(ctrl.currentOffset, 5)

        // Backend recovers; the file now holds "helloWORLD". The append itself
        // still buffers invisibly, but it must trigger a fresh catch-up whose
        // backfill [5, 10) reconciles the buffered bytes (no dup, no gap).
        t.fetchError = nil
        t.cannedBackfill = (d("WORLD"), termFile(size: 10))
        t.fireAppend("WORLD")
        for _ in 0..<500 where ctrl.currentOffset < 10 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(ctrl.currentOffset, 10)
        XCTAssertEqual(s(sink.received), "helloWORLD")
    }

    private var blockId: String { "11111111-1111-1111-1111-111111111111" }
    private var tabId: String { "22222222-2222-2222-2222-222222222222" }
}

// MARK: - MockTransport

/// Minimal `WaveTransport` for controller tests: records call ordering, captures
/// notifies/resync, and lets a test fire `blockfile` events into the subscription
/// handler (optionally mid-fetch to simulate the subscribe/backfill race).
private final class MockTransport: WaveTransport, @unchecked Sendable {
    var addrs: ServerAddrs? = ServerAddrs(wsAddr: "127.0.0.1:1", webAddr: "127.0.0.1:2")
    var routeId: String? = "window:test"
    var isConnected: Bool = true
    var onReconnect: (@Sendable () -> Void)?

    var order: [String] = []
    var notifies: [(command: String, data: JSONValue)] = []
    var lastResync: JSONValue?
    var cannedBackfill: (Data, WaveFile) = (Data(), WaveFile(
        zoneid: "zone", name: "term",
        opts: FileOpts(maxsize: TerminalConst.termFileMaxSize, circular: true),
        createdts: 0, size: 0, modts: 0))
    var beforeFetchReturn: (() -> Void)?
    /// When set, every file fetch throws it (simulates a backend outage).
    var fetchError: WaveError?

    private var handler: (@Sendable (WaveEvent) -> Void)?

    func fireAppend(_ text: String) {
        let payload = WSFileEventData(
            zoneid: "11111111-1111-1111-1111-111111111111",
            filename: "term", fileop: FileOp.append,
            data64: WaveBase64.encode(text))
        fire(payload)
    }

    func fireTruncate() {
        let payload = WSFileEventData(
            zoneid: "11111111-1111-1111-1111-111111111111",
            filename: "term", fileop: FileOp.truncate, data64: "")
        fire(payload)
    }

    private func fire(_ payload: WSFileEventData) {
        guard let handler else { return }
        let data = try! JSONValue.encode(payload)
        handler(WaveEvent(event: WaveEventName.blockFile, scopes: ["block:11111111-1111-1111-1111-111111111111"], data: data))
    }

    func spawn(env: [String: String]) async throws -> ServerAddrs { addrs! }
    func connect(routeId: String) async throws {}
    func reconnect() async throws {}
    func disconnect() {}

    func call<Req: Encodable & Sendable, Res: Decodable & Sendable>(
        command: String, data: Req?, route: String?, timeoutMs: Int64?
    ) async throws -> Res {
        throw WaveError.notConnected
    }

    func callVoid<Req: Encodable & Sendable>(
        command: String, data: Req?, route: String?, timeoutMs: Int64?
    ) async throws {
        order.append(command == TerminalCommand.resync ? "resync" : command)
        if command == TerminalCommand.resync, let data {
            lastResync = try? JSONValue.encode(data)
        }
    }

    func notify<Req: Encodable & Sendable>(command: String, data: Req?, route: String?) throws {
        if let data {
            notifies.append((command, try JSONValue.encode(data)))
        }
    }

    func stream<Req: Encodable & Sendable>(
        command: String, data: Req?, route: String?,
        onChunk: @escaping @Sendable (Result<RpcMessage, WaveError>) -> Void
    ) throws -> SubscriptionToken {
        SubscriptionToken { }
    }

    func callService(_ call: WebCallType) async throws -> WebReturnType {
        throw WaveError.notConnected
    }

    func fetchFile(zoneId: String, name: String, offset: Int64) async throws -> (data: Data, info: WaveFile) {
        beforeFetchReturn?()
        if let fetchError { throw fetchError }
        order.append("backfill")
        return cannedBackfill
    }

    /// Tail/ranged fetch used by the mount path: serve the canned body's suffix
    /// with the same startOffset arithmetic the real server uses.
    func fetchFileRange(zoneId: String, name: String, range: FileFetchRange) async throws -> FileFetchResult {
        beforeFetchReturn?()
        if let fetchError { throw fetchError }
        order.append("backfill")
        let (data, info) = cannedBackfill
        if let tail = range.tail, tail > 0, Int64(data.count) > tail {
            let body = Data(data.suffix(Int(tail)))
            return FileFetchResult(data: body, info: info, startOffset: info.size - tail)
        }
        return FileFetchResult(data: data, info: info, startOffset: Swift.max(range.offset, info.dataStartIdx))
    }

    func subscribe(
        _ request: SubscriptionRequest, handler: @escaping @Sendable (WaveEvent) -> Void
    ) -> SubscriptionToken {
        order.append("subscribe")
        self.handler = handler
        return SubscriptionToken { }
    }
}

#if canImport(CGhostty) && canImport(AppKit)
import AppKit
import CGhostty

/// Terminal key encoding — modified cursor keys must carry the xterm modifier so the
/// shell gets word-navigation (Option+Left/Right) etc., not a bare arrow.
final class TerminalKeyEncodingTests: XCTestCase {
    func testModifierCode() {
        XCTAssertEqual(GhosttyTerminalView.csiModifier([]), 1)
        XCTAssertEqual(GhosttyTerminalView.csiModifier([.shift]), 2)
        XCTAssertEqual(GhosttyTerminalView.csiModifier([.option]), 3)   // Alt
        XCTAssertEqual(GhosttyTerminalView.csiModifier([.control]), 5)
        XCTAssertEqual(GhosttyTerminalView.csiModifier([.option, .shift]), 4)
        XCTAssertEqual(GhosttyTerminalView.csiModifier([.shift, .control]), 6)
    }

    func testCursorKeyEncoding() {
        let esc = Data([0x1b])
        // Plain Left stays a bare arrow.
        XCTAssertEqual(GhosttyTerminalView.csiCursor("D", 1), esc + Data("[D".utf8))
        // Modifier form (used for Shift/Ctrl combos; Option-only is intercepted
        // upstream in bytes(for:) and never reaches this encoder).
        XCTAssertEqual(GhosttyTerminalView.csiCursor("D", 3), esc + Data("[1;3D".utf8))
        XCTAssertEqual(GhosttyTerminalView.csiCursor("C", 3), esc + Data("[1;3C".utf8))
        // Shift+Left -> ESC[1;2D; Ctrl+Left -> ESC[1;5D.
        XCTAssertEqual(GhosttyTerminalView.csiCursor("D", 2), esc + Data("[1;2D".utf8))
        XCTAssertEqual(GhosttyTerminalView.csiCursor("D", 5), esc + Data("[1;5D".utf8))
    }

    func testAlternateScrollSequence() {
        let esc = Data([0x1b])
        XCTAssertEqual(
            GhosttyTerminalView.alternateScrollSequence(up: true, applicationCursorKeys: false),
            esc + Data("[A".utf8))
        XCTAssertEqual(
            GhosttyTerminalView.alternateScrollSequence(up: false, applicationCursorKeys: false),
            esc + Data("[B".utf8))
        // DECCKM set (vi does this) -> SS3 forms.
        XCTAssertEqual(
            GhosttyTerminalView.alternateScrollSequence(up: true, applicationCursorKeys: true),
            esc + Data("OA".utf8))
        XCTAssertEqual(
            GhosttyTerminalView.alternateScrollSequence(up: false, applicationCursorKeys: true),
            esc + Data("OB".utf8))
    }

    func testTildeKeyEncoding() {
        let esc = Data([0x1b])
        XCTAssertEqual(GhosttyTerminalView.csiTilde(3, 1), esc + Data("[3~".utf8))      // Delete
        XCTAssertEqual(GhosttyTerminalView.csiTilde(5, 3), esc + Data("[5;3~".utf8))    // Option+PageUp
    }

    private func keyEvent(_ scalarValue: Int, flags: NSEvent.ModifierFlags) -> NSEvent {
        let s = String(UnicodeScalar(UInt32(scalarValue))!)
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: s, charactersIgnoringModifiers: s,
            isARepeat: false, keyCode: 0)!
    }

    /// Option-only nav chords take the emacs Meta forms so they work in libedit
    /// (psql) as well as readline — CSI `ESC[1;3D` shows up as `;3D` garbage there.
    func testOptionNavChordsUseEmacsForms() {
        let esc = Data([0x1b])
        XCTAssertEqual(GhosttyTerminalView.bytes(for: keyEvent(NSLeftArrowFunctionKey, flags: [.option])),
                       esc + Data("b".utf8))
        XCTAssertEqual(GhosttyTerminalView.bytes(for: keyEvent(NSRightArrowFunctionKey, flags: [.option])),
                       esc + Data("f".utf8))
        XCTAssertEqual(GhosttyTerminalView.bytes(for: keyEvent(NSHomeFunctionKey, flags: [.option])),
                       Data([0x01]))
        XCTAssertEqual(GhosttyTerminalView.bytes(for: keyEvent(NSEndFunctionKey, flags: [.option])),
                       Data([0x05]))
        // Extra modifiers keep the xterm CSI forms.
        XCTAssertEqual(GhosttyTerminalView.bytes(for: keyEvent(NSLeftArrowFunctionKey, flags: [.option, .shift])),
                       esc + Data("[1;4D".utf8))
        XCTAssertEqual(GhosttyTerminalView.bytes(for: keyEvent(NSLeftArrowFunctionKey, flags: [.option, .control])),
                       esc + Data("[1;7D".utf8))
        // Plain arrows/Home unaffected.
        XCTAssertEqual(GhosttyTerminalView.bytes(for: keyEvent(NSLeftArrowFunctionKey, flags: [])),
                       esc + Data("[D".utf8))
        XCTAssertEqual(GhosttyTerminalView.bytes(for: keyEvent(NSHomeFunctionKey, flags: [])),
                       esc + Data("[H".utf8))
    }

    /// Numpad Enter arrives as ETX (0x03) — it must submit like Return (\r), not
    /// pass through raw (a literal Ctrl-C on the pty).
    func testNumpadEnterSubmitsLikeReturn() {
        XCTAssertEqual(GhosttyTerminalView.bytes(for: keyEvent(0x03, flags: [.numericPad])),
                       Data([0x0d]))
        // Shift+numpad-Enter mirrors Shift+Return's LF (Claude Code newline).
        XCTAssertEqual(GhosttyTerminalView.bytes(for: keyEvent(0x03, flags: [.numericPad, .shift])),
                       Data([0x0a]))
        // Option+Enter keeps the Meta form; the main Return key is unchanged.
        XCTAssertEqual(GhosttyTerminalView.bytes(for: keyEvent(0x03, flags: [.numericPad, .option])),
                       Data([0x1b, 0x0d]))
        XCTAssertEqual(GhosttyTerminalView.bytes(for: keyEvent(0x0d, flags: [])), Data([0x0d]))
        XCTAssertEqual(GhosttyTerminalView.bytes(for: keyEvent(0x0d, flags: [.shift])), Data([0x0a]))
    }

    /// Shift+Tab arrives as NSBackTabCharacter (0x19 = Ctrl-Y!). It must encode as the
    /// xterm backtab CSI Z, not pass through raw — 0x19 is readline's yank, so it would
    /// paste the kill ring instead of cycling modes in TUIs like Claude Code.
    func testShiftTabEncodesBacktabNotCtrlY() {
        let esc = Data([0x1b])
        XCTAssertEqual(GhosttyTerminalView.bytes(for: keyEvent(0x19, flags: [.shift])),
                       esc + Data("[Z".utf8))
        // Backtab wins even with extra modifiers held.
        XCTAssertEqual(GhosttyTerminalView.bytes(for: keyEvent(0x19, flags: [.shift, .option])),
                       esc + Data("[Z".utf8))
        // Plain Tab and a real Ctrl-Y are unaffected.
        XCTAssertEqual(GhosttyTerminalView.bytes(for: keyEvent(0x09, flags: [])), Data([0x09]))
        XCTAssertEqual(GhosttyTerminalView.bytes(for: keyEvent(Int(UnicodeScalar("y").value), flags: [.control])),
                       Data([0x19]))
    }
}

/// Per-frame find-highlight scanning: every visible occurrence of the query maps
/// to cell columns, so washes recompute from CONTENT each draw and follow their
/// text when a streaming TUI scrolls the screen.
final class FindOccurrenceColsTests: XCTestCase {
    private func asciiOffsets(_ line: String) -> [Int] {
        Array(0..<line.utf16.count)
    }

    func testMultipleOccurrencesOnOneRow() {
        let line = "err then err again err"
        let cols = GhosttyTerminalView.findOccurrenceCols(line: line, offsets: asciiOffsets(line), needle: "err")
        XCTAssertEqual(cols, [0...2, 9...11, 19...21])
    }

    func testCaseInsensitive() {
        let line = "Error ERROR error"
        let cols = GhosttyTerminalView.findOccurrenceCols(line: line, offsets: asciiOffsets(line), needle: "eRrOr")
        XCTAssertEqual(cols, [0...4, 6...10, 12...16])
    }

    func testNoMatchAndEmptyInputs() {
        XCTAssertEqual(GhosttyTerminalView.findOccurrenceCols(line: "abc", offsets: [0, 1, 2], needle: "xyz"), [])
        XCTAssertEqual(GhosttyTerminalView.findOccurrenceCols(line: "", offsets: [], needle: "x"), [])
        XCTAssertEqual(GhosttyTerminalView.findOccurrenceCols(line: "abc", offsets: [0, 1, 2], needle: ""), [])
    }

    func testOverlappingCandidatesScanForward() {
        // "aaaa" with needle "aa" -> non-overlapping forward matches.
        let line = "aaaa"
        let cols = GhosttyTerminalView.findOccurrenceCols(line: line, offsets: asciiOffsets(line), needle: "aa")
        XCTAssertEqual(cols, [0...1, 2...3])
    }

    func testColumnsSharingAnOffsetAreAllCovered() {
        // A wide glyph's lead + spacer cells share one text offset; the wash
        // must cover BOTH columns, and neighbors stay untouched.
        let line = "本ok"
        let offsets = [0, 0, 1, 2]
        XCTAssertEqual(GhosttyTerminalView.findOccurrenceCols(line: line, offsets: offsets, needle: "本"),
                       [0...1])
        XCTAssertEqual(GhosttyTerminalView.findOccurrenceCols(line: line, offsets: offsets, needle: "ok"),
                       [2...3])
    }

    func testUserSelectionPaintsAboveSupplementalFindHighlight() {
        XCTAssertEqual(
            GhosttyTerminalView.cellOverlayOrder(
                hasFind: true, hasCursor: true, selected: true),
            [.find, .cursor, .selection])
        XCTAssertEqual(
            GhosttyTerminalView.cellOverlayOrder(
                hasFind: true, hasCursor: false, selected: true),
            [.find, .selection])
    }
}

/// Find navigation must not borrow Ghostty's active selection. That selection is
/// the source of truth for Cmd-C, whether it came from a drag or a word gesture.
final class TerminalFindSelectionTests: XCTestCase {
    func testCurrentMarkerAndClosingFindPreserveCopySelection() {
        let sink = GhosttySink(cols: 40, rows: 5)
        let controller = TerminalController(
            blockId: "11111111-1111-1111-1111-111111111111",
            tabId: "22222222-2222-2222-2222-222222222222",
            transport: MockTransport(),
            sink: sink)
        let view = GhosttyTerminalView(
            controller: controller, sink: sink,
            font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        sink.feed(Data("find copyword".utf8))

        installSelection(5...12, in: sink)
        XCTAssertEqual(selectionText(in: sink), "copyword")

        XCTAssertTrue(view.markCurrentMatchInVisibleSinkRows(query: "find"))
        XCTAssertEqual(
            selectionText(in: sink), "copyword",
            "moving the current search result must not replace the user's Copy selection")

        view.showFindBar()
        view.hideFindBar()
        XCTAssertEqual(
            selectionText(in: sink), "copyword",
            "closing Find must remove only find UI, not the user's selection")
    }

    func testDoubleClickWordSelectionStillCopiesWhileFindIsOpen() throws {
        let sink = GhosttySink(cols: 40, rows: 5)
        let controller = TerminalController(
            blockId: "11111111-1111-1111-1111-111111111111",
            tabId: "22222222-2222-2222-2222-222222222222",
            transport: MockTransport(),
            sink: sink)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let view = GhosttyTerminalView(controller: controller, sink: sink, font: font)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.setFrameSize(NSSize(width: 480, height: 160))
        sink.feed(Data("find copyword".utf8))

        view.showFindBar()
        XCTAssertTrue(view.markCurrentMatchInVisibleSinkRows(query: "find"))

        let cell = GhosttyTerminalView.measureCell(font: font)
        let localPoint = NSPoint(
            x: 10 + CGFloat(7) * cell.width + cell.width / 2,
            y: 4 + cell.height / 2)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(localPoint, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 1))
        view.mouseDown(with: event)

        XCTAssertEqual(
            view.copyVirtualSelection(), "copyword",
            "double-click must keep producing the word selection used by Cmd-C")
        view.hideFindBar()
        XCTAssertEqual(view.copyVirtualSelection(), "copyword")
    }

    func testDragSelectionWorksAfterFindInLargeScrolledSink() throws {
        let sink = GhosttySink(
            cols: 40, rows: 5,
            maxScrollback: GhosttySink.scrollbackBytes(lines: 200_000, cols: 40))
        let controller = TerminalController(
            blockId: "11111111-1111-1111-1111-111111111111",
            tabId: "22222222-2222-2222-2222-222222222222",
            transport: MockTransport(),
            sink: sink)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let view = GhosttyTerminalView(controller: controller, sink: sink, font: font)
        let size = NSSize(width: 480, height: 160)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.setFrameSize(size)

        // Keep the target near the oldest retained rows, well away from the active
        // viewport. This exercises the same displaced sink viewport used by a find
        // landing in a terminal with substantial output.
        var output = "find dragword tail\r\n"
        for line in 0..<12_000 { output += "noise-\(line)\r\n" }
        sink.feed(Data(output.utf8))
        sink.withTerminal { terminal in
            var top = GhosttyTerminalScrollViewport()
            top.tag = GHOSTTY_SCROLL_VIEWPORT_TOP
            ghostty_terminal_scroll_viewport(terminal, top)
        }

        view.showFindBar()
        XCTAssertTrue(view.markCurrentMatchInVisibleSinkRows(query: "find"))

        let cell = GhosttyTerminalView.measureCell(font: font)
        func event(_ type: NSEvent.EventType, col: Int) throws -> NSEvent {
            let localPoint = NSPoint(
                x: 10 + CGFloat(col) * cell.width + cell.width / 2,
                y: 4 + cell.height / 2)
            return try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: view.convert(localPoint, to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1))
        }

        view.mouseDown(with: try event(.leftMouseDown, col: 5))
        view.mouseDragged(with: try event(.leftMouseDragged, col: 12))
        view.mouseUp(with: try event(.leftMouseUp, col: 12))

        XCTAssertEqual(
            selectionText(in: sink), "dragword",
            "find state must not consume or replace a drag in displaced live scrollback")
    }

    private func installSelection(_ cols: ClosedRange<Int>, in sink: GhosttySink) {
        sink.withTerminal { terminal in
            func ref(at col: Int) -> GhosttyGridRef? {
                var point = GhosttyPoint()
                point.tag = GHOSTTY_POINT_TAG_SCREEN
                point.value.coordinate = GhosttyPointCoordinate(x: UInt16(col), y: 0)
                var ref = GhosttyGridRef()
                ref.size = MemoryLayout<GhosttyGridRef>.stride
                guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { return nil }
                return ref
            }
            guard let start = ref(at: cols.lowerBound), let end = ref(at: cols.upperBound) else {
                return XCTFail("failed to resolve selection cells")
            }
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.stride
            selection.start = start
            selection.end = end
            withUnsafePointer(to: &selection) {
                XCTAssertEqual(
                    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, $0),
                    GHOSTTY_SUCCESS)
            }
        }
    }

    private func selectionText(in sink: GhosttySink) -> String? {
        var result: String?
        sink.withTerminal { terminal in
            var opts = GhosttyTerminalSelectionFormatOptions()
            opts.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.stride
            opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
            opts.unwrap = true
            opts.trim = true
            opts.selection = nil
            var ptr: UnsafeMutablePointer<UInt8>?
            var len = 0
            guard ghostty_terminal_selection_format_alloc(
                terminal, nil, opts, &ptr, &len) == GHOSTTY_SUCCESS,
                let ptr, len > 0 else { return }
            result = String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
            ghostty_free(nil, ptr, len)
        }
        return result
    }
}

/// A terminal can change DEC mouse-reporting modes between any two output bytes.
/// One physical gesture must nevertheless stay with the owner chosen on mouseDown,
/// and Shift must always provide an escape hatch for local text selection.
final class TerminalPointerGestureTests: XCTestCase {
    private struct Fixture {
        let sink: GhosttySink
        let view: GhosttyTerminalView
        let window: NSWindow
        let cell: CGSize
    }

    private func fixture(text: String = "dragword") -> Fixture {
        let sink = GhosttySink(cols: 40, rows: 5)
        let controller = TerminalController(
            blockId: "11111111-1111-1111-1111-111111111111",
            tabId: "22222222-2222-2222-2222-222222222222",
            transport: MockTransport(),
            sink: sink)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let view = GhosttyTerminalView(controller: controller, sink: sink, font: font)
        let size = NSSize(width: 480, height: 160)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.setFrameSize(size)
        sink.feed(Data(text.utf8))
        return Fixture(sink: sink, view: view, window: window,
                       cell: GhosttyTerminalView.measureCell(font: font))
    }

    private func event(
        _ type: NSEvent.EventType, col: Int, row: Int = 0, fixture: Fixture,
        modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1
    ) throws -> NSEvent {
        let localPoint = NSPoint(
            x: 10 + CGFloat(col) * fixture.cell.width + fixture.cell.width / 2,
            y: 4 + CGFloat(row) * fixture.cell.height + fixture.cell.height / 2)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: fixture.view.convert(localPoint, to: nil),
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: fixture.window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: clickCount,
            pressure: 1))
    }

    func testLocalDragStaysLocalWhenMouseReportingTurnsOnMidGesture() throws {
        let f = fixture()
        f.view.mouseDown(with: try event(.leftMouseDown, col: 0, fixture: f))

        // A streaming app may enable mouse reporting after the press. Re-reading
        // this mode during drag/up used to steal the rest of Wave's selection.
        f.sink.feed(Data("\u{1b}[?1000h".utf8))
        f.view.mouseDragged(with: try event(.leftMouseDragged, col: 7, fixture: f))
        f.view.mouseUp(with: try event(.leftMouseUp, col: 7, fixture: f))

        XCTAssertEqual(selectionText(in: f.sink), "dragword")
    }

    func testShiftDragSelectsLocallyWhileApplicationTracksMouse() throws {
        let f = fixture()
        f.sink.feed(Data("\u{1b}[?1000h".utf8))

        f.view.mouseDown(with: try event(
            .leftMouseDown, col: 0, fixture: f, modifiers: .shift))
        f.view.mouseDragged(with: try event(
            .leftMouseDragged, col: 7, fixture: f, modifiers: .shift))
        f.view.mouseUp(with: try event(
            .leftMouseUp, col: 7, fixture: f, modifiers: .shift))

        XCTAssertEqual(
            selectionText(in: f.sink), "dragword",
            "Shift must bypass a real or stale remote mouse-reporting mode")
    }

    func testSelectionStartsInMiddleOfWrappedRowsAfterRepeatedReflow() throws {
        let f = fixture(text: "")

        // Long-lived log panes accumulate old pages at several widths. A click on a
        // visible continuation row must remain addressable after those pages reflow.
        f.sink.setSize(cols: 80, rows: 5)
        f.sink.feed(Data(String(repeating: "wrappedword ", count: 2_000).utf8))
        for cols in [24, 120, 32, 96, 40] {
            f.sink.setSize(cols: cols, rows: 5)
        }

        f.view.mouseDown(with: try event(
            .leftMouseDown, col: 12, row: 2, fixture: f))
        f.view.mouseDragged(with: try event(
            .leftMouseDragged, col: 20, row: 2, fixture: f))
        f.view.mouseUp(with: try event(
            .leftMouseUp, col: 20, row: 2, fixture: f))
        XCTAssertNotNil(
            selectionText(in: f.sink),
            "a drag beginning away from column zero must survive page reflow")

        f.view.mouseDown(with: try event(
            .leftMouseDown, col: 15, row: 2, fixture: f, clickCount: 2))
        XCTAssertEqual(
            f.view.copyVirtualSelection(), "wrappedword",
            "double-click in the middle of a wrapped row must resolve a word")
    }

    private func selectionText(in sink: GhosttySink) -> String? {
        var result: String?
        sink.withTerminal { terminal in
            var opts = GhosttyTerminalSelectionFormatOptions()
            opts.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.stride
            opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
            opts.unwrap = true
            opts.trim = true
            opts.selection = nil
            var ptr: UnsafeMutablePointer<UInt8>?
            var len = 0
            guard ghostty_terminal_selection_format_alloc(
                terminal, nil, opts, &ptr, &len) == GHOSTTY_SUCCESS,
                let ptr, len > 0 else { return }
            result = String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
            ghostty_free(nil, ptr, len)
        }
        return result
    }

}

/// `isDirectlyEncodedKey` is the gate that keeps control/navigation keys on the direct
/// `bytes(for:)` encoder while routing ordinary text (incl. dead keys) through the macOS
/// text-input system. Dead-key composition itself needs a live input context and is
/// integration-only; here we test the pure classification by its inputs.
final class TerminalDirectKeyClassificationTests: XCTestCase {
    private func scalar(_ s: String) -> Unicode.Scalar? { s.unicodeScalars.first }

    func testOrdinaryTextRoutesThroughInputContext() {
        XCTAssertFalse(GhosttyTerminalView.isDirectlyEncodedKey(flags: [], scalar: scalar("a")))
        // Shift+letter (capital) is still ordinary text.
        XCTAssertFalse(GhosttyTerminalView.isDirectlyEncodedKey(flags: [.shift], scalar: scalar("A")))
        // The dead-key triggers themselves (apostrophe, backtick) are ordinary text — they
        // must reach the IME to compose.
        XCTAssertFalse(GhosttyTerminalView.isDirectlyEncodedKey(flags: [], scalar: scalar("'")))
        XCTAssertFalse(GhosttyTerminalView.isDirectlyEncodedKey(flags: [], scalar: scalar("`")))
        XCTAssertFalse(GhosttyTerminalView.isDirectlyEncodedKey(flags: [], scalar: scalar("é")))
    }

    func testControlAndOptionAreDirect() {
        XCTAssertTrue(GhosttyTerminalView.isDirectlyEncodedKey(flags: [.control], scalar: scalar("c")))
        XCTAssertTrue(GhosttyTerminalView.isDirectlyEncodedKey(flags: [.option], scalar: scalar("a")))
        XCTAssertTrue(GhosttyTerminalView.isDirectlyEncodedKey(flags: [.control, .shift], scalar: scalar("a")))
    }

    func testReturnTabEscapeBackspaceAreDirect() {
        XCTAssertTrue(GhosttyTerminalView.isDirectlyEncodedKey(flags: [], scalar: scalar("\r")))
        XCTAssertTrue(GhosttyTerminalView.isDirectlyEncodedKey(flags: [], scalar: scalar("\t")))
        XCTAssertTrue(GhosttyTerminalView.isDirectlyEncodedKey(flags: [], scalar: Unicode.Scalar(0x1b)))
        XCTAssertTrue(GhosttyTerminalView.isDirectlyEncodedKey(flags: [], scalar: Unicode.Scalar(0x7f)))
        // Shift+Enter stays direct — the \n special case lives in the direct encoder.
        XCTAssertTrue(GhosttyTerminalView.isDirectlyEncodedKey(flags: [.shift], scalar: scalar("\r")))
    }

    func testNavigationAndFunctionKeysAreDirect() {
        XCTAssertTrue(GhosttyTerminalView.isDirectlyEncodedKey(flags: [], scalar: Unicode.Scalar(UInt32(NSLeftArrowFunctionKey))))
        XCTAssertTrue(GhosttyTerminalView.isDirectlyEncodedKey(flags: [], scalar: Unicode.Scalar(UInt32(NSHomeFunctionKey))))
        XCTAssertTrue(GhosttyTerminalView.isDirectlyEncodedKey(flags: [], scalar: Unicode.Scalar(UInt32(NSPageUpFunctionKey))))
        XCTAssertTrue(GhosttyTerminalView.isDirectlyEncodedKey(flags: [], scalar: Unicode.Scalar(UInt32(NSF1FunctionKey))))
    }

    func testNilScalarWithoutModifiersIsNotDirect() {
        // A bare dead key delivers an empty `characters`/`charactersIgnoringModifiers`.
        XCTAssertFalse(GhosttyTerminalView.isDirectlyEncodedKey(flags: [], scalar: nil))
    }
}

/// The cell width must ROUND the glyph advance — `ceil` over-widened every cell (~+1px),
/// producing visible letter-spacing / text that looked too wide.
final class TerminalCellMetricsTests: XCTestCase {
    func testCellWidthRoundsAdvanceNotCeil() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        let cell = GhosttyTerminalView.measureCell(font: font)
        XCTAssertEqual(cell.width, advance.rounded(), accuracy: 0.001,
                       "cell width must round the advance, not ceil it")
        // SF Mono 12 advance ≈ 7.42 -> round 7, ceil 8; guard against a ceil regression.
        if ceil(advance) != advance.rounded() {
            XCTAssertNotEqual(cell.width, ceil(advance),
                              "cell width must not ceil — it over-widens letter spacing")
        }
    }

    // Live re-render: a larger font yields a larger cell, and the same view width then
    // measures FEWER columns (the cols recompute the font change drives).
    func testFontSizeChangesCellMetricsAndColumns() {
        let small = GhosttyTerminalView.measureCell(font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        let large = GhosttyTerminalView.measureCell(font: .monospacedSystemFont(ofSize: 24, weight: .regular))
        XCTAssertGreaterThan(large.width, small.width, "a larger font must widen the cell")
        XCTAssertGreaterThan(large.height, small.height)

        let smallCols = GhosttyTerminalView.gridSize(width: 800, height: 400, cellSize: small, padH: 10, padV: 4).cols
        let largeCols = GhosttyTerminalView.gridSize(width: 800, height: 400, cellSize: large, padH: 10, padV: 4).cols
        XCTAssertGreaterThan(smallCols, largeCols, "the bigger font must recompute to fewer columns")
        XCTAssertGreaterThanOrEqual(smallCols, 1)
    }

    // The font helper picks up family/size and falls back to a monospaced font for an
    // unknown family.
    func testTerminalFontSettingsResolution() {
        let def = TerminalFontSettings.font(family: nil, size: nil)
        XCTAssertEqual(def.pointSize, 12, accuracy: 0.001)
        let sized = TerminalFontSettings.font(family: nil, size: 18)
        XCTAssertEqual(sized.pointSize, 18, accuracy: 0.001)
        // An unknown family still resolves to a usable (monospaced) font at the size.
        let unknown = TerminalFontSettings.font(family: "NoSuchFontXYZ", size: 15)
        XCTAssertEqual(unknown.pointSize, 15, accuracy: 0.001)
    }

    // term:transparency (0 opaque … 1 clear) maps to a background alpha (1 … 0), clamped.
    func testBackgroundAlphaMapping() {
        XCTAssertEqual(TerminalFontSettings.backgroundAlpha(transparency: nil), 1, accuracy: 0.001)
        XCTAssertEqual(TerminalFontSettings.backgroundAlpha(transparency: 0), 1, accuracy: 0.001)
        XCTAssertEqual(TerminalFontSettings.backgroundAlpha(transparency: 0.25), 0.75, accuracy: 0.001)
        XCTAssertEqual(TerminalFontSettings.backgroundAlpha(transparency: 1), 0, accuracy: 0.001)
        XCTAssertEqual(TerminalFontSettings.backgroundAlpha(transparency: 5), 0, accuracy: 0.001, "clamped")
    }

    // Theme hex parsing: `#rrggbb` / `rrggbb`, with empty/invalid → nil (keep default).
    func testTermRGBHexParsing() {
        XCTAssertEqual(TermRGB.fromHex("#ff8800"), TermRGB(r: 255, g: 136, b: 0))
        XCTAssertEqual(TermRGB.fromHex("00ff00"), TermRGB(r: 0, g: 255, b: 0))
        XCTAssertNil(TermRGB.fromHex(""))
        XCTAssertNil(TermRGB.fromHex(nil))
        XCTAssertNil(TermRGB.fromHex("#fff"))
        XCTAssertNil(TermRGB.fromHex("nothex"))
    }
}

// Output rendering uses Ghostty's row-level damage and an explicit AppKit visibility
// gate. Keep the pure range/visibility decisions pinned so a later rendering change
// cannot silently regress to full-grid work for every terminal chunk.
final class TerminalRenderDamageTests: XCTestCase {
    func testDirtyRowsCoalesceIntoMinimalRanges() {
        XCTAssertEqual(
            GhosttyTerminalView.coalescedRowRanges([5, 3, 4, 9, 9, -1, 12]),
            [3..<6, 9..<10, 12..<13])
        XCTAssertEqual(GhosttyTerminalView.coalescedRowRanges([]), [])
    }

    func testDirtyRectMapsOnlyToIntersectingGridRows() {
        XCTAssertEqual(
            GhosttyTerminalView.drawRowRange(
                dirtyRect: NSRect(x: 0, y: 14, width: 200, height: 10),
                padV: 4, cellHeight: 10, rowCount: 5),
            1..<2)
        XCTAssertEqual(
            GhosttyTerminalView.drawRowRange(
                dirtyRect: NSRect(x: 0, y: 13.5, width: 200, height: 1),
                padV: 4, cellHeight: 10, rowCount: 5),
            0..<2,
            "a rect crossing a row boundary must redraw both rows")
        XCTAssertEqual(
            GhosttyTerminalView.drawRowRange(
                dirtyRect: NSRect(x: 0, y: 60, width: 200, height: 10),
                padV: 4, cellHeight: 10, rowCount: 5),
            0..<0)
    }

    func testInvisibleOrHiddenTerminalSuppressesRendering() {
        XCTAssertFalse(GhosttyTerminalView.shouldSuppressTerminalRendering(
            windowVisible: true, hiddenOrHasHiddenAncestor: false))
        XCTAssertTrue(GhosttyTerminalView.shouldSuppressTerminalRendering(
            windowVisible: false, hiddenOrHasHiddenAncestor: false),
            "a fully occluded/minimized/off-Space window must not schedule frames")
        XCTAssertTrue(GhosttyTerminalView.shouldSuppressTerminalRendering(
            windowVisible: true, hiddenOrHasHiddenAncestor: true),
            "a hidden tab/view must not schedule frames")
    }
}

// The cursor is a FILLED block only when this view holds key focus AND its window is
// the key window; otherwise it's HOLLOW. A background window's focused terminal must
// therefore show a hollow cursor (the regression these assert against).
final class TerminalCursorStyleTests: XCTestCase {
    func testCursorFilledOnlyWhenFocusedAndWindowKey() {
        XCTAssertTrue(GhosttyTerminalView.cursorIsFilled(hasKeyFocus: true, windowIsKey: true),
                      "focused pane in the key window → filled cursor")
        XCTAssertFalse(GhosttyTerminalView.cursorIsFilled(hasKeyFocus: true, windowIsKey: false),
                       "focused pane in a BACKGROUND window → hollow cursor")
        XCTAssertFalse(GhosttyTerminalView.cursorIsFilled(hasKeyFocus: false, windowIsKey: true),
                       "unfocused pane → hollow cursor")
        XCTAssertFalse(GhosttyTerminalView.cursorIsFilled(hasKeyFocus: false, windowIsKey: false))
    }

    // DECSCUSR shape honored when focused; forced HOLLOW when unfocused regardless of shape.
    func testResolvedCursorStyleHonorsShapeWhenFocused() {
        for reported in [
            GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK,
            GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR,
            GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE,
        ] {
            XCTAssertEqual(
                GhosttyTerminalView.resolvedCursorStyle(reported: reported, filled: true).rawValue,
                reported.rawValue,
                "a focused pane keeps the reported DECSCUSR shape")
            XCTAssertEqual(
                GhosttyTerminalView.resolvedCursorStyle(reported: reported, filled: false).rawValue,
                GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW.rawValue,
                "an unfocused pane collapses any shape to the hollow block")
        }
    }
}

// Mouse-reporting gate: a click reaches the pty only when ANY tracking mode is active.
// Missing a mode here drops every click into local selection (the click "does nothing"
// for the TUI). The live terminal query + encode/send are integration-only; this covers
// the OR decision over the aggregate flag + the individual DEC tracking modes.
final class TerminalMouseReportingTests: XCTestCase {
    func testReportingOffWhenNoModeActive() {
        XCTAssertFalse(GhosttyTerminalView.mouseReportingActive(
            aggregate: false, x10: false, normal: false, button: false, any: false))
    }

    func testEachIndividualModeEnablesReporting() {
        XCTAssertTrue(GhosttyTerminalView.mouseReportingActive(
            aggregate: false, x10: true, normal: false, button: false, any: false), "X10 (9)")
        XCTAssertTrue(GhosttyTerminalView.mouseReportingActive(
            aggregate: false, x10: false, normal: true, button: false, any: false), "normal (1000)")
        XCTAssertTrue(GhosttyTerminalView.mouseReportingActive(
            aggregate: false, x10: false, normal: false, button: true, any: false), "button-event (1002)")
        XCTAssertTrue(GhosttyTerminalView.mouseReportingActive(
            aggregate: false, x10: false, normal: false, button: false, any: true), "any-event (1003)")
    }

    func testAggregateFlagAloneEnablesReporting() {
        XCTAssertTrue(GhosttyTerminalView.mouseReportingActive(
            aggregate: true, x10: false, normal: false, button: false, any: false),
            "the aggregate MOUSE_TRACKING flag alone must enable reporting")
    }
}

// Mapping a URL's UTF-16 char range back to the cell columns it spans (hover underline).
// The integration row read + Cmd-hover wiring are tested manually; this covers the math.
final class TerminalLinkColumnRangeTests: XCTestCase {
    func testColumnRangeForAsciiRunIsContiguous() {
        // 1:1 ASCII offsets: "a https://x.co b" → URL chars 2...12 cover columns 2...12.
        let offsets = Array(0..<16)
        XCTAssertEqual(GhosttyTerminalView.columnRange(offsets: offsets, utf16Lower: 2, utf16Upper: 13), 2...12)
    }

    func testColumnRangeEmptyWhenNoColumnInside() {
        let offsets = Array(0..<10)
        XCTAssertNil(GhosttyTerminalView.columnRange(offsets: offsets, utf16Lower: 20, utf16Upper: 30))
    }

    func testColumnRangeWithWideGlyphOffsetGap() {
        // A wide glyph at column 0 advances the UTF-16 offset by 2, so column 1 starts at
        // offset 2; a URL spanning offsets 2..<5 must map to columns 1...3.
        let offsets = [0, 2, 3, 4, 5]
        XCTAssertEqual(GhosttyTerminalView.columnRange(offsets: offsets, utf16Lower: 2, utf16Upper: 5), 1...3)
    }
}

// A TUI that dies without its DECRST cleanup (crashed docker exec / ssh) leaves
// mouse/focus reporting stuck on, flooding the shell prompt with SGR reports. The
// sink self-heals at the next shell-integration prompt mark (OSC 133;A), and
// `resetStuckModes` is the manual context-menu escape hatch.
final class TerminalModeHealTests: XCTestCase {
    private func modeOn(_ sink: GhosttySink, _ mode: UInt16) -> Bool {
        var on = false
        sink.withTerminal { t in
            _ = ghostty_terminal_mode_get(t, GhosttyMode(mode), &on)
        }
        return on
    }

    private func activeScreen(_ sink: GhosttySink) -> GhosttyTerminalScreen {
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        sink.withTerminal { t in
            _ = ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        }
        return screen
    }

    func testPromptStartClearsStuckMouseReporting() {
        let sink = GhosttySink(cols: 40, rows: 5)
        sink.feed(d("\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?1004h"))
        XCTAssertTrue(modeOn(sink, 1003))
        XCTAssertTrue(modeOn(sink, 1004))

        sink.feed(d("\u{1b}]133;A\u{7}$ "))
        XCTAssertFalse(modeOn(sink, 1003), "any-motion tracking must be cleared at the prompt mark")
        XCTAssertFalse(modeOn(sink, 1006), "the SGR encoding must not outlive the tracking mode")
        XCTAssertFalse(modeOn(sink, 1004), "focus reporting must be cleared at the prompt mark")
    }

    func testEnableAfterPromptMarkSurvives() {
        // Backfill shape: one chunk replays an old prompt, then the still-running
        // TUI's mouse enable. The heal must apply AT the mark, not after the chunk.
        let sink = GhosttySink(cols: 40, rows: 5)
        sink.feed(d("\u{1b}]133;A\u{7}$ vim\r\u{1b}[?1002h\u{1b}[?1006h"))
        XCTAssertTrue(modeOn(sink, 1002), "a mouse enable AFTER the prompt mark is live app state")
        XCTAssertTrue(modeOn(sink, 1006))
    }

    func testBackfillReplayHealsFinalState() {
        let sink = GhosttySink(cols: 40, rows: 5)
        sink.feedBackfill(d("\u{1b}[?1000h\u{1b}]133;A\u{7}$ "))
        XCTAssertFalse(modeOn(sink, 1000), "replayed history ending at a prompt must not resurrect tracking")
    }

    func testPromptMarkWithoutStuckModesChangesNothing() {
        let sink = GhosttySink(cols: 40, rows: 5)
        sink.feed(d("\u{1b}[?2004h\u{1b}]133;A\u{7}$ "))
        XCTAssertTrue(modeOn(sink, 2004), "bracketed paste belongs to the shell and must be left alone")
    }

    func testResetStuckModesRestoresInputState() {
        let sink = GhosttySink(cols: 40, rows: 5)
        sink.feed(d("\u{1b}[?1003h\u{1b}[?1049h\u{1b}[?25l"))
        XCTAssertTrue(modeOn(sink, 1049))
        XCTAssertEqual(activeScreen(sink), GHOSTTY_TERMINAL_SCREEN_ALTERNATE)

        sink.resetStuckModes()
        XCTAssertFalse(modeOn(sink, 1003))
        XCTAssertFalse(modeOn(sink, 1049), "manual reset must leave the alt screen")
        XCTAssertEqual(
            activeScreen(sink), GHOSTTY_TERMINAL_SCREEN_PRIMARY,
            "the BUFFER must swap back too — clearing the 1049 flag alone keeps rendering the dead TUI")
        XCTAssertTrue(modeOn(sink, 25), "manual reset must re-show the cursor")
    }

    func testPromptStartExitsStuckAltScreen() {
        // A full-screen TUI (vim, or Claude Code's full-screen views) killed
        // without DECRST 1049 leaves the alt screen active; the wheel then
        // encodes as arrow keys (alternate scroll) cycling shell history
        // instead of scrolling the viewport.
        let sink = GhosttySink(cols: 40, rows: 5)
        sink.feed(d("\u{1b}[?1049h\u{1b}[?1h\u{1b}[?25ltui"))
        XCTAssertTrue(modeOn(sink, 1049))

        sink.feed(d("\u{1b}]133;A\u{7}$ "))
        XCTAssertFalse(modeOn(sink, 1049), "alt screen must be exited at the prompt mark")
        XCTAssertEqual(activeScreen(sink), GHOSTTY_TERMINAL_SCREEN_PRIMARY)
        XCTAssertFalse(modeOn(sink, 1), "cursor-keys application mode belonged to the dead TUI")
        XCTAssertTrue(modeOn(sink, 25), "the dead TUI's hidden cursor must be re-shown")
    }

    func testWavePromptMarkHealsStuckModes() {
        // Wave-launched shells emit OSC 16162;A (shellintegration precmd), not
        // OSC 133;A — the heal must trigger on Wave's own mark too.
        let sink = GhosttySink(cols: 40, rows: 5)
        sink.feed(d("\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?1049h"))
        XCTAssertTrue(modeOn(sink, 1049))

        sink.feed(d("\u{1b}]16162;A\u{7}$ "))
        XCTAssertFalse(modeOn(sink, 1002))
        XCTAssertFalse(modeOn(sink, 1049))
        XCTAssertEqual(activeScreen(sink), GHOSTTY_TERMINAL_SCREEN_PRIMARY)
    }

    func testAltScreenEnableAfterWaveMarkSurvives() {
        // Backfill shape: the chunk replays a prompt, then the still-running
        // TUI's alt-screen enter. The heal applies AT the mark, not after.
        let sink = GhosttySink(cols: 40, rows: 5)
        sink.feed(d("\u{1b}]16162;A\u{7}$ vim\r\u{1b}[?1049h"))
        XCTAssertTrue(modeOn(sink, 1049), "an alt-screen enter AFTER the prompt mark is live app state")
        XCTAssertEqual(activeScreen(sink), GHOSTTY_TERMINAL_SCREEN_ALTERNATE)
    }

    func testHealPreservesPrimaryScreenContentAndCursor() {
        // 1049 exit must restore the saved primary cursor so the prompt renders
        // right after the command line that launched the TUI.
        let sink = GhosttySink(cols: 40, rows: 5)
        sink.feed(d("one\r\ntwo\r\n$ vim\r\n"))
        sink.feed(d("\u{1b}[?1049h\u{1b}[2JTUI"))
        sink.feed(d("\u{1b}]16162;A\u{7}"))
        XCTAssertEqual(activeScreen(sink), GHOSTTY_TERMINAL_SCREEN_PRIMARY)
        var row: UInt16 = 0
        sink.withTerminal { t in
            _ = ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &row)
        }
        XCTAssertEqual(Int(row), 3, "cursor must land where the primary screen left off")
    }
}
#endif
