// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// E2E-4 — THE KEYSTONE (docs/E2E.md "Terminal (the keystone fuzz) ⭐"). Drives a
// REAL shell over a REAL wavesrv (real pty / filestore / wps broker — nothing
// mocked except libghostty, replaced by `LockedCapturingSink`) and asserts the
// byte stream the client feeds the sink equals the shell's actual stdout
// byte-for-byte — no dup, no drop — across the five required scenarios:
//
//   a) printf of a known string            -> exact byte match
//   b) seq flood >2 MB                       -> forces circular wrap; live stream
//                                              lossless (no dup/drop) (GUARDS §T)
//   c) clear (cmd:clearonstart + restart)    -> fileop=truncate clears the sink +
//                                              resets offset (GUARDS §T)
//   d) WS reconnect mid-stream               -> backfill+offset catch-up; every
//                                              byte produced during the outage is
//                                              delivered exactly once (GUARDS §A/§T)
//   e) resize                                -> termsize propagated to the pty
//                                              (TIOCSWINSZ), stream intact (GUARDS §T)
//
// Captures are extracted between echo-proof markers (see Marker), so they are
// immune to shell prompt/echo noise. The reconciler MATH is fuzzed separately and
// exhaustively in TerminalReconcilerFuzzTests.swift.

import XCTest
import WaveCore
@testable import WaveProtocol
@testable import WaveTerminal
import WaveStore
import WaveCommands

final class TerminalE2ETests: XCTestCase {

    /// (a) printf of a known string -> exact byte-for-byte match.
    func testPrintfExactBytes() async throws {
        let fx = try await TerminalE2EFixture.make(initialSize: TermSize(rows: 50, cols: 200))
        defer { fx.teardown() }
        try await fx.quiet()

        let payload = "hello, wave — byte-exact ✓ 12345"
        fx.send(Marker.line(tag: "A", body: "printf %s '\(payload)'"))

        let snap = try await fx.waitForSink {
            $0.slice(between: Marker.startToken("A"), and: Marker.endToken("A")) != nil
        }
        let seg = try XCTUnwrap(snap.slice(between: Marker.startToken("A"), and: Marker.endToken("A")))
        XCTAssertEqual(seg, Data(payload.utf8), "printf output must match the shell's stdout byte-for-byte")
    }

    /// (b) seq flood >2 MB -> forces the circular term file to wrap on disk; the
    /// LIVE event stream must still deliver every byte exactly once (no dup/drop).
    func testYesFloodOver2MBNoDupNoDrop() async throws {
        let fx = try await TerminalE2EFixture.make(initialSize: TermSize(rows: 50, cols: 200))
        defer { fx.teardown() }
        try await fx.quiet()

        // ~3.5 MB of output (>2 MB circular max) => the on-disk file wraps.
        let n = 500_000
        fx.send(Marker.line(tag: "B", body: "seq 1 \(n)"))

        let snap = try await fx.waitForSink(timeout: 90) {
            $0.slice(between: Marker.startToken("B"), and: Marker.endToken("B")) != nil
        }
        let seg = try XCTUnwrap(snap.slice(between: Marker.startToken("B"), and: Marker.endToken("B")))
        let ints = parseIntLines(seg)
        // Subscribed before the flood => the live path must carry the FULL sequence.
        assertContiguous(ints, expectedFirst: 1, expectedLast: n)
    }

