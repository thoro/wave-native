// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Pins the libghostty coordinate-basis fact the view's unified selection relies
// on: on a no-scrollback screen (the alt screen vi/less run on) the scrollbar
// deliberately reports offset 0 while the page list may still hold grown rows
// above the active area — rows the SCREEN point tag DOES count. Any code that
// converts between viewport and SCREEN rows via the scrollbar offset is
// therefore wrong on the alt screen (selections land one row off).

#if canImport(CGhostty)
import XCTest
import CGhostty
@testable import WaveTerminal

final class TerminalSelectionBasisTests: XCTestCase {
    private func write(_ t: GhosttyTerminal, _ s: String) {
        let d = Array(s.utf8)
        d.withUnsafeBufferPointer { ghostty_terminal_vt_write(t, $0.baseAddress, $0.count) }
    }

    private func screenY(_ t: GhosttyTerminal, viewportRow: Int) -> Int? {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: 0, y: UInt32(viewportRow))
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.stride
        guard ghostty_terminal_grid_ref(t, point, &ref) == GHOSTTY_SUCCESS else { return nil }
        var out = GhosttyPointCoordinate()
        guard ghostty_terminal_point_from_grid_ref(t, &ref, GHOSTTY_POINT_TAG_SCREEN, &out) == GHOSTTY_SUCCESS
        else { return nil }
        return Int(out.y)
    }

    func testAltScreenScreenPointBasisMatchesRowsAboveActiveArea() throws {
        var t: GhosttyTerminal?
        var opts = GhosttyTerminalOptions()
        opts.cols = 10
        opts.rows = 5
        opts.max_scrollback = 1_000_000
        XCTAssertEqual(ghostty_terminal_new(nil, &t, opts), GHOSTTY_SUCCESS)
        guard let t else { return }
        defer { ghostty_terminal_free(t) }

        write(t, "p1\r\np2\r\np3")
        write(t, "\u{1b}[?1049h")
        for i in 1...12 {
            write(t, "alt\(i)\(i < 12 ? "\r\n" : "")")
        }

        var sb = GhosttyTerminalScrollbar()
        XCTAssertEqual(ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb), GHOSTTY_SUCCESS)
        var totalRows = 0
        XCTAssertEqual(ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &totalRows), GHOSTTY_SUCCESS)
        let origin = try XCTUnwrap(screenY(t, viewportRow: 0))

        XCTAssertEqual(Int(sb.offset), 0, "no-scrollback scrollbar always reports offset 0")
        XCTAssertEqual(
            origin, totalRows - 5,
            "SCREEN points count any rows retained above the active area; the scrollbar would hide them, which is why selection math must use the grid-ref SCREEN basis, never the scrollbar offset")
    }

    func testPrimaryScreenScrollbarOffsetMatchesScreenPoints() throws {
        var t: GhosttyTerminal?
        var opts = GhosttyTerminalOptions()
        opts.cols = 10
        opts.rows = 5
        opts.max_scrollback = 1_000_000
        XCTAssertEqual(ghostty_terminal_new(nil, &t, opts), GHOSTTY_SUCCESS)
        guard let t else { return }
        defer { ghostty_terminal_free(t) }

        for i in 1...12 {
            write(t, "line\(i)\(i < 12 ? "\r\n" : "")")
        }

        var sb = GhosttyTerminalScrollbar()
        XCTAssertEqual(ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb), GHOSTTY_SUCCESS)
        let origin = try XCTUnwrap(screenY(t, viewportRow: 0))
        XCTAssertEqual(origin, Int(sb.offset), "primary screen: both bases agree")
        XCTAssertGreaterThan(origin, 0)
    }
}
#endif
