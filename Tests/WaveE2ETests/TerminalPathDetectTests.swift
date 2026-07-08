// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Tests for TerminalPathDetect — the pure path-token-under-column helper that backs
// Cmd-click-to-open for filesystem paths. Existence resolution (against the pane CWD)
// and the mouseDown/hover wiring in GhosttyTerminalView are integration-only and are
// not covered here; this verifies token extraction + decoration stripping.

import XCTest
@testable import WaveTerminal

final class TerminalPathDetectTests: XCTestCase {

    private func col(_ line: String, of substring: String, offset: Int = 1) -> Int {
        let r = (line as NSString).range(of: substring)
        XCTAssertNotEqual(r.location, NSNotFound, "substring not found: \(substring)")
        return r.location + offset
    }

    private func path(_ line: String, at column: Int) -> String? {
        TerminalPathDetect.pathRangeAt(line: line, column: column)?.path
    }

    func testAbsolutePath() {
        let line = "see /Users/x/notes.txt for details"
        XCTAssertEqual(path(line, at: col(line, of: "Users")), "/Users/x/notes.txt")
    }

    func testTildePath() {
        let line = "stored at ~/.config/wave/settings.json now"
        XCTAssertEqual(path(line, at: col(line, of: "settings")), "~/.config/wave/settings.json")
    }

    func testRelativePathWithDotSlash() {
        let line = "edit ./src/main.swift please"
        XCTAssertEqual(path(line, at: col(line, of: "src")), "./src/main.swift")
    }

    func testStripsGrepStyleLineColumnLocator() {
        let line = "Sources/app/foo.swift:42:10: error here"
        XCTAssertEqual(path(line, at: col(line, of: "foo")), "Sources/app/foo.swift")
    }

    func testStripsSurroundingQuotesAndTrailingPunctuation() {
        let line = "opened \"/tmp/a/b.log\"."
        XCTAssertEqual(path(line, at: col(line, of: "tmp")), "/tmp/a/b.log")
    }

    func testPlainWordWithoutSeparatorReturnsNil() {
        let line = "this is just prose without paths"
        XCTAssertNil(path(line, at: col(line, of: "prose")))
    }

    func testClickOnTrimmedLocatorTailReturnsNil() {
        // Clicking the ":42" locator (trimmed away) should not resolve to the path.
        let line = "Sources/app/foo.swift:42 here"
        XCTAssertNil(path(line, at: col(line, of: "42")))
    }
}
