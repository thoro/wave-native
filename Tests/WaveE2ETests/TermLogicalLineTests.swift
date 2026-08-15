// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Tests for TermLogicalLine — the pure soft-wrap joiner that lets URL/path
// autodetection see a full token wrapped over several visual rows (narrow
// pane), and maps a matched range back to per-row column spans for the hover
// underline. The render-state/history slice collection in GhosttyTerminalView
// is integration-only and not covered here.

import XCTest
@testable import WaveTerminal

final class TermLogicalLineTests: XCTestCase {

    private func slice(row: Int, _ text: String, wrapped: Bool) -> TermRowSlice {
        TermRowSlice(row: row, text: text, offsets: Array(0..<(text as NSString).length), wrapped: wrapped)
    }

    private func col(_ line: String, of substring: String) -> Int {
        let r = (line as NSString).range(of: substring)
        XCTAssertNotEqual(r.location, NSNotFound, "substring not found: \(substring)")
        return r.location
    }

    func testWrappedURLResolvesFromEitherRow() {
        // The reported bug: a Bitbucket PR link soft-wrapped by a narrow window
        // was detected per visual row, so Cmd-click opened a truncated URL.
        let full = "https://bitbucket.example.com/projects/ACME/repos/widget-catalog-service/"
            + "pull-requests?create&sourceBranch=refs%2Fheads%2FPROJ-12345"
        let row0 = "remote:   " + String(full.prefix(40))
        let row1 = String(full.dropFirst(40).prefix(50))
        let row2 = String(full.dropFirst(90))
        let rows = [
            slice(row: 0, row0, wrapped: true),
            slice(row: 1, row1, wrapped: true),
            slice(row: 2, row2, wrapped: false),
        ]
        for (index, clickCol) in [(0, 12), (1, 5), (2, 3)] {
            let line = TermLogicalLine.around(rows: rows, index: index)
            XCTAssertNotNil(line)
            guard let line, let offset = line.utf16Offset(row: index, col: clickCol) else { continue }
            XCTAssertEqual(TerminalURLDetect.urlAt(line: line.text, column: offset), full,
                           "row \(index) col \(clickCol)")
        }
    }

    func testAnchorOnContinuationRowWalksUpToLineStart() {
        let rows = [
            slice(row: 0, "before text here", wrapped: false),
            slice(row: 1, "see https://example.com/a", wrapped: true),
            slice(row: 2, "b/c now", wrapped: false),
        ]
        guard let line = TermLogicalLine.around(rows: rows, index: 2) else {
            return XCTFail("no logical line")
        }
        XCTAssertEqual(line.text, "see https://example.com/ab/c now")
        XCTAssertNil(line.utf16Offset(row: 0, col: 0), "row above the wrap run is not part of the line")
        XCTAssertEqual(TerminalURLDetect.urlAt(line: line.text, column: line.utf16Offset(row: 2, col: 1)!),
                       "https://example.com/ab/c")
    }

    func testNonWrappedRowBehavesLikeSingleRowDetection() {
        let text = "open https://github.com/x/y for details"
        let rows = [
            slice(row: 0, "unrelated", wrapped: false),
            slice(row: 1, text, wrapped: false),
            slice(row: 2, "unrelated too", wrapped: false),
        ]
        guard let line = TermLogicalLine.around(rows: rows, index: 1) else {
            return XCTFail("no logical line")
        }
        XCTAssertEqual(line.text, text)
        XCTAssertEqual(TerminalURLDetect.urlAt(line: line.text, column: line.utf16Offset(row: 1, col: col(text, of: "github"))!),
                       "https://github.com/x/y")
    }

