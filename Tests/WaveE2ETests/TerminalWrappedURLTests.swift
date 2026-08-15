// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// A long URL soft-wrapped across sink rows (git's "Create a pull request"
// hint in a narrow pane) must autodetect as the FULL url from any row of the
// wrap run. Regression: the RAW row out-param was an Optional GhosttyRow —
// the C side writes only the payload bytes, the optional's tag stayed nil,
// and every row's wrap flag silently read false, so detection truncated the
// URL at the first row boundary and the continuation rows detected nothing.

#if canImport(CGhostty) && canImport(AppKit)
import AppKit
import XCTest
import CGhostty
import WaveCore
@testable import WaveTerminal

final class TerminalWrappedURLTests: XCTestCase {
    func testWrappedGitPushURLDetectsFullURLFromEveryRow() throws {
        let sink = GhosttySink(cols: 40, rows: 10)
        let controller = TerminalController(
            blockId: "11111111-1111-1111-1111-111111111111",
            tabId: "22222222-2222-2222-2222-222222222222",
            transport: WrappedURLTransport(),
            sink: sink)
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let view = GhosttyTerminalView(controller: controller, sink: sink, font: font)
        let size = NSSize(width: 300, height: 160)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.setFrameSize(size)

        let url = "https://github.com/exampleorg-ltd/infra_tf-widgets/pull/new/feat/external-dns"
        var out = "remote: Create a pull request for 'feat/external-dns' on GitHub by visiting:\r\n"
        out += "remote:      \(url)\r\n"
        out += "remote:\r\n"
        sink.feed(Data(out.utf8))

        let cell = GhosttyTerminalView.measureCell(font: font)
        func event(row: Int, col: Int) -> NSEvent {
            let localPoint = NSPoint(
                x: 10 + CGFloat(col) * cell.width + cell.width / 2,
                y: 4 + CGFloat(row) * cell.height + cell.height / 2)
            return NSEvent.mouseEvent(
                with: .leftMouseDown, location: view.convert(localPoint, to: nil),
                modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }

        // "remote: Create a pull request..." (77 chars) wraps over rows 0-1; the
        // URL line (89 chars) covers rows 2-4. The URL must resolve identically
        // from its first row and from its continuation row.
        XCTAssertEqual(view.autodetectedURL(for: event(row: 2, col: 20)), url)
        XCTAssertEqual(view.autodetectedURL(for: event(row: 3, col: 20)), url)
        XCTAssertEqual(view.autodetectedURL(for: event(row: 4, col: 2)), url)
        XCTAssertNil(view.autodetectedURL(for: event(row: 5, col: 2)), "blank row must not detect a URL")
    }
}

private final class WrappedURLTransport: WaveTransport, @unchecked Sendable {
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
    ) throws -> SubscriptionToken { SubscriptionToken { } }

    func callService(_ call: WebCallType) async throws -> WebReturnType { throw WaveError.notConnected }

    func fetchFile(zoneId: String, name: String, offset: Int64) async throws -> (data: Data, info: WaveFile) {
        throw WaveError.notConnected
    }

    func fetchFileRange(zoneId: String, name: String, range: FileFetchRange) async throws -> FileFetchResult {
        throw WaveError.notConnected
    }

    func subscribe(
        _ request: SubscriptionRequest, handler: @escaping @Sendable (WaveEvent) -> Void
    ) -> SubscriptionToken { SubscriptionToken { } }
}
#endif
