// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Parses raw term-file bytes into styled history rows at a given width using a
// throwaway libghostty-vt terminal, off the main thread. The scratch terminal
// runs the SAME VT engine over the same bytes as the live sink, so re-derived
// rows match what the sink produced; per-row extraction goes through
// TermRowExtract, the same field reads the live draw path uses.

import Foundation
#if canImport(CGhostty)
import CGhostty
#endif

#if canImport(CGhostty)

/// Off-main scratch-VT parser. One serial queue per instance keeps libghostty
/// calls confined; each parse owns a fresh terminal so it never interacts with
/// the live sink's lock.
final class HistoryChunkParser {
    private let queue = DispatchQueue(label: "wave.terminal.history.parse", qos: .userInitiated)

    /// Rows per viewport page while extracting; also the scratch terminal height.
    private static let pageRows = 50
    /// Scrollback cap for the scratch terminal. max_scrollback is a page-memory
    /// BYTE budget (not lines -- see GhosttySink.scrollbackBytes); pages
    /// allocate on demand, so a large cap costs nothing until rows exist. 256MB
    /// covers a 10k-line chunk at any sane width with wide margin.
    private static let scratchScrollback = 256 * 1024 * 1024

    struct ParseResult {
        var rows: [TermHistoryRow]
        /// Index into `rows` where each RAW line (one per \n byte in the fed
        /// data, matching the backend's filestore line numbering) starts.
        /// Recorded from the cursor position while feeding — NOT derived from
        /// wrap-continuation flags, which drift from raw-\n space whenever a
        /// program starts a new visual row without emitting \n (readline
        /// hard-wraps, NEL/CNL, cursor motion). Used to map logical lines <->
        /// rows.
        var lineStartRows: [Int]
    }

    /// Parse `bytes` at `cols` wide and deliver styled rows on `completion`
    /// (invoked on the parser queue -- caller hops to main).
    ///
    /// - Parameters:
    ///   - warmupLines: leading logical lines that are parser-state warm-up
    ///     only (SGR/charset context) and are dropped from the result.
    ///   - palette: the live terminal's current 256-color palette so indexed
    ///     colors resolve to identical RGB values.
    ///   - isCancelled: checked between pages; a cancelled parse delivers nil.
    func parse(
        bytes: Data,
        cols: Int,
        warmupLines: Int,
        palette: [GhosttyColorRgb]?,
        isCancelled: @escaping () -> Bool,
        completion: @escaping (ParseResult?) -> Void
    ) {
        queue.async {
            completion(Self.parseSync(
                bytes: bytes, cols: cols, warmupLines: warmupLines,
                palette: palette, isCancelled: isCancelled))
        }
    }

    static func parseSync(
        bytes: Data,
        cols: Int,
        warmupLines: Int,
        palette: [GhosttyColorRgb]?,
        isCancelled: @escaping () -> Bool
    ) -> ParseResult? {
        var opts = GhosttyTerminalOptions()
        opts.cols = UInt16(max(2, min(cols, Int(UInt16.max))))
        opts.rows = UInt16(pageRows)
        opts.max_scrollback = scratchScrollback
        var t: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &t, opts) == GHOSTTY_SUCCESS, let terminal = t else { return nil }
        defer { ghostty_terminal_free(terminal) }
        // No write-pty/bell/pwd callbacks: queries inside history are silently
        // dropped, exactly like the live sink's replaying mode.

