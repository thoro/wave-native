// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Packed row model for the virtualized-scrollback history layer. History
// chunks hold tens of thousands of styled rows, so cells are packed into 16
// bytes (codepoint + resolved RGB + style bits) instead of the draw-path's
// String/NSColor snapshot; the terminal view converts visible rows back on
// the fly through a small color cache and draws them via the SAME drawCell
// path as live rows, so history renders pixel-identically.

import Foundation
#if canImport(CGhostty)
import CGhostty
#endif

/// Style bits for a packed cell.
public struct TermCellFlags: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold = TermCellFlags(rawValue: 1 << 0)
    public static let italic = TermCellFlags(rawValue: 1 << 1)
    public static let faint = TermCellFlags(rawValue: 1 << 2)
    public static let inverse = TermCellFlags(rawValue: 1 << 3)
    public static let invisible = TermCellFlags(rawValue: 1 << 4)
    public static let underline = TermCellFlags(rawValue: 1 << 5)
    public static let strikethrough = TermCellFlags(rawValue: 1 << 6)
    public static let overline = TermCellFlags(rawValue: 1 << 7)
    /// fgRGB holds an explicit resolved color (else use the view's default fg).
    public static let hasFg = TermCellFlags(rawValue: 1 << 8)
    /// bgRGB holds an explicit resolved color (else the cell has no bg fill).
    public static let hasBg = TermCellFlags(rawValue: 1 << 9)
}

/// One styled history cell, packed to 16 bytes. `codepoint == 0` is a blank
/// cell; multi-codepoint grapheme clusters spill into the row's side table.
public struct TermPackedCell: Sendable, Equatable {
    public var codepoint: UInt32
    public var fgRGB: UInt32
    public var bgRGB: UInt32
    public var flags: TermCellFlags
    var pad: UInt16 = 0

    public init(codepoint: UInt32 = 0, fgRGB: UInt32 = 0, bgRGB: UInt32 = 0, flags: TermCellFlags = []) {
        self.codepoint = codepoint
        self.fgRGB = fgRGB
        self.bgRGB = bgRGB
        self.flags = flags
    }
}

/// An OSC-8 hyperlink covering a column range of one row.
public struct TermLinkSpan: Sendable, Equatable {
    public var cols: ClosedRange<Int>
    public var uri: String
    public init(cols: ClosedRange<Int>, uri: String) {
        self.cols = cols
        self.uri = uri
    }
}

/// One parsed history row: packed styled cells (trailing blanks trimmed), the
/// flattened text (blank cells contribute a space, matching the live path's
/// `rowLine`), per-column UTF-16 offsets into that text, the soft-wrap flag,
/// and any OSC-8 link spans.
public struct TermHistoryRow: Sendable {
    public var cells: [TermPackedCell]
    public var plain: String
    public var offsets: [Int]
    /// This row soft-wraps into the next (GHOSTTY_ROW_DATA_WRAP). Copy joins
    /// wrapped rows without a newline.
    public var wrapped: Bool
    /// This row is the continuation of a soft-wrapped predecessor
    /// (GHOSTTY_ROW_DATA_WRAP_CONTINUATION) -- i.e. NOT a logical line start.
    public var isContinuation: Bool
    public var graphemes: [UInt16: String]?
    public var links: [TermLinkSpan]?

    public init(cells: [TermPackedCell], plain: String, offsets: [Int], wrapped: Bool,
                isContinuation: Bool = false,
                graphemes: [UInt16: String]? = nil, links: [TermLinkSpan]? = nil) {
        self.cells = cells
        self.plain = plain
        self.offsets = offsets
        self.wrapped = wrapped
        self.isContinuation = isContinuation
        self.graphemes = graphemes
        self.links = links
    }

