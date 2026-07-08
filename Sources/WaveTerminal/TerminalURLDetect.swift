// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveTerminal — URL autodetection for plain (non-OSC-8) terminal text.
// Given a single visual row of text and the column the user Cmd-clicked, return
// the URL token covering that column (or nil). This is the pure, Foundation-only
// half of "Cmd-click to open a plain URL": it has no AppKit/libghostty deps so it
// stays deterministic and unit-testable. The view supplies the row text + column
// (read from the libghostty render state) and feeds the result back into the same
// `onOpenWebURL` seam used by OSC-8 hyperlinks.

import Foundation

/// Detects clickable URLs inside a row of terminal text.
///
/// We use `NSDataDetector(.link)` rather than a hand-rolled regex: it is part of
/// Foundation (so still pure + portable), it is battle-tested against the messy
/// reality of URLs, and it already does the normalization we want for free —
/// bare `www.` hosts are promoted to an `http://` URL, and trailing sentence
/// punctuation (the `.` in "see https://x.com.") is excluded from the match. A
/// regex would re-implement all of that (badly) and drift from platform behavior.
enum TerminalURLDetect {
    /// Trailing characters that are almost never part of a URL when they sit at
    /// the very end of a token (sentence/wrapping punctuation). NSDataDetector
    /// already strips these, so this is a defensive second pass for any scheme it
    /// returns with punctuation still attached.
    private static let trailingPunctuation: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", ">", "'", "\"",
    ]

    /// `.link` detector is stateless + thread-safe to reuse, so build it once.
    private static let detector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    /// Return the URL covering `column` in `line`, or nil if the click did not
    /// land on a URL. `column` is a UTF-16 offset into `line` (the same unit
    /// `NSString`/`NSRange` use); for ASCII URLs this equals the character index.
    static func urlAt(line: String, column: Int) -> String? {
        urlRangeAt(line: line, column: column)?.url
    }

    /// Like `urlAt`, but also returns the matched URL's UTF-16 character range in `line`
    /// (trailing sentence/wrapping punctuation excluded, mirroring `urlAt`'s trimming).
    /// The hover-underline path needs the range to map the link back to its cell columns.
    static func urlRangeAt(line: String, column: Int) -> (url: String, range: NSRange)? {
        guard !line.isEmpty, let detector else { return nil }
        let ns = line as NSString
        guard column >= 0, column < ns.length else { return nil }

        let full = NSRange(location: 0, length: ns.length)
        let matches = detector.matches(in: line, options: [], range: full)
        for match in matches where NSLocationInRange(column, match.range) {
            guard let url = match.url?.absoluteString, !url.isEmpty else { continue }
            // Trim trailing punctuation off the VISUAL range too (the matched substring),
            // so the hover underline stops before a sentence-final "." or ")".
            let trimmedLen = (trimTrailing(ns.substring(with: match.range)) as NSString).length
            let range = NSRange(location: match.range.location, length: max(1, trimmedLen))
            return (trimTrailing(url), range)
        }
        return nil
    }

    /// Strip trailing sentence/wrapping punctuation, but keep a closing `)` when
    /// it balances an opening `(` inside the URL (e.g. Wikipedia-style paths) —
    /// the common "don't break balanced parens" rule.
    private static func trimTrailing(_ url: String) -> String {
        var out = url
        while let last = out.last, trailingPunctuation.contains(last) {
            if last == ")" {
                let opens = out.reduce(into: 0) { $0 += ($1 == "(") ? 1 : 0 }
                let closes = out.reduce(into: 0) { $0 += ($1 == ")") ? 1 : 0 }
                if closes <= opens { break }
            }
            out.removeLast()
        }
        return out
    }
}