        if let palette, palette.count == 256 {
            palette.withUnsafeBufferPointer { buf in
                _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, buf.baseAddress)
            }
        }

        // Feed line by line (split at \n) and record the cursor's absolute row
        // after each newline: rawStarts[i] = row where raw line i begins. The
        // scratch cap is far above any chunk, so no pruning ever shifts these.
        // Values are clamped ascending because cursor motion inside TUI redraws
        // can move upward; those lines are fuzzy either way.
        var rawStarts: [Int] = [0]
        var fed = 0
        var sinceCancelCheck = 0
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while fed < bytes.count {
                if sinceCancelCheck > 256 * 1024 {
                    sinceCancelCheck = 0
                    if isCancelled() { return }
                }
                let remaining = bytes.count - fed
                let cur = base.advanced(by: fed)
                let nl = memchr(cur, 0x0A, remaining)
                let n = nl.map { UnsafeRawPointer($0) - cur + 1 } ?? remaining
                ghostty_terminal_vt_write(terminal, cur.assumingMemoryBound(to: UInt8.self), n)
                fed += n
                sinceCancelCheck += n
                if nl != nil {
                    rawStarts.append(max(rawStarts[rawStarts.count - 1], cursorAbsoluteRow(terminal)))
                }
            }
        }
        if isCancelled() { return nil }
        // One entry per raw line actually present: data ending in \n has no
        // trailing partial line, so the last recorded start begins nothing.
        if bytes.isEmpty || bytes.last == 0x0A {
            rawStarts.removeLast()
        }

        var state: GhosttyRenderState?
        var it: GhosttyRenderStateRowIterator?
        var cells: GhosttyRenderStateRowCells?
        guard ghostty_render_state_new(nil, &state) == GHOSTTY_SUCCESS, let state,
              ghostty_render_state_row_iterator_new(nil, &it) == GHOSTTY_SUCCESS, var it,
              ghostty_render_state_row_cells_new(nil, &cells) == GHOSTTY_SUCCESS, var cells
        else { return nil }
        defer {
            ghostty_render_state_row_cells_free(cells)
            ghostty_render_state_row_iterator_free(it)
            ghostty_render_state_free(state)
        }

        var total = 0
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total)

        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_TOP
        ghostty_terminal_scroll_viewport(terminal, behavior)

        var rows: [TermHistoryRow] = []
        rows.reserveCapacity(total)
        while rows.count < total {
            if isCancelled() { return nil }
            var sb = GhosttyTerminalScrollbar()
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb) == GHOSTTY_SUCCESS else { break }
            // On the clamped final page the viewport overlaps rows we already
            // captured; skip those.
            let skip = rows.count - Int(sb.offset)
            guard ghostty_render_state_update(state, terminal) == GHOSTTY_SUCCESS else { break }
            ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &it)
            var pageRow = 0
            while ghostty_render_state_row_iterator_next(it) {
                defer { pageRow += 1 }
                if pageRow < skip { continue }
                if rows.count >= total { break }
                rows.append(extractRow(terminal, it: it, cells: &cells, pageRow: pageRow))
            }
            if Int(sb.offset) + Int(sb.len) >= total { break }
            var d = GhosttyTerminalScrollViewport()
            d.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
            d.value.delta = Int(sb.len)
            ghostty_terminal_scroll_viewport(terminal, d)
        }

        // Trailing blank rows are the scratch terminal's empty active area.
        while let last = rows.last, last.plain.allSatisfy({ $0 == " " }), last.cells.isEmpty {
            rows.removeLast()
        }

        // Drop warm-up rows by RAW line boundary (the caller fetched exactly
        // `warmupLines` extra raw lines in front of the chunk).
        if warmupLines > 0 {
            let dropCount = min(warmupLines < rawStarts.count ? rawStarts[warmupLines] : rows.count, rows.count)
            rows.removeFirst(dropCount)
            rawStarts = warmupLines < rawStarts.count
                ? rawStarts[warmupLines...].map { $0 - dropCount } : []
        }

        // Entries can point past the end after trailing-blank trimming (a raw
        // line whose rows were all blank); clamp so row lookups stay in range.
        let lineStartRows = rawStarts.map { min(max(0, $0), rows.count) }
        return ParseResult(rows: rows, lineStartRows: lineStartRows)
    }

    /// Absolute row (scrollback rows above the active area + active-area
    /// cursor y) of the scratch terminal's cursor, in the same row space the
    /// page-by-page extraction below indexes.
    private static func cursorAbsoluteRow(_ terminal: GhosttyTerminal) -> Int {
        var scrollback = 0
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &scrollback)
        var y: UInt16 = 0
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
        return scrollback + Int(y)
    }

    private static func extractRow(
        _ terminal: GhosttyTerminal,
        it: GhosttyRenderStateRowIterator,
        cells: inout GhosttyRenderStateRowCells,
        pageRow: Int
    ) -> TermHistoryRow {
        var wrapped = false
        var isContinuation = false
        var hasHyperlink = false
        // Out-param must be a NON-optional GhosttyRow: the C side writes only the
        // 8-byte payload, so an Optional's tag byte stays "nil" and `if let`
        // silently drops the row (all flags read as false).
        var raw: GhosttyRow = 0
        if ghostty_render_state_row_get(it, GHOSTTY_RENDER_STATE_ROW_DATA_RAW, &raw) == GHOSTTY_SUCCESS {
            _ = ghostty_row_get(raw, GHOSTTY_ROW_DATA_WRAP, &wrapped)
            _ = ghostty_row_get(raw, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &isContinuation)
            _ = ghostty_row_get(raw, GHOSTTY_ROW_DATA_HYPERLINK, &hasHyperlink)
        }

        var packed: [TermPackedCell] = []
        var plain = ""
        var offsets: [Int] = []
        var graphemes: [UInt16: String]?
        if ghostty_render_state_row_get(it, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells) == GHOSTTY_SUCCESS {
            (packed, plain, offsets, graphemes) = TermRowExtract.packRow(cells: cells)
        }

        var links: [TermLinkSpan]?
        if hasHyperlink {
            links = extractLinks(terminal, pageRow: pageRow, cols: packed.count)
        }
        return TermHistoryRow(
            cells: TermRowExtract.trimTrailing(packed),
            plain: plain, offsets: offsets, wrapped: wrapped,
            isContinuation: isContinuation,
            graphemes: graphemes, links: links)
    }

    /// Per-cell OSC-8 URI sweep for a viewport row (only runs on rows whose
    /// hyperlink flag is set -- rare). Merges adjacent same-URI cells into spans.
    private static func extractLinks(_ terminal: GhosttyTerminal, pageRow: Int, cols: Int) -> [TermLinkSpan]? {
        var spans: [TermLinkSpan] = []
        var currentURI: String?
        var spanStart = 0
        for x in 0..<cols {
            let uri = hyperlinkURI(terminal, col: x, viewportRow: pageRow)
            if uri != currentURI {
                if let u = currentURI {
                    spans.append(TermLinkSpan(cols: spanStart...(x - 1), uri: u))
                }
                currentURI = uri
                spanStart = x
            }
        }
        if let u = currentURI {
            spans.append(TermLinkSpan(cols: spanStart...(cols - 1), uri: u))
        }
        return spans.isEmpty ? nil : spans
    }

    private static func hyperlinkURI(_ terminal: GhosttyTerminal, col: Int, viewportRow: Int) -> String? {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(max(0, col)), y: UInt32(max(0, viewportRow)))
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.stride
        guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { return nil }
        var needed = 0
        _ = withUnsafePointer(to: &ref) { ghostty_grid_ref_hyperlink_uri($0, nil, 0, &needed) }
        guard needed > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: needed)
        var written = 0
        let rc = withUnsafePointer(to: &ref) { refPtr in
            buf.withUnsafeMutableBufferPointer {
                ghostty_grid_ref_hyperlink_uri(refPtr, $0.baseAddress, $0.count, &written)
            }
        }
        guard rc == GHOSTTY_SUCCESS, written > 0 else { return nil }
        return String(decoding: buf.prefix(written), as: UTF8.self)
    }
}

#endif