    /// (c) clear -> a real server-side fileop=truncate clears the sink and resets
    /// the offset; subsequent output flows cleanly (GUARDS §T).
    func testClearTruncatesSink() async throws {
        let fx = try await TerminalE2EFixture.make(initialSize: TermSize(rows: 50, cols: 200))
        defer { fx.teardown() }
        try await fx.quiet()

        fx.send(Marker.line(tag: "C1", body: "printf %s before-clear-unique"))
        _ = try await fx.waitForSink {
            $0.slice(between: Marker.startToken("C1"), and: Marker.endToken("C1")) != nil
        }
        let prevClears = fx.sink.clearCount

        // Set cmd:clearonstart, then force-restart the controller -> the backend
        // truncates the "term" file and publishes fileop=truncate
        // (`shellcontroller.go:281`, `blockcontroller.go:391-415`).
        try await fx.commands.setMeta(.block(fx.blockId), meta: ["cmd:clearonstart": .bool(true)])
        try await fx.transport.callVoid(
            command: TerminalCommand.resync,
            data: CommandControllerResyncData(
                forcerestart: true, tabid: fx.tabId, blockid: fx.blockId,
                rtopts: RuntimeOpts(termsize: TermSize(rows: 50, cols: 200))))

        try await fx.waitForClear(after: prevClears)

        // The pre-clear content is gone from the sink (truncate cleared it).
        XCTAssertEqual(fx.sink.snapshot.occurrences(of: Marker.startToken("C1")), 0,
                       "truncate must clear previously-captured output")

        // New output after the clear is delivered cleanly.
        fx.send(Marker.line(tag: "C2", body: "printf %s after-clear-unique"))
        let snap2 = try await fx.waitForSink {
            $0.slice(between: Marker.startToken("C2"), and: Marker.endToken("C2")) != nil
        }
        let seg2 = try XCTUnwrap(snap2.slice(between: Marker.startToken("C2"), and: Marker.endToken("C2")))
        XCTAssertEqual(seg2, Data("after-clear-unique".utf8))
    }

    /// (d) WS reconnect mid-stream -> bytes produced while the socket is DOWN are
    /// caught up via the offset backfill exactly once, with no dup of pre-outage
    /// bytes and no gap (GUARDS §A re-subscribe + §T offset catch-up).
    func testReconnectMidStreamCatchUp() async throws {
        let fx = try await TerminalE2EFixture.make(initialSize: TermSize(rows: 50, cols: 200))
        defer { fx.teardown() }
        try await fx.quiet()

        fx.send(Marker.line(tag: "D0", body: "printf %s pre-outage"))
        _ = try await fx.waitForSink {
            $0.slice(between: Marker.startToken("D0"), and: Marker.endToken("D0")) != nil
        }
        XCTAssertEqual(fx.sink.snapshot.occurrences(of: Marker.startToken("D0")), 1)

        // ~0.3 MB produced entirely during the outage (< 2 MB => no overrun past
        // the consumed offset, so the catch-up is gap-free). The `sleep 1` keeps
        // output from starting until after we've disconnected.
        let n = 50_000
        // Tag is "D1" (not "D"): "WV_START_D" is a prefix of "WV_START_D0", so a "D"
        // tag would let `slice` match inside the pre-outage D0 markers and miss the
        // seq region entirely.
        fx.send("sleep 1; " + Marker.line(tag: "D1", body: "seq 1 \(n)"))
        // FIFO outbound queue: awaiting a round-trip getMeta proves the preceding
        // ControllerInput frame reached the server before we disconnect.
        _ = try await fx.commands.getMeta(.block(fx.blockId))

        fx.transport.disconnect()
        // Outage window: the shell runs `sleep 1` then floods while we're offline.
        try await Task.sleep(nanoseconds: 2_500_000_000)

        // Reconnect (re-announces + re-subscribes, GUARDS §A) and catch up the
        // bytes produced during the outage.
        try await fx.transport.connect(routeId: WaveRoute.window(fx.windowId))
        try await fx.controller.handleReconnect()

        let snap = try await fx.waitForSink(timeout: 30) {
            $0.slice(between: Marker.startToken("D1"), and: Marker.endToken("D1")) != nil
        }
        let seg = try XCTUnwrap(snap.slice(between: Marker.startToken("D1"), and: Marker.endToken("D1")))
        let ints = parseIntLines(seg)
        assertContiguous(ints, expectedFirst: 1, expectedLast: n)
        // The pre-outage marker must not be duplicated by the catch-up backfill.
        XCTAssertEqual(snap.occurrences(of: Marker.startToken("D0")), 1,
                       "reconnect must not re-deliver pre-outage bytes")
    }

