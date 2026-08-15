// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Double-click word selection in an alt-screen TUI (vi/less) must select — and
// draw the wash on — the row that was clicked, both with and without mouse
// tracking, and regardless of primary-screen scrollback behind the alt screen.
// These pin the unified-selection row math end-to-end at the view level: click
// -> unifiedHit -> ghostty word range -> wash draw row -> copied text.

#if canImport(CGhostty) && canImport(AppKit)
import AppKit
import XCTest
import CGhostty
import WaveCore
@testable import WaveTerminal

final class TerminalAltScreenSelectionTests: XCTestCase {
    private var window: NSWindow!
    private var view: GhosttyTerminalView!
    private var sink: GhosttySink!
    private var cell: NSSize = .zero

    private func makeFixture() {
        sink = GhosttySink(cols: 40, rows: 5)
        let controller = TerminalController(
            blockId: "11111111-1111-1111-1111-111111111111",
            tabId: "22222222-2222-2222-2222-222222222222",
            transport: AltSelTransport(),
            sink: sink)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view = GhosttyTerminalView(controller: controller, sink: sink, font: font)
        let size = NSSize(width: 480, height: 160)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.setFrameSize(size)
        cell = GhosttyTerminalView.measureCell(font: font)
    }

    /// vi-like screen: rows "alpha one" / "bravo two" / "charlie three" /
    /// "delta four" / "~status", drawn via CUP after entering the alt screen.
    private func feedViScreen(prelude: String, modes: String) {
        var stream = prelude
        stream += "\u{1b}[?1049h" + modes + "\u{1b}[2J"
        stream += "\u{1b}[1;1Halpha one"
        stream += "\u{1b}[2;1Hbravo two"
        stream += "\u{1b}[3;1Hcharlie three"
        stream += "\u{1b}[4;1Hdelta four"
        stream += "\u{1b}[5;1H~status"
        sink.feed(Data(stream.utf8))
    }

    private func mouse(_ type: NSEvent.EventType, row: Int, col: Int, count: Int) throws -> NSEvent {
        let localPoint = NSPoint(
            x: 10 + CGFloat(col) * cell.width + cell.width / 2,
            y: 4 + CGFloat(row) * cell.height + cell.height / 2)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: view.convert(localPoint, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: count,
            pressure: 1))
    }

    /// A real double-click as AppKit delivers it: click 1 down/up, click 2 down/up.
    private func doubleClick(row: Int, col: Int) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, row: row, col: col, count: 1))
        view.mouseUp(with: try mouse(.leftMouseUp, row: row, col: col, count: 1))
        view.mouseDown(with: try mouse(.leftMouseDown, row: row, col: col, count: 2))
        view.mouseUp(with: try mouse(.leftMouseUp, row: row, col: col, count: 2))
    }

    private func capture() -> NSBitmapImageRep {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Text rows whose pixels differ between two captures (the selection wash).
    private func changedRows(_ base: NSBitmapImageRep, _ now: NSBitmapImageRep) -> [Int] {
        let scale = CGFloat(base.pixelsHigh) / view.bounds.height
        var rows: [Int] = []
        for row in 0..<5 {
            let yLo = Int((4 + CGFloat(row) * cell.height) * scale)
            let yHi = Int((4 + CGFloat(row + 1) * cell.height) * scale)
            var differs = false
            outer: for y in yLo..<min(yHi, base.pixelsHigh) {
                for x in 0..<min(base.pixelsWide, now.pixelsWide) where base.colorAt(x: x, y: y) != now.colorAt(x: x, y: y) {
                    differs = true
                    break outer
                }
            }
            if differs { rows.append(row) }
        }
        return rows
    }

    func testDoubleClickSelectsClickedRowWithMouseTrackingOn() throws {
        makeFixture()
        feedViScreen(prelude: "shell1\r\nshell2\r\nshell3\r\n", modes: "\u{1b}[?1002h\u{1b}[?1006h")
        let base = capture()
        try doubleClick(row: 1, col: 2)
        XCTAssertEqual(view.copyVirtualSelection(), "bravo")
        XCTAssertEqual(changedRows(base, capture()), [1], "wash must paint on the clicked row only")
    }

    func testDoubleClickSelectsClickedRowWithMouseTrackingOff() throws {
        makeFixture()
        feedViScreen(prelude: "shell1\r\nshell2\r\nshell3\r\n", modes: "")
        let base = capture()
        try doubleClick(row: 2, col: 2)
        XCTAssertEqual(view.copyVirtualSelection(), "charlie")
        XCTAssertEqual(changedRows(base, capture()), [2], "wash must paint on the clicked row only")
    }

    func testDoubleClickSelectsClickedRowWithScrollbackBehindAltScreen() throws {
        makeFixture()
        var prelude = ""
        for i in 1...40 { prelude += "shellhistory\(i)\r\n" }
        feedViScreen(prelude: prelude, modes: "\u{1b}[?1002h\u{1b}[?1006h")
        let base = capture()
        try doubleClick(row: 3, col: 2)
        XCTAssertEqual(view.copyVirtualSelection(), "delta")
        XCTAssertEqual(changedRows(base, capture()), [3], "wash must paint on the clicked row only")
    }
}

private final class AltSelTransport: WaveTransport, @unchecked Sendable {
    var addrs: ServerAddrs? = ServerAddrs(wsAddr: "127.0.0.1:1", webAddr: "127.0.0.1:2")
    var routeId: String? = "window:test"
    var isConnected: Bool = true
    var onReconnect: (@Sendable () -> Void)?

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
    ) async throws {}

    func notify<Req: Encodable & Sendable>(command: String, data: Req?, route: String?) throws {}

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
        throw WaveError.notConnected
    }

    func fetchFileRange(zoneId: String, name: String, range: FileFetchRange) async throws -> FileFetchResult {
        throw WaveError.notConnected
    }

    func subscribe(
        _ request: SubscriptionRequest, handler: @escaping @Sendable (WaveEvent) -> Void
    ) -> SubscriptionToken {
        SubscriptionToken { }
    }
}
#endif
