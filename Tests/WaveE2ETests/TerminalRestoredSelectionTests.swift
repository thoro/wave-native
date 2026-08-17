// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Repro for "restored history is unselectable after a reboot": content fed via
// the backfill replay path (feedBackfill, as mount() does on restart) followed
// by fresh live output must be selectable by click-drag exactly like content
// that arrived live — both at the bottom of the buffer and after scrolling up
// into the sink's scrollback.

#if canImport(CGhostty) && canImport(AppKit)
import AppKit
import XCTest
import CGhostty
import WaveCore
@testable import WaveTerminal

final class TerminalRestoredSelectionTests: XCTestCase {
    private var window: NSWindow!
    private var view: GhosttyTerminalView!
    private var sink: GhosttySink!
    private var cell: NSSize = .zero
    private var gridRows = 0
    private var gridCols = 0

    private func makeFixture() {
        sink = GhosttySink(cols: 40, rows: 5)
        let controller = TerminalController(
            blockId: "11111111-1111-1111-1111-111111111111",
            tabId: "22222222-2222-2222-2222-222222222222",
            transport: RestoredSelTransport(),
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
        let grid = GhosttyTerminalView.gridSize(
            width: size.width, height: size.height, cellSize: cell, padH: 10, padV: 4)
        gridRows = grid.rows
        gridCols = grid.cols
    }

    private func mouse(_ type: NSEvent.EventType, row: Int, col: Int, count: Int = 1) throws -> NSEvent {
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

    private func dragSelect(fromRow: Int, fromCol: Int, toRow: Int, toCol: Int) throws {
        view.mouseDown(with: try mouse(.leftMouseDown, row: fromRow, col: fromCol))
        view.mouseDragged(with: try mouse(.leftMouseDragged, row: toRow, col: toCol))
        view.mouseUp(with: try mouse(.leftMouseUp, row: toRow, col: toCol))
    }

    private func scrollUp(rows: Int) throws {
        let cg = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: Int32(CGFloat(rows) * cell.height), wheel2: 0, wheel3: 0))
        cg.location = window.convertPoint(
            toScreen: view.convert(NSPoint(x: 50, y: 50), to: nil))
        let ev = try XCTUnwrap(NSEvent(cgEvent: cg))
        view.scrollWheel(with: ev)
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
        for row in 0..<gridRows {
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

    private static let promptMark = "\u{1b}]16162;A\u{07}"

    /// Restored-at-boot shape: N old lines replayed through the backfill path,
    /// then the new shell's prompt + output arriving live.
    private func feedRestoredScenario(oldLines: Int) {
        var restored = ""
        for i in 1...oldLines {
            restored += Self.promptMark + "old-line-\(i)\r\n"
        }
        sink.feedBackfill(Data(restored.utf8))
        sink.feed(Data((Self.promptMark + "new-line-1\r\nnew-line-2").utf8))
    }

    func testClickDragSelectsBackfilledRowsOnScreen() throws {
        makeFixture()
        feedRestoredScenario(oldLines: gridRows - 3)
        let base = capture()
        try dragSelect(fromRow: 1, fromCol: 0, toRow: 2, toCol: 7)
        XCTAssertEqual(
            changedRows(base, capture()), [1, 2],
            "click-drag over replayed (restored) rows must draw the selection wash")
    }

    func testClickDragSelectsLiveRowsOnScreen() throws {
        makeFixture()
        feedRestoredScenario(oldLines: gridRows - 3)
        let base = capture()
        let newRow = gridRows - 3
        try dragSelect(fromRow: newRow, fromCol: 0, toRow: newRow, toCol: 7)
        XCTAssertEqual(
            changedRows(base, capture()), [newRow],
            "click-drag over live rows must draw the selection wash")
    }

    func testClickDragSelectsBackfilledScrollback() throws {
        makeFixture()
        feedRestoredScenario(oldLines: gridRows + 20)
        try scrollUp(rows: 15)
        let base = capture()
        try dragSelect(fromRow: 1, fromCol: 0, toRow: 2, toCol: 7)
        XCTAssertEqual(
            changedRows(base, capture()), [1, 2],
            "click-drag in scrolled-up replayed scrollback must draw the selection wash")
    }

    func testDoubleClickSelectsBackfilledWord() throws {
        makeFixture()
        feedRestoredScenario(oldLines: gridRows - 3)
        view.mouseDown(with: try mouse(.leftMouseDown, row: 1, col: 2))
        view.mouseUp(with: try mouse(.leftMouseUp, row: 1, col: 2))
        view.mouseDown(with: try mouse(.leftMouseDown, row: 1, col: 2, count: 2))
        view.mouseUp(with: try mouse(.leftMouseUp, row: 1, col: 2, count: 2))
        XCTAssertEqual(view.copyVirtualSelection(), "old-line-2")
    }
}

private final class RestoredSelTransport: WaveTransport, @unchecked Sendable {
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
    ) async throws -> Res { throw WaveError.notConnected }
    func callVoid<Req: Encodable & Sendable>(
        command: String, data: Req?, route: String?, timeoutMs: Int64?
    ) async throws {}
    func notify<Req: Encodable & Sendable>(command: String, data: Req?, route: String?) throws {}
    func stream<Req: Encodable & Sendable>(
        command: String, data: Req?, route: String?,
        onChunk: @escaping @Sendable (Result<RpcMessage, WaveError>) -> Void
    ) throws -> SubscriptionToken { SubscriptionToken {} }
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
    ) -> SubscriptionToken { SubscriptionToken {} }
}
#endif