    /// Overlapping catch-up backfills (sleep/wake flapping fires `onReconnect`
    /// repeatedly, spawning concurrent `handleReconnect` tasks) must NOT crash: the
    /// second backfill lands on an already-loaded reconciler and previously tripped
    /// its single-load precondition, SIGTRAP'ing the app. The stream must stay
    /// gap-free and duplicate-free.
    func testConcurrentReconnectsDoNotCrash() async throws {
        let fx = try await TerminalE2EFixture.make(initialSize: TermSize(rows: 50, cols: 200))
        defer { fx.teardown() }
        try await fx.quiet()

        fx.send(Marker.line(tag: "R0", body: "printf %s pre-outage"))
        _ = try await fx.waitForSink {
            $0.slice(between: Marker.startToken("R0"), and: Marker.endToken("R0")) != nil
        }

        let n = 20_000
        fx.send("sleep 1; " + Marker.line(tag: "R1", body: "seq 1 \(n)"))
        _ = try await fx.commands.getMeta(.block(fx.blockId))

        fx.transport.disconnect()
        try await Task.sleep(nanoseconds: 2_500_000_000)
        try await fx.transport.connect(routeId: WaveRoute.window(fx.windowId))

        // Fire several catch-up backfills concurrently, mirroring a flapping reconnect
        // that calls the `onReconnect` hook multiple times before the first completes.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { try await fx.controller.handleReconnect() }
            }
            try await group.waitForAll()
        }

        let snap = try await fx.waitForSink(timeout: 30) {
            $0.slice(between: Marker.startToken("R1"), and: Marker.endToken("R1")) != nil
        }
        let seg = try XCTUnwrap(snap.slice(between: Marker.startToken("R1"), and: Marker.endToken("R1")))
        assertContiguous(parseIntLines(seg), expectedFirst: 1, expectedLast: n)
        XCTAssertEqual(snap.occurrences(of: Marker.startToken("R0")), 1,
                       "concurrent reconnects must not re-deliver pre-outage bytes")
    }

    /// (e) resize -> the new termsize reaches the pty (verified via `stty size`),
    /// and the byte stream stays intact across the resize (GUARDS §T).
    func testResizePropagatesToPty() async throws {
        let fx = try await TerminalE2EFixture.make(initialSize: TermSize(rows: 50, cols: 120))
        defer { fx.teardown() }
        try await fx.quiet()

        // Initial size came from mount()'s ControllerResync rtopts.termsize.
        fx.send(Marker.line(tag: "E1", body: "stty size"))
        let s1 = try await fx.waitForSink {
            $0.slice(between: Marker.startToken("E1"), and: Marker.endToken("E1")) != nil
        }
        let size1 = decodeTrim(try XCTUnwrap(s1.slice(between: Marker.startToken("E1"), and: Marker.endToken("E1"))))
        XCTAssertEqual(size1, "50 120", "initial pty size must equal the resync termsize")

        fx.controller.resize(TermSize(rows: 24, cols: 90))
        XCTAssertEqual(fx.sink.lastSize, TermGridSize(cols: 90, rows: 24))
        // Give TIOCSWINSZ a moment to apply server-side.
        try await Task.sleep(nanoseconds: 400_000_000)

        fx.send(Marker.line(tag: "E2", body: "stty size"))
        let s2 = try await fx.waitForSink {
            $0.slice(between: Marker.startToken("E2"), and: Marker.endToken("E2")) != nil
        }
        let size2 = decodeTrim(try XCTUnwrap(s2.slice(between: Marker.startToken("E2"), and: Marker.endToken("E2"))))
        XCTAssertEqual(size2, "24 90", "resize must propagate the new termsize to the pty")
    }

    // MARK: - Assertions

    /// Assert a parsed counter run is strictly contiguous (each = prev+1) with the
    /// given endpoints — proving no dropped, duplicated, or reordered output.
    private func assertContiguous(
        _ ints: [Int], expectedFirst: Int, expectedLast: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(ints.isEmpty, "no counter output captured", file: file, line: line)
        guard !ints.isEmpty else { return } // avoid a `1..<0` range crash below
        XCTAssertEqual(ints.first, expectedFirst, "first counter value", file: file, line: line)
        XCTAssertEqual(ints.last, expectedLast, "last counter value", file: file, line: line)
        XCTAssertEqual(ints.count, expectedLast - expectedFirst + 1, "counter count (dup/drop)", file: file, line: line)
        for i in 1..<ints.count where ints[i] != ints[i - 1] + 1 {
            return XCTFail("non-contiguous at index \(i): \(ints[i - 1]) -> \(ints[i])", file: file, line: line)
        }
    }

    private func decodeTrim(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
