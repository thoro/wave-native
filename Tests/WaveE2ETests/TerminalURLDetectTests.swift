// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Tests for TerminalURLDetect — the pure URL-token-under-column helper that backs
// Cmd-click-to-open for plain (non-OSC-8) URLs. The render-state cell reading and
// the mouseDown wiring in GhosttyTerminalView are integration-only (they require a
// live libghostty terminal + AppKit event) and are not covered here.

import XCTest
@testable import WaveTerminal

final class TerminalURLDetectTests: XCTestCase {

    private func col(_ line: String, of substring: String, offset: Int = 1) -> Int {
        let r = (line as NSString).range(of: substring)
        XCTAssertNotEqual(r.location, NSNotFound, "substring not found: \(substring)")
        return r.location + offset
    }

    func testHttpsURLReturnedWhenClickInside() {
        let line = "open https://github.com/x/y for details"
        XCTAssertEqual(TerminalURLDetect.urlAt(line: line, column: col(line, of: "github")),
                       "https://github.com/x/y")
    }

    func testHttpLocalhostWithPortAndPath() {
        let line = "serving at http://localhost:3000/path now"
        XCTAssertEqual(TerminalURLDetect.urlAt(line: line, column: col(line, of: "localhost")),
                       "http://localhost:3000/path")
    }

    func testBareWWWNormalizedToHTTP() {
        // NSDataDetector promotes a bare www. host to an http:// URL.
        let line = "go to www.example.com today"
        XCTAssertEqual(TerminalURLDetect.urlAt(line: line, column: col(line, of: "example")),
                       "http://www.example.com")
    }

    func testFileURL() {
        let line = "edit file:///Users/x/notes.txt here"
        XCTAssertEqual(TerminalURLDetect.urlAt(line: line, column: col(line, of: "Users")),
                       "file:///Users/x/notes.txt")
    }

    func testClickOnSurroundingTextReturnsNil() {
        let line = "open https://github.com/x/y for details"
        XCTAssertNil(TerminalURLDetect.urlAt(line: line, column: col(line, of: "details")))
        XCTAssertNil(TerminalURLDetect.urlAt(line: line, column: 0))
    }

    func testTrailingPunctuationTrimmed() {
        let line = "see https://x.com."
        XCTAssertEqual(TerminalURLDetect.urlAt(line: line, column: col(line, of: "x.com")),
                       "https://x.com")
        let line2 = "ref https://x.com/path), ok"
        XCTAssertEqual(TerminalURLDetect.urlAt(line: line2, column: col(line2, of: "path")),
                       "https://x.com/path")
    }

    func testBalancedParensKept() {
        let line = "wiki (https://en.wikipedia.org/wiki/Foo_(bar)) page"
        XCTAssertEqual(TerminalURLDetect.urlAt(line: line, column: col(line, of: "wikipedia")),
                       "https://en.wikipedia.org/wiki/Foo_(bar)")
    }

    func testMultipleURLsReturnsOneUnderColumn() {
        let line = "a http://first.com/q b https://second.com/z end"
        XCTAssertEqual(TerminalURLDetect.urlAt(line: line, column: col(line, of: "first")),
                       "http://first.com/q")
        XCTAssertEqual(TerminalURLDetect.urlAt(line: line, column: col(line, of: "second")),
                       "https://second.com/z")
    }

    func testEmptyAndOutOfRange() {
        XCTAssertNil(TerminalURLDetect.urlAt(line: "", column: 0))
        XCTAssertNil(TerminalURLDetect.urlAt(line: "https://x.com", column: -1))
        XCTAssertNil(TerminalURLDetect.urlAt(line: "https://x.com", column: 999))
    }

    // urlRangeAt backs the hover underline: it returns the same URL as urlAt PLUS the
    // matched char range, with trailing sentence punctuation excluded from the range.
    func testURLRangeCoversTheURLToken() {
        let line = "open https://github.com/x/y for details"
        let result = TerminalURLDetect.urlRangeAt(line: line, column: col(line, of: "github"))
        XCTAssertEqual(result?.url, "https://github.com/x/y")
        let r = (line as NSString).range(of: "https://github.com/x/y")
        XCTAssertEqual(result?.range.location, r.location)
        XCTAssertEqual(result?.range.length, r.length)
    }

    func testURLRangeExcludesTrailingPunctuation() {
        let line = "see https://x.com."
        let result = TerminalURLDetect.urlRangeAt(line: line, column: col(line, of: "x.com"))
        XCTAssertEqual(result?.url, "https://x.com")
        // The range must stop before the sentence-final ".".
        let urlRange = (line as NSString).range(of: "https://x.com")
        XCTAssertEqual(result?.range.length, urlRange.length)
    }

    func testURLRangeNilOffURL() {
        let line = "open https://github.com/x/y for details"
        XCTAssertNil(TerminalURLDetect.urlRangeAt(line: line, column: col(line, of: "details")))
    }
}
