// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveTerminal — filesystem-path autodetection for plain terminal text, the file
// counterpart to TerminalURLDetect. Given a single visual row and the clicked
// column, return the path-like token covering it (or nil). This half is pure +
// Foundation-only and unit-testable: it only finds the token and strips the
// decorations terminals add (surrounding quotes/brackets, a trailing `:line:col`
// locator, sentence punctuation). It deliberately does NOT touch the filesystem —
// the view resolves the token against the pane's CWD and stats it, so existence is
// the caller's concern and this stays deterministic.

import Foundation

/// Detects clickable filesystem paths inside a row of terminal text.
enum TerminalPathDetect {
    /// Trailing characters that are almost never part of a path at the very end of a
    /// token (sentence/wrapping punctuation). Mirrors TerminalURLDetect's set.
    private static let trailingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", ">", "'", "\"",
    ]

    /// Leading wrappers terminals/log formats put around a path token.
    private static let leadingWrappers: Set<Character> = ["'", "\"", "(", "[", "{", "<"]

    /// Return the path token covering `column` in `line`, plus its UTF-16 range (after
    /// trimming wrappers and a `:line[:col]` locator). `column` is a UTF-16 offset.
    /// Returns nil when the token does not look like a path (no `/`, `~`, `./`, `../`).
    static func pathRangeAt(line: String, column: Int) -> (path: String, range: NSRange)? {
        let ns = line as NSString
        guard !line.isEmpty, column >= 0, column < ns.length else { return nil }

        // Expand left/right to the whitespace-delimited token under the column.
        var start = column
        var end = column + 1
        while start > 0, !isSpace(ns.character(at: start - 1)) { start -= 1 }
        while end < ns.length, !isSpace(ns.character(at: end)) { end += 1 }
        guard end > start else { return nil }

        // Trim one layer of leading wrapper(s), tracking how far the token start moved
        // so the returned range still aligns to the visual cells.
        var token = ns.substring(with: NSRange(location: start, length: end - start))
        var leadTrim = 0
        while let first = token.first, leadingWrappers.contains(first) {
            token.removeFirst()
            leadTrim += 1
        }
        token = stripLocator(trimTrailing(token))
        guard !token.isEmpty, looksLikePath(token) else { return nil }

        let loc = start + leadTrim
        let len = (token as NSString).length
        // Guard against the click landing on a trimmed-away tail (e.g. the `:42` locator).
        guard column < loc + len else { return nil }
        return (token, NSRange(location: loc, length: max(1, len)))
    }

    /// A token "looks like a path" when it carries a directory separator or a home/relative
    /// prefix — enough to avoid matching ordinary prose words while accepting the common
    /// shapes (`/abs`, `~/x`, `./x`, `../x`, `dir/file`).
    static func looksLikePath(_ token: String) -> Bool {
        if token.hasPrefix("~") || token.hasPrefix("./") || token.hasPrefix("../") { return true }
        return token.contains("/")
    }

    /// Strip a trailing `:line` or `:line:col` source locator (grep/compiler output),
    /// but only when the suffix is purely numeric so real filenames with colons survive.
    private static func stripLocator(_ token: String) -> String {
        var parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return token }
        while parts.count >= 2, let last = parts.last, !last.isEmpty, last.allSatisfy({ $0.isNumber }) {
            parts.removeLast()
        }
        return parts.joined(separator: ":")
    }

    private static func trimTrailing(_ token: String) -> String {
        var out = token
        while let last = out.last, trailingPunctuation.contains(last) { out.removeLast() }
        return out
    }

    private static func isSpace(_ u: unichar) -> Bool {
        u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D
    }
}
