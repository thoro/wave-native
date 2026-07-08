// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Tests for the virtualized-scrollback groundwork: the segmented dataStartIdx
// mirror (must match pkg/filestore/blockstore.go:84-97 exactly), the tail
// backfill reconcile, and the sink scrollback settings resolution.

import XCTest
import WaveCore
@testable import WaveTerminal

private func segFile(size: Int64, maxsize: Int64) -> WaveFile {
    WaveFile(
        zoneid: "zone",
        name: WaveProtocolConst.blockFileTerm,
        opts: FileOpts(maxsize: maxsize, compressed: true, segmented: true),
        createdts: 0,
        size: size,
        modts: 0)
}

private func d(_ s: String) -> Data { Data(s.utf8) }
private func s(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

final class SegmentedDataStartIdxTests: XCTestCase {
    private let part: Int64 = 65536

    // mirrors the Go math: maxParts = maxsize/part; firstSeg = (size-1)/part + 1 - maxParts
    func testBelowMax() {
        XCTAssertEqual(segFile(size: part * 3, maxsize: part * 4).dataStartIdx, 0)
    }

    func testExactlyMax() {
        XCTAssertEqual(segFile(size: part * 4, maxsize: part * 4).dataStartIdx, 0)
    }

    func testOnePastMax() {
        // size = 4 parts + 1 byte -> highest seg 4, firstSeg 1
        XCTAssertEqual(segFile(size: part * 4 + 1, maxsize: part * 4).dataStartIdx, part)
    }

    func testLarge() {
        let maxsize: Int64 = 256 * 1024 * 1024
        let size: Int64 = 300 * 1024 * 1024
        let maxParts = maxsize / part
        let firstSeg = (size - 1) / part + 1 - maxParts
        XCTAssertEqual(segFile(size: size, maxsize: maxsize).dataStartIdx, firstSeg * part)
    }

    func testUnlimited() {
        XCTAssertEqual(segFile(size: 1 << 40, maxsize: 0).dataStartIdx, 0)
    }

    func testEmpty() {
        XCTAssertEqual(segFile(size: 0, maxsize: part).dataStartIdx, 0)
    }

    func testDataLength() {
        let f = segFile(size: part * 4 + 1, maxsize: part * 4)
        XCTAssertEqual(f.dataLength, f.size - f.dataStartIdx)
    }
}

final class TailBackfillTests: XCTestCase {

    func testTailBackfillAnchorsAtServerStart() throws {
        var r = TerminalReconciler(startOffset: 0)
        // file is 100 bytes, tail body is the last 5
        let (out, actualStart) = try r.applyTailBackfill(data: d("tail!"), info: segFile(size: 100, maxsize: 0))
        XCTAssertEqual(s(out), "tail!")
        XCTAssertEqual(actualStart, 95)
        XCTAssertEqual(r.absOffset, 100)
        XCTAssertTrue(r.loaded)
    }

    func testTailBackfillMergesBufferedOverlap() throws {
        var r = TerminalReconciler(startOffset: 0)
        // live appends raced the GET: last 3 bytes of the tail plus 2 new ones
        XCTAssertEqual(r.append(d("il!XY")).count, 0)
        let (out, actualStart) = try r.applyTailBackfill(data: d("tail!"), info: segFile(size: 100, maxsize: 0))
        XCTAssertEqual(s(out), "tail!XY")
        XCTAssertEqual(actualStart, 95)
        XCTAssertEqual(r.absOffset, 102)
    }

    func testTailBackfillEmptyFile() throws {
        var r = TerminalReconciler(startOffset: 0)
        let (out, actualStart) = try r.applyTailBackfill(data: Data(), info: segFile(size: 0, maxsize: 0))
        XCTAssertEqual(out.count, 0)
        XCTAssertEqual(actualStart, 0)
        XCTAssertTrue(r.loaded)
    }

    func testTailBackfillLongerThanFileThrows() throws {
        var r = TerminalReconciler(startOffset: 0)
        XCTAssertThrowsError(try r.applyTailBackfill(data: d("toolong"), info: segFile(size: 3, maxsize: 0)))
    }

    func testLiveAppendsAfterTailBackfill() throws {
        var r = TerminalReconciler(startOffset: 0)
        _ = try r.applyTailBackfill(data: d("abc"), info: segFile(size: 3, maxsize: 0))
        XCTAssertEqual(s(r.append(d("def"))), "def")
        XCTAssertEqual(r.absOffset, 6)
    }
}

private func histRow(_ plain: String, wrapped: Bool = false, continuation: Bool = false) -> TermHistoryRow {
    TermHistoryRow(cells: [], plain: plain, offsets: plain.enumerated().map { $0.offset }, wrapped: wrapped, isContinuation: continuation)
}

final class SeamMatchTests: XCTestCase {

    func testUniqueMatch() {
        let rows = ["a", "b", "target", "next", "more"].map { histRow($0) }
        let idx = TerminalHistoryModel.matchSignature(["target", "next"], in: rows, nearRow: nil)
        XCTAssertEqual(idx, 2)
    }

    func testTrailingSpacesIgnored() {
        let rows = [histRow("prompt$   "), histRow("out")]
        let idx = TerminalHistoryModel.matchSignature(["prompt$", "out   "], in: rows, nearRow: nil)
        XCTAssertEqual(idx, 0)
    }

    func testEmptySignatureRowsAreWildcards() {
        let rows = ["x", "hit", "anything", "y"].map { histRow($0) }
        let idx = TerminalHistoryModel.matchSignature(["", "hit", ""], in: rows, nearRow: nil)
        // signature[1] anchors at rows[1], so the match starts one row above
        XCTAssertEqual(idx, 0)
    }

    func testPeriodicContentPicksNearest() {
        let rows = ["tick", "tock", "tick", "tock", "tick", "tock"].map { histRow($0) }
        let near = TerminalHistoryModel.matchSignature(["tick", "tock"], in: rows, nearRow: 4)
        XCTAssertEqual(near, 4)
        let far = TerminalHistoryModel.matchSignature(["tick", "tock"], in: rows, nearRow: 0)
        XCTAssertEqual(far, 0)
    }

    func testAllBlankSignatureReturnsNil() {
        let rows = ["a", "b"].map { histRow($0) }
        XCTAssertNil(TerminalHistoryModel.matchSignature(["", "   "], in: rows, nearRow: nil))
    }

    func testSignaturePastParsedRowsIsWildcard() {
        let rows = ["a", "last"].map { histRow($0) }
        let idx = TerminalHistoryModel.matchSignature(["last", "unparsed", "unparsed2"], in: rows, nearRow: nil)
        XCTAssertEqual(idx, 1)
    }

    func testNoMatch() {
        let rows = ["a", "b"].map { histRow($0) }
        XCTAssertNil(TerminalHistoryModel.matchSignature(["zzz"], in: rows, nearRow: nil))
    }
}

final class TermScrollbarMathTests: XCTestCase {

    func testNoBarWhenContentFits() {
        XCTAssertNil(TermScrollbarMath.geometry(
            topLine: 0, linesOnScreen: 50, totalLines: 40, matchLines: [], trackHeight: 500))
    }

    func testMarkersShowEvenWhenContentFits() {
        let geo = TermScrollbarMath.geometry(
            topLine: 0, linesOnScreen: 50, totalLines: 40, matchLines: [10], trackHeight: 500)
        XCTAssertEqual(geo?.markerYs.count, 1)
    }

    func testThumbSpansTrackProportionally() {
        let geo = TermScrollbarMath.geometry(
            topLine: 0, linesOnScreen: 100, totalLines: 1000, matchLines: [], trackHeight: 500)!
        XCTAssertEqual(geo.thumbHeight, 50, accuracy: 0.5)
        XCTAssertEqual(geo.thumbY, 0, accuracy: 0.5)
    }

    func testThumbAtBottom() {
        let geo = TermScrollbarMath.geometry(
            topLine: 900, linesOnScreen: 100, totalLines: 1000, matchLines: [], trackHeight: 500)!
        XCTAssertEqual(geo.thumbY + geo.thumbHeight, 500, accuracy: 0.5)
    }

    func testMarkerPositionsExactInLineSpace() {
        let geo = TermScrollbarMath.geometry(
            topLine: 0, linesOnScreen: 10, totalLines: 1000, matchLines: [0, 500, 1000], trackHeight: 1001)!
        XCTAssertEqual(geo.markerYs, [0, 500, 1000])
    }

    func testNearbyMarkersDedupePerPixel() {
        // 10k lines on a 100px track: lines 0..50 all land on pixel row 0
        let geo = TermScrollbarMath.geometry(
            topLine: 0, linesOnScreen: 10, totalLines: 10000,
            matchLines: Array(0...50).map(Int64.init), trackHeight: 100)!
        XCTAssertEqual(geo.markerYs.count, 1)
    }

    func testClickToLineRoundTrip() {
        XCTAssertEqual(TermScrollbarMath.line(atTrackY: 250, trackHeight: 500, totalLines: 1000), 500)
        XCTAssertEqual(TermScrollbarMath.line(atTrackY: 0, trackHeight: 500, totalLines: 1000), 0)
        XCTAssertEqual(TermScrollbarMath.line(atTrackY: 500, trackHeight: 500, totalLines: 1000), 1000)
    }
}

final class HistoryChunkParserTests: XCTestCase {

    func testParsesLargeChunk() {
        var bytes = Data()
        for i in 29800..<40000 {
            bytes.append(Data("\(i)\r\n".utf8))
        }
        let result = HistoryChunkParser.parseSync(
            bytes: bytes, cols: 80, warmupLines: 200, palette: nil, isCancelled: { false })
        XCTAssertNotNil(result)
        guard let result else { return }
        XCTAssertEqual(result.rows.count, 10000, "expected 10000 rows after 200-line warmup, got \(result.rows.count)")
        XCTAssertEqual(result.rows.first?.plain.hasPrefix("30000"), true, "first row was \(result.rows.first?.plain ?? "nil")")
        XCTAssertEqual(result.rows.last?.plain.hasPrefix("39999"), true, "last row was \(result.rows.last?.plain ?? "nil")")
        XCTAssertEqual(result.lineStartRows.count, 10000)
    }

    func testParsesSmallChunk() {
        let bytes = Data("alpha\r\nbeta\r\ngamma\r\n".utf8)
        let result = HistoryChunkParser.parseSync(
            bytes: bytes, cols: 80, warmupLines: 0, palette: nil, isCancelled: { false })
        XCTAssertEqual(result?.rows.count, 3)
        XCTAssertEqual(result?.rows[0].plain.hasPrefix("alpha"), true)
    }
}

final class PlainWordRangeTests: XCTestCase {

    func testWordExpansion() {
        XCTAssertEqual(GhosttyTerminalView.plainWordRange("hello world", col: 2), 0...4)
        XCTAssertEqual(GhosttyTerminalView.plainWordRange("hello world", col: 8), 6...10)
    }

    func testPunctuationBounds() {
        // path-ish tokens stay whole; brackets/quotes split
        XCTAssertEqual(GhosttyTerminalView.plainWordRange("ls /usr/local/bin today", col: 6), 3...16)
        XCTAssertEqual(GhosttyTerminalView.plainWordRange("(inner)", col: 3), 1...5)
        XCTAssertEqual(GhosttyTerminalView.plainWordRange("a \"quoted\" b", col: 5), 3...8)
    }

    func testBoundaryClickSelectsRun() {
        XCTAssertEqual(GhosttyTerminalView.plainWordRange("a    b", col: 3), 1...4)
        XCTAssertEqual(GhosttyTerminalView.plainWordRange("x((y", col: 2), 1...2)
    }

    func testOutOfRange() {
        XCTAssertNil(GhosttyTerminalView.plainWordRange("abc", col: 7))
        XCTAssertNil(GhosttyTerminalView.plainWordRange("", col: 0))
    }
}

final class ClampedSelectionColsTests: XCTestCase {

    func testInteriorRowSpansTextOnly() {
        XCTAssertEqual(GhosttyTerminalView.clampedSelectionCols(lo: 0, hi: 12, textWidth: 12), 0..<12)
    }

    func testEndpointBeyondTextClampsToTextEnd() {
        // drag ended at col 40 on a 12-char line
        XCTAssertEqual(GhosttyTerminalView.clampedSelectionCols(lo: 3, hi: 41, textWidth: 12), 3..<12)
    }

    func testSpanEntirelyInBlankRegionIsNoSelection() {
        XCTAssertNil(GhosttyTerminalView.clampedSelectionCols(lo: 20, hi: 30, textWidth: 12))
    }

    func testBlankRowGetsNoWash() {
        XCTAssertNil(GhosttyTerminalView.clampedSelectionCols(lo: 0, hi: 80, textWidth: 0))
    }

    func testNegativeLoClampsToZero() {
        XCTAssertEqual(GhosttyTerminalView.clampedSelectionCols(lo: -1, hi: 5, textWidth: 10), 0..<5)
    }

    func testEmptySpanIsNil() {
        XCTAssertNil(GhosttyTerminalView.clampedSelectionCols(lo: 5, hi: 5, textWidth: 10))
    }
}