    /// Cell text for drawing: the grapheme-cluster side table wins, else the
    /// single codepoint, else a space.
    public func text(at col: Int) -> String {
        if let g = graphemes?[UInt16(col)] { return g }
        guard col < cells.count else { return " " }
        let cp = cells[col].codepoint
        guard cp != 0, let u = Unicode.Scalar(cp) else { return " " }
        return String(u)
    }

    /// The link span covering a column, if any.
    public func link(at col: Int) -> TermLinkSpan? {
        links?.first { $0.cols.contains(col) }
    }
}

#if canImport(CGhostty)
enum TermRowExtract {
    static func packRGB(_ c: GhosttyColorRgb) -> UInt32 {
        (UInt32(c.r) << 16) | (UInt32(c.g) << 8) | UInt32(c.b)
    }

    /// Extract one render-state row into the packed model. Reads the exact same
    /// GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_* fields as the live draw path's
    /// `snapshotRow`, so packed history rows carry identical resolved styling.
    /// Must run while the owning terminal is exclusively held.
    static func packRow(cells: GhosttyRenderStateRowCells) -> (cells: [TermPackedCell], plain: String, offsets: [Int], graphemes: [UInt16: String]?) {
        var packed: [TermPackedCell] = []
        var plain = ""
        var offsets: [Int] = []
        var utf16Len = 0
        var graphemes: [UInt16: String]?
        var col = 0
        while ghostty_render_state_row_cells_next(cells) {
            offsets.append(utf16Len)
            var len: UInt32 = 0
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &len)

            var text = ""
            if len > 0 {
                var scalars = [UInt32](repeating: 0, count: Int(len))
                scalars.withUnsafeMutableBufferPointer { buf in
                    _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, buf.baseAddress)
                }
                for v in scalars where v != 0 {
                    if let u = Unicode.Scalar(v) { text.unicodeScalars.append(u) }
                }
            }

            var flags: TermCellFlags = []
            var fgPacked: UInt32 = 0
            var bgPacked: UInt32 = 0
            var fgRgb = GhosttyColorRgb()
            if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fgRgb) == GHOSTTY_SUCCESS {
                flags.insert(.hasFg)
                fgPacked = packRGB(fgRgb)
            }
            var bgRgb = GhosttyColorRgb()
            if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bgRgb) == GHOSTTY_SUCCESS {
                flags.insert(.hasBg)
                bgPacked = packRGB(bgRgb)
            }

            var style = GhosttyStyle()
            style.size = MemoryLayout<GhosttyStyle>.stride
            _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
            if style.bold { flags.insert(.bold) }
            if style.italic { flags.insert(.italic) }
            if style.faint { flags.insert(.faint) }
            if style.inverse { flags.insert(.inverse) }
            if style.invisible { flags.insert(.invisible) }
            if style.underline != 0 { flags.insert(.underline) }
            if style.strikethrough { flags.insert(.strikethrough) }
            if style.overline { flags.insert(.overline) }

            var codepoint: UInt32 = 0
            if let first = text.unicodeScalars.first {
                codepoint = first.value
                if text.unicodeScalars.count > 1 {
                    if graphemes == nil { graphemes = [:] }
                    graphemes?[UInt16(col)] = text
                }
                plain += text
                utf16Len += text.utf16.count
            } else {
                plain.append(" ")
                utf16Len += 1
            }
            packed.append(TermPackedCell(codepoint: codepoint, fgRGB: fgPacked, bgRGB: bgPacked, flags: flags))
            col += 1
        }
        return (packed, plain, offsets, graphemes)
    }

    /// Trim trailing fully-blank unstyled cells (memory: most rows are short).
    static func trimTrailing(_ cells: [TermPackedCell]) -> [TermPackedCell] {
        var end = cells.count
        while end > 0 {
            let c = cells[end - 1]
            if c.codepoint != 0 || !c.flags.isDisjoint(with: [.hasBg, .underline, .strikethrough, .overline, .inverse]) {
                break
            }
            end -= 1
        }
        return Array(cells[0..<end])
    }
}
#endif
