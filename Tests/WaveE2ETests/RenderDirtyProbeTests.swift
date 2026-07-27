// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Pins the libghostty render-state dirty semantics the view's damage pipeline
// relies on (GhosttyTerminalView.terminalDamageAndReset). If a vendored ghostty
// bump changes any of these, partial-row repainting silently breaks — these
// assertions turn that into a loud test failure.

#if canImport(CGhostty)
import XCTest
import CGhostty
@testable import WaveTerminal

final class RenderDirtyProbeTests: XCTestCase {
    func testDirtySemanticsTheDamagePipelineRequires() throws {
        var t: GhosttyTerminal?
        var opts = GhosttyTerminalOptions()
        opts.cols = 10
        opts.rows = 5
        opts.max_scrollback = 1_000_000
        XCTAssertEqual(ghostty_terminal_new(nil, &t, opts), GHOSTTY_SUCCESS)
        guard let t else { return }
        defer { ghostty_terminal_free(t) }

        var st: GhosttyRenderState?
        _ = ghostty_render_state_new(nil, &st)
        var iterHandle: GhosttyRenderStateRowIterator?
        _ = ghostty_render_state_row_iterator_new(nil, &iterHandle)
        defer {
            if let st { ghostty_render_state_free(st) }
            if let iterHandle { ghostty_render_state_row_iterator_free(iterHandle) }
        }

        func write(_ s: String) {
            let d = Array(s.utf8)
            d.withUnsafeBufferPointer { ghostty_terminal_vt_write(t, $0.baseAddress, $0.count) }
        }

        func updateAndCollect() -> (global: GhosttyRenderStateDirty, rows: [Int]) {
            _ = ghostty_render_state_update(st, t)
            var dirty = GHOSTTY_RENDER_STATE_DIRTY_FULL
            _ = ghostty_render_state_get(st, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
            var rows: [Int] = []
            var it = iterHandle
            _ = ghostty_render_state_get(st, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &it)
            var row = 0
            while ghostty_render_state_row_iterator_next(it) {
                var rowDirty = false
                _ = ghostty_render_state_row_get(it, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty)
                if rowDirty { rows.append(row) }
                var clean = false
                _ = ghostty_render_state_row_set(it, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean)
                row += 1
            }
            var cleanState = GHOSTTY_RENDER_STATE_DIRTY_FALSE
            _ = ghostty_render_state_set(st, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &cleanState)
            return (dirty, rows)
        }

        write("l1\r\nl2\r\nl3\r\nl4\r\nl5")
        _ = updateAndCollect()

        write("x")
        let nonscroll = updateAndCollect()
        XCTAssertEqual(nonscroll.rows, [4], "a plain write must flag exactly the written row")

        // A viewport scroll invalidates every row position; the pipeline depends on
        // global FULL here — per-row flags alone would leave stale pre-scroll rows.
        write("\r\nl6")
        let scroll = updateAndCollect()
        XCTAssertEqual(scroll.global, GHOSTTY_RENDER_STATE_DIRTY_FULL,
                       "a scroll must escalate the global dirty state to FULL")

        write("\u{1b}[2;4r\u{1b}[2;1H\u{1b}[1S\u{1b}[r")
        let regionScroll = updateAndCollect()
        XCTAssertEqual(regionScroll.rows, [0, 1, 2, 3, 4],
                       "a scroll-region scroll must flag all viewport rows")

        // KNOWN GAP the view compensates for (see lastDamageCursorRow): a pure
        // cursor move flags nothing. If ghostty starts flagging it, the hack can go.
        write("\u{1b}[H")
        let cursorOnly = updateAndCollect()
        XCTAssertEqual(cursorOnly.rows, [], "pure cursor motion currently flags no rows")

        // draw(_:) re-runs render_state_update WITHOUT collecting; flags from a
        // prior write must survive that intermediate update (OR, not overwrite),
        // or the flush→draw race would eat damage.
        write("\u{1b}[5;10Hz")
        _ = ghostty_render_state_update(st, t)
        write("\u{1b}[2;1Hy")
        let interleaved = updateAndCollect()
        XCTAssertTrue(interleaved.rows.contains(4),
                      "damage consumed by an uncollected update must survive to the next collection")
        XCTAssertTrue(interleaved.rows.contains(1))
    }
}
#endif