    func testSegmentsMapRangeBackToPerRowColumns() {
        let row0 = "remote:   https://x.com/abc"
        let row1 = "def/ghi ok"
        let rows = [slice(row: 0, row0, wrapped: true), slice(row: 1, row1, wrapped: false)]
        guard let line = TermLogicalLine.around(rows: rows, index: 0),
              let offset = line.utf16Offset(row: 0, col: col(row0, of: "x.com")),
              let (url, range) = TerminalURLDetect.urlRangeAt(line: line.text, column: offset) else {
            return XCTFail("no URL on joined line")
        }
        XCTAssertEqual(url, "https://x.com/abcdef/ghi")
        let segments = line.segments(in: range)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].row, 0)
        XCTAssertEqual(segments[0].cols, 10...26)
        XCTAssertEqual(segments[1].row, 1)
        XCTAssertEqual(segments[1].cols, 0...6)
    }

    func testJoinIsCappedAtMaxJoinRows() {
        var rows: [TermRowSlice] = []
        for r in 0...(2 * TermLogicalLine.MaxJoinRows + 2) {
            rows.append(slice(row: r, "aaaa", wrapped: true))
        }
        let anchor = TermLogicalLine.MaxJoinRows + 1
        guard let line = TermLogicalLine.around(rows: rows, index: anchor) else {
            return XCTFail("no logical line")
        }
        XCTAssertEqual((line.text as NSString).length, (2 * TermLogicalLine.MaxJoinRows + 1) * 4)
        XCTAssertNotNil(line.utf16Offset(row: anchor, col: 0))
        XCTAssertNil(line.utf16Offset(row: rows.count - 1, col: 0))
    }

    func testNthOccurrenceCountsLogicalLinesTopDown() {
        let rows = [
            slice(row: 0, "error one", wrapped: false),
            slice(row: 1, "all fine", wrapped: false),
            slice(row: 2, "ERROR two", wrapped: false),
            slice(row: 3, "error three", wrapped: false),
        ]
        XCTAssertEqual(TermLogicalLine.nthOccurrence(rows: rows, needle: "error", n: 0)?.row, 0)
        XCTAssertEqual(TermLogicalLine.nthOccurrence(rows: rows, needle: "error", n: 1)?.row, 2)
        XCTAssertEqual(TermLogicalLine.nthOccurrence(rows: rows, needle: "error", n: 2)?.row, 3)
        XCTAssertNil(TermLogicalLine.nthOccurrence(rows: rows, needle: "error", n: 3))
    }

    func testNthOccurrenceCountsWrapRunOnce() {
        // "error error" on one wrapped logical line counts as ONE occurrence
        // line (backend search reports one match per raw line), and a needle
        // spanning the wrap boundary still counts.
        let rows = [
            slice(row: 0, "error err", wrapped: true),
            slice(row: 1, "or tail", wrapped: false),
            slice(row: 2, "error again", wrapped: false),
        ]
        let first = TermLogicalLine.nthOccurrence(rows: rows, needle: "error", n: 0)
        XCTAssertEqual(first?.row, 0)
        XCTAssertEqual(first?.col, 0)
        XCTAssertEqual(TermLogicalLine.nthOccurrence(rows: rows, needle: "error", n: 1)?.row, 2)
        XCTAssertNil(TermLogicalLine.nthOccurrence(rows: rows, needle: "error", n: 2))
    }

    func testNthOccurrenceSpanningWrapBoundaryReturnsFirstSegment() {
        let rows = [
            slice(row: 0, "xxxxxne", wrapped: true),
            slice(row: 1, "edle yy", wrapped: false),
        ]
        let hit = TermLogicalLine.nthOccurrence(rows: rows, needle: "needle", n: 0)
        XCTAssertEqual(hit?.row, 0)
        XCTAssertEqual(hit?.col, 5)
    }

    func testNthOccurrenceEmptyInputs() {
        XCTAssertNil(TermLogicalLine.nthOccurrence(rows: [], needle: "x", n: 0))
        XCTAssertNil(TermLogicalLine.nthOccurrence(rows: [slice(row: 0, "x", wrapped: false)], needle: "", n: 0))
        XCTAssertNil(TermLogicalLine.nthOccurrence(rows: [slice(row: 0, "x", wrapped: false)], needle: "x", n: -1))
    }

    func testOutOfBoundsInputs() {
        let rows = [slice(row: 0, "hello", wrapped: false)]
        XCTAssertNil(TermLogicalLine.around(rows: rows, index: -1))
        XCTAssertNil(TermLogicalLine.around(rows: rows, index: 1))
        XCTAssertNil(TermLogicalLine.around(rows: [], index: 0))
        guard let line = TermLogicalLine.around(rows: rows, index: 0) else {
            return XCTFail("no logical line")
        }
        XCTAssertNil(line.utf16Offset(row: 0, col: -1))
        XCTAssertNil(line.utf16Offset(row: 0, col: 5))
        XCTAssertNil(line.utf16Offset(row: 3, col: 0))
    }
}
