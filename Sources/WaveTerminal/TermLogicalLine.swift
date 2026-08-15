// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveTerminal — logical-line assembly for URL/path autodetection across soft
// wraps. A long URL printed in a narrow pane soft-wraps over several visual
// rows; detecting per visual row then yields a truncated URL (and Cmd-click
// opens the wrong page). This joins the soft-wrap run around an anchor row into
// one logical line, translates the clicked cell into an offset on that line so
// the pure detectors see the full token, and maps a matched UTF-16 range back
// to per-row column spans for the hover underline. Foundation-only so it stays
// deterministic and unit-testable.

import Foundation

/// One visual row's contribution to a logical line: its flattened text and
/// per-column UTF-16 offset table (`rowLine` / `TermHistoryRow` semantics),
/// plus whether it soft-wraps into the following row.
struct TermRowSlice {
    let row: Int
    let text: String
    let offsets: [Int]
    let wrapped: Bool
}

/// A soft-wrap run of visual rows joined into one string, with enough
/// bookkeeping to map cells to string offsets and back.
struct TermLogicalLine {
    /// Rows joined above/below the anchor are capped here: no real URL spans
    /// more, and it bounds the per-hover render-state work.
    static let MaxJoinRows = 16

    let text: String
    private let slices: [(row: Int, base: Int, utf16Len: Int, offsets: [Int])]

    /// Assemble the soft-wrap run containing `rows[index]`. `rows` must be
    /// visually contiguous (each element the row directly below its
    /// predecessor). Rows are joined without a separator, mirroring how the
    /// terminal wraps: a wrapped row is full-width, so the token continues
    /// seamlessly on the next row.
    static func around(rows: [TermRowSlice], index: Int) -> TermLogicalLine? {
        guard index >= 0, index < rows.count else { return nil }
        var start = index
        while start > 0, index - start < MaxJoinRows, rows[start - 1].wrapped { start -= 1 }
        var end = index
        while end < rows.count - 1, end - index < MaxJoinRows, rows[end].wrapped { end += 1 }
        return join(rows[start...end])
    }

    /// Join an exact row range (already known to be one soft-wrap run) without
    /// the anchor-relative cap `around` applies.
    static func join(_ rows: ArraySlice<TermRowSlice>) -> TermLogicalLine? {
        guard !rows.isEmpty else { return nil }
        var text = ""
        var base = 0
        var slices: [(row: Int, base: Int, utf16Len: Int, offsets: [Int])] = []
        for slice in rows {
            let len = (slice.text as NSString).length
            slices.append((slice.row, base, len, slice.offsets))
            text += slice.text
            base += len
        }
        return TermLogicalLine(text: text, slices: slices)
    }

    /// The n-th (0-based, top-down) soft-wrap run in `rows` whose joined text
    /// contains `needle` (case-insensitive), as the (row, col) where the match
    /// starts. Runs are joined before searching so a needle spanning a wrap
    /// boundary still counts, and each run counts ONCE however many times the
    /// needle appears in it — mirroring the backend scrollback search's
    /// one-match-per-line semantics so ordinals line up on both sides.
    static func nthOccurrence(rows: [TermRowSlice], needle: String, n: Int) -> (row: Int, col: Int)? {
        guard !needle.isEmpty, n >= 0 else { return nil }
        var remaining = n
        var i = 0
        while i < rows.count {
            var j = i
            while j < rows.count - 1, rows[j].wrapped { j += 1 }
            defer { i = j + 1 }
            guard let line = join(rows[i...j]),
                  let r = line.text.range(of: needle, options: [.caseInsensitive]) else { continue }
            if remaining > 0 {
                remaining -= 1
                continue
            }
            guard let seg = line.segments(in: NSRange(r, in: line.text)).first else { return nil }
            return (seg.row, seg.cols.lowerBound)
        }
        return nil
    }

    /// UTF-16 offset into `text` of the cell at (row, col), or nil when the row
    /// is not part of this line or the column is past the row's content.
    func utf16Offset(row: Int, col: Int) -> Int? {
        guard let s = slices.first(where: { $0.row == row }),
              col >= 0, col < s.offsets.count else { return nil }
        return s.base + s.offsets[col]
    }

    /// Map a UTF-16 range in `text` back to the per-row inclusive column spans
    /// it covers (hover-underline geometry).
    func segments(in range: NSRange) -> [(row: Int, cols: ClosedRange<Int>)] {
        var out: [(row: Int, cols: ClosedRange<Int>)] = []
        for s in slices {
            let lower = max(range.location, s.base)
            let upper = min(range.location + range.length, s.base + s.utf16Len)
            guard lower < upper else { continue }
            if let cols = Self.columnRange(offsets: s.offsets, utf16Lower: lower - s.base, utf16Upper: upper - s.base) {
                out.append((s.row, cols))
            }
        }
        return out
    }

    /// Map a UTF-16 character range in a row's flattened string back to the
    /// inclusive viewport column range it covers, via the per-column offset
    /// table from `rowLine`. A column is included when its start offset lies
    /// within [lower, upper).
    static func columnRange(offsets: [Int], utf16Lower: Int, utf16Upper: Int) -> ClosedRange<Int>? {
        var lo = -1
        var hi = -1
        for (col, off) in offsets.enumerated() where off >= utf16Lower && off < utf16Upper {
            if lo < 0 { lo = col }
            hi = col
        }
        guard lo >= 0 else { return nil }
        return lo...hi
    }
}
