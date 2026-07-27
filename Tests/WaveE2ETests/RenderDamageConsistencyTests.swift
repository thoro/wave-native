// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Damage-consistency harness: drives the REAL collect→paint pipeline
// (terminalDamageAndReset + draw(_:)) against an accumulated backing bitmap the
// way AppKit's backing store accumulates partial redraws, with adversarial feed
// interleavings (feeds landing BETWEEN damage collection and the draw that
// consumes it — the race a live pty stream hits constantly). After quiescence
// (drain pending damage exactly as a scheduled flush would), the accumulated
// bitmap must be pixel-identical to a from-scratch full redraw. A mismatch means
// damage was lost — the "scrambled TUI until you select everything" bug.

#if canImport(CGhostty)
import XCTest
import AppKit
import WaveCore
@testable import WaveTerminal

/// Inert transport: the harness feeds the sink directly, so the controller's
/// transport is never exercised beyond protocol conformance.
private final class StubTransport: WaveTransport, @unchecked Sendable {
    var addrs: ServerAddrs? = ServerAddrs(wsAddr: "127.0.0.1:1", webAddr: "127.0.0.1:2")
    var routeId: String? = "window:test"
    var isConnected = true
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
    func subscribe(
        _ request: SubscriptionRequest, handler: @escaping @Sendable (WaveEvent) -> Void
    ) -> SubscriptionToken { SubscriptionToken {} }
}

final class RenderDamageConsistencyTests: XCTestCase {
    private var window: NSWindow!
    private var view: GhosttyTerminalView!
    private var sink: GhosttySink!
    private var controller: TerminalController!

    private let viewSize = NSSize(width: 420, height: 180)

    override func setUp() {
        super.setUp()
        sink = GhosttySink(cols: 80, rows: 24)
        controller = TerminalController(
            blockId: "11111111-1111-1111-1111-111111111111",
            tabId: "22222222-2222-2222-2222-222222222222",
            transport: StubTransport(),
            sink: sink)
        view = GhosttyTerminalView(
            controller: controller, sink: sink,
            font: .monospacedSystemFont(ofSize: 11, weight: .regular))
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: viewSize),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.setFrameSize(viewSize)
    }

    override func tearDown() {
        window = nil
        view = nil
        controller = nil
        sink = nil
        super.tearDown()
    }

    private func makeBitmap() -> NSBitmapImageRep {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(viewSize.width), pixelsHigh: Int(viewSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    }

    /// Paint `damage` into `bitmap` through the real `draw(_:)`, clipped exactly to
    /// the damage rects (the backing-store contract: pixels outside stay stale).
    private func paint(_ damage: GhosttyTerminalView.TerminalDamage, into bitmap: NSBitmapImageRep) {
        let rects: [NSRect]
        switch damage {
        case .none:
            return
        case .full:
            rects = [view.bounds]
        case .rows(let ranges):
            // Mirrors GhosttyTerminalView.invalidate(.rows): padV = 4, full width.
            let ch = GhosttyTerminalView.measureCell(
                font: .monospacedSystemFont(ofSize: 11, weight: .regular)).height
            rects = ranges.map { range in
                NSRect(x: 0, y: 4 + CGFloat(range.lowerBound) * ch,
                       width: view.bounds.width,
                       height: CGFloat(range.count) * ch)
            }
        }
        guard let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        for rect in rects {
            ctx.cgContext.saveGState()
            ctx.cgContext.clip(to: rect)
            view.draw(rect)
            ctx.cgContext.restoreGState()
        }
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func fullRepaintReference() -> NSBitmapImageRep {
        let bitmap = makeBitmap()
        paint(.full, into: bitmap)
        return bitmap
    }

    private func assertConverged(_ accumulated: NSBitmapImageRep, seed: Int, step: String) {
        let reference = fullRepaintReference()
        XCTAssertEqual(accumulated.tiffRepresentation, reference.tiffRepresentation,
                       "accumulated partial redraws diverged from full redraw (seed \(seed), \(step))")
    }

    /// Claude-Code-shaped output: cursor-addressed row rewrites, SGR runs, erase-to-EOL,
    /// scrolls, region scrolls, sync-mode wraps. Deterministic per seed.
    private func chunk(op: Int, rng: inout UInt64) -> String {
        func rand(_ n: Int) -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int((rng >> 33) % UInt64(n))
        }
        switch op % 8 {
        case 0: return "\u{1b}[\(1 + rand(24));1H\u{1b}[2Kline-\(rand(999)) \u{1b}[38;5;\(rand(255))mcolored\u{1b}[0m tail"
        case 1: return "\r\nscrolled-\(rand(999))"
        case 2: return "\u{1b}[\(1 + rand(24));\(1 + rand(60))Hmid\(rand(99))"
        case 3: return "\u{1b}[?2026h\u{1b}[H\u{1b}[2Kframe-\(rand(999))\u{1b}[3;1H\u{1b}[2Kbody-\(rand(999))\u{1b}[?2026l"
        case 4: return "\u{1b}[2;20r\u{1b}[2;1H\u{1b}[1S\u{1b}[r\u{1b}[20;1Hregion-\(rand(999))"
        case 5: return "\u{1b}[48;2;\(rand(255));\(rand(255));\(rand(255))m  block  \u{1b}[0m"
        case 6: return "\u{1b}[\(1 + rand(24));1H\u{1b}[K"
        default: return "plain \(rand(9999)) text"
        }
    }

    func testInterleavedFeedsConvergeToFullRedraw() {
        var partialCount = 0
        var rowDamageTotal = 0
        for seed in 0..<40 {
            var rng = UInt64(seed &* 2654435761 &+ 1)
            sink.feed(Data("\u{1b}[2J\u{1b}[H".utf8))
            let accumulated = makeBitmap()
            paint(view.terminalDamageAndReset(), into: accumulated)

            for op in 0..<30 {
                sink.feed(Data(chunk(op: op, rng: &rng).utf8))
                let damage = view.terminalDamageAndReset()
                if case .rows(let ranges) = damage {
                    partialCount += 1
                    rowDamageTotal += ranges.reduce(0) { $0 + $1.count }
                }
                // The race: another chunk lands AFTER damage collection but BEFORE
                // the draw that consumes it (draw re-reads the newer state).
                sink.feed(Data(chunk(op: op &+ 3, rng: &rng).utf8))
                paint(damage, into: accumulated)
            }
            // Quiescence: the racy feeds above each re-signal onRender in real life,
            // so a final flush would run. Model exactly one more flush+draw.
            paint(view.terminalDamageAndReset(), into: accumulated)
            assertConverged(accumulated, seed: seed, step: "after drain flush")
        }
        // Vacuity guards: the run must exercise real partial-row repaints on a
        // real grid, or convergence proves nothing.
        print("HARNESS partial damages: \(partialCount), rows: \(rowDamageTotal)")
        XCTAssertGreaterThan(partialCount, 100, "harness must exercise partial-row damage")
        let reference = fullRepaintReference()
        XCTAssertNotEqual(reference.tiffRepresentation, makeBitmap().tiffRepresentation,
                          "reference render must not be blank")
    }
}
#endif
