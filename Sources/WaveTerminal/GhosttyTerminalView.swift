// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveTerminal — the native terminal content view (PROTOCOL.md §4 render half).
// It renders a `GhosttySink`'s libghostty-vt grid with CoreText and encodes
// keyboard input to the pty. This is the native replacement for Electron's
// xterm.js canvas: libghostty-vt owns VT parsing + grid/scrollback state; this
// view only reads the render-state snapshot and draws it, and translates AppKit
// key events into the byte stream the pty expects (routed via the controller).
//
// Scope of this first cut (documented in docs/INTEGRATION.md): solid-grid render
// of glyphs + per-cell fg/bg + block/bar/underline cursor; key input for text,
// control combos, Alt-as-Meta, and navigation keys; mouse selection (drag +
// Cmd-C copy) and mouse reporting (when the app enables tracking). Not yet:
// ligatures and the Kitty keyboard protocol (libghostty-vt's key encoder).

#if canImport(CGhostty) && canImport(AppKit)
import AppKit
import CGhostty
import WaveCore

/// Renders one terminal block and feeds keystrokes back to its controller.
public final class GhosttyTerminalView: NSView {
    /// Raised on Cmd-D / Cmd-Shift-D to split the tab. Carries (this block's id,
    /// direction "horizontal"|"vertical"). Wired by the composition root via BlockEnv.
    public var onSplit: ((_ blockId: String, _ direction: String) -> Void)?

    /// Raised on Cmd-M to toggle magnify on this pane. Carries this block's id.
    /// Wired by the composition root via BlockEnv.
    public var onMagnify: ((_ blockId: String) -> Void)?

    /// Raised by the "Close" context-menu item to close this pane. Carries this
    /// block's id. Wired by the composition root via BlockEnv (`env.onClose`).
    public var onClose: ((_ blockId: String) -> Void)?

    /// Raised to open an OSC-8 terminal hyperlink as a web pane (Cmd-click or the
    /// "Open Link" menu item). Carries (this block's id, the URI). Wired by the
    /// composition root via BlockEnv (`env.onOpenWebURL`).
    public var onOpenWebURL: ((_ blockId: String, _ url: String) -> Void)?

    /// Raised on a click to focus this pane (move the green border + keyboard focus).
    /// Wired by the composition root via `BlockEnv.onRequestFocus`.
    public var onFocusRequest: (() -> Void)?

    /// Raised after the view (re)enters a window, so the composition root can re-derive the
    /// background alpha from the new window's translucency (a pane split into an already
    /// transparent window must come up translucent without waiting for a config reload).
    public var onDidMoveToWindow: (() -> Void)?

    /// Whether this view holds keyboard focus — drives the cursor style (filled block
    /// when focused, hollow outline when not, matching standard terminals).
    private var hasKeyFocus = false

    /// Set to true by `insertText` when the macOS text-input system commits a glyph for
    /// the key currently being processed in `keyDown`. It lets `keyDown` tell "the IME
    /// already sent the composed character" apart from "the IME declined, fall back to the
    /// direct encoder" — without this, plain ASCII would be lost when no input method runs.
    private var pendingInputHandled = false

    /// The current uncommitted preedit (dead-key / IME composition in progress), tracked
    /// purely so it is NOT forwarded to the pty until it commits via `insertText`. Inline
    /// preedit display in the grid is out of scope; this is logical state only.
    private var markedText = ""

    /// Observers for the owning window's key/non-key transitions. The cursor must go
    /// hollow when the window stops being key even though this view keeps firstResponder
    /// (resignFirstResponder does NOT fire on a window deactivation), so we repaint on
    /// the window notifications. Re-bound in `viewDidMoveToWindow`, torn down in `deinit`.
    private var windowKeyObservers: [NSObjectProtocol] = []

    /// The hyperlink URI under the most recent right-click, captured in `menu(for:)`
    /// so the "Open Link" items act on the clicked cell.
    private var menuHyperlinkURI: String?

    private let controller: TerminalController
    private let sink: GhosttySink
    // Font + cell metrics are rebuilt in place when `term:fontsize`/`term:fontfamily`
    // change (live re-render via `applyAppearance`), so they are vars, not lets.
    private var font: NSFont
    private var fontBold: NSFont
    private var fontItalic: NSFont
    private var fontBoldItalic: NSFont
    private var cellSize: CGSize

    /// Terminal background alpha (`term:transparency`: 1 = opaque … 0 = clear). The
    /// default-bg fill + the view layer honour it so the window/desktop shows through.
    private var backgroundAlpha: CGFloat = 1

    /// Theme selection-wash override (`termtheme.selectionBackground`); nil keeps the
    /// built-in translucent white wash.
    private var selectionColorOverride: NSColor?

    /// Inset of the terminal grid from the view edges (Wave's `.term` padding,
    /// `frontend/app/view/term/term.scss:25` — 4px vertical, 10px horizontal).
    private let padH: CGFloat = 10
    private let padV: CGFloat = 4

    // Reused libghostty-vt render-state handles (render.h: create once, update
    // per frame). All access is under `sink.withTerminal` (exclusive terminal).
    private var renderState: GhosttyRenderState?
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var rowCells: GhosttyRenderStateRowCells?

    private var lastCols = 0
    private var lastRows = 0

    // Mouse reporting (mouse/encoder.h): created once, reused per event. Encodes
    // press/release/motion/scroll to pty bytes when the app enables tracking.
    private var mouseEncoder: GhosttyMouseEncoder?
    private var mouseEvent: GhosttyMouseEvent?
    private var mouseButtonDown = false

    // Local drag-selection state (used only when mouse tracking is OFF). The anchor is
    // held in ABSOLUTE screen coordinates (scrollback-inclusive), NOT viewport cells, so
    // it survives the viewport scrolling mid-drag — the whole point of being able to drag
    // (or wheel) up into history while selecting. Storing a viewport cell made the anchor
    // drift the moment the viewport moved, which broke multi-line selection across
    // scrollback. Untracked refs are invalidated by any mutation, so both endpoints are
    // re-resolved to fresh refs inside one lock each tick.
    private var selectionAnchorScreen: (col: Int, row: Int)?
    private var dragMovedSelection = false
    /// A multi-click gesture claimed locally while the app has mouse tracking on:
    /// its drag/up must not be forwarded to the app.
    private var trackingLocalGesture = false

    /// Drives continuous auto-scroll while a selection drag is held past the top/bottom
    /// edge (so the user can extend the selection into off-screen history). Carries the
    /// last drag event so each timer tick can re-resolve the live pointer cell.
    private var autoScrollTimer: Timer?
    private var lastDragEvent: NSEvent?

    /// Inclusive viewport-column range of a link (OSC-8 or autodetected URL) under the
    /// pointer while Cmd is held — drives the hover underline + the pointing-hand cursor.
    private struct HoverLink { let row: Int; let cols: ClosedRange<Int> }

    /// The link currently Cmd-hovered, if any. nil clears the underline + cursor shape.
    private var hoverLink: HoverLink?

    /// Last viewport cell the pointer hovered, so `flagsChanged` (Cmd press/release) can
    /// re-evaluate the link without a fresh mouse event. Updated only when the cell changes
    /// (the hover recompute is throttled to actual cell transitions, not sub-pixel motion).
    private var hoverCell: (col: Int, row: Int)?

    /// Tracking area that delivers `mouseMoved` for the Cmd-hover link detection. Rebuilt
    /// in `updateTrackingAreas`; `.inVisibleRect` keeps it sized to the view automatically.
    private var hoverTrackingArea: NSTrackingArea?

    // Cursor blink (render.h CURSOR_BLINKING): a ~0.53s on/off toggle while the focused
    // pane's TUI requests a blinking cursor. The timer runs ONLY while a blink is actually
    // wanted (steady cursors cost nothing), and a hidden phase suppresses the cursor cell
    // without touching the underlying glyph.
    private var cursorBlinkTimer: Timer?
    private var cursorBlinkOn = true

    // MARK: virtualized-history state

    /// The paged on-disk history layer stitched above the live sink.
    let history = TerminalHistoryModel()

    /// Rows scrolled ABOVE the live sink's top. 0 = pure live mode (all existing
    /// behavior untouched). While > 0 the sink viewport is pinned to its top and
    /// the drawn grid is [history rows][sink rows].
    private var historyScrollRows = 0

    /// Stable scroll anchor across estimate->exact row-count changes: the
    /// (chunk, rowInChunk) of the top visible history row.
    private var historyTopAnchor: (chunk: Int, row: Int)?

    /// Find-match wash in the history layer (global history row + columns).
    private var historyHighlight: (rowIndex: Int, cols: Range<Int>)?

    /// A seam re-anchor is running; entry into history waits for it.
    private var reanchorInFlight = false

    /// Throttle for the frozen-seam prune probe (500ms between signature reads).
    private var lastSeamProbe = Date.distantPast

    /// Unified selection spanning history + sink rows (nil = native selection
    /// or none). Activated by drags that start on / cross into history rows.
    private var virtualSelection: VirtualSelection? {
        didSet { if virtualSelection == nil { fullBufferSelected = false } }
    }

    /// Cmd-A with paged history: the ENTIRE on-disk buffer is selected; Copy
    /// fetches the server-side ANSI-stripped text instead of assembling rows.
    private var fullBufferSelected = false

    /// Multi-click drag granularity: double-click drags extend by words,
    /// triple-click drags by whole logical lines (standard terminal behavior).
    enum SelectionGranularity { case char, word, line }
    private var selectionGranularity: SelectionGranularity = .char
    /// The word/line range selected at multi-click time; drags select the
    /// UNION of this range and the pointer's range at the same granularity.
    private var granularityAnchorRange: (start: UnifiedPos, end: UnifiedPos)?

    /// Wheel ticks that arrived while the seam re-anchor was in flight; applied
    /// once it lands so rapid scrolling across the seam loses no distance.
    private var pendingEnterRows = 0

    /// packed RGB -> NSColor cache for history-row drawing.
    private var packedColorCache: [UInt32: NSColor] = [:]

    // MARK: find bar + line-space scrollbar state

    private var findBar: TerminalFindBarView?
    private var findDebounce: Task<Void, Never>?
    /// The in-flight match jump; superseded (cancelled) by every new jump so
    /// rapid next/next/next cannot land out of order after slow chunk loads.
    private var jumpTask: Task<Void, Never>?
    private var searchMatches: [TermSearchMatch] = []
    private var searchIndex = 0
    private var searchTruncated = false
    /// Total flushed logical lines reported by the last search (scrollbar domain).
    private var searchTotalLines: Int64 = 0

    /// The overlay scrollbar shows while scrolling (1s fade) and always while
    /// the find bar has results.
    private var scrollbarActiveUntil = Date.distantPast
    private var scrollbarFadeTimer: Timer?
    private var scrollbarDragging = false
    private static let scrollbarWidth: CGFloat = 10

    /// A position in the stitched history+live row space. Any history position
    /// orders before any sink position; history orders by (chunk, row, col),
    /// sink by SCREEN (row, col).
    enum UnifiedPos: Comparable {
        case history(chunk: Int, row: Int, col: Int)
        case sink(screenRow: Int, col: Int)

        static func < (a: UnifiedPos, b: UnifiedPos) -> Bool {
            switch (a, b) {
            case let (.history(c1, r1, x1), .history(c2, r2, x2)):
                return (c1, r1, x1) < (c2, r2, x2)
            case (.history, .sink):
                return true
            case (.sink, .history):
                return false
            case let (.sink(r1, x1), .sink(r2, x2)):
                return (r1, x1) < (r2, x2)
            }
        }
    }

    struct VirtualSelection {
        var anchor: UnifiedPos
        var head: UnifiedPos
        var ordered: (start: UnifiedPos, end: UnifiedPos) {
            anchor <= head ? (anchor, head) : (head, anchor)
        }
    }

    /// Translucent selection wash drawn under the glyph (Wave parity ≈ white/22%).
    private static let selectionColor = NSColor(white: 1, alpha: 0.22)

    /// - Parameter font: the terminal font (Hack 12, STYLE §2 — passed in by the
    ///   composition root so WaveTerminal need not depend on the chrome's Theme).
    public init(controller: TerminalController, sink: GhosttySink, font: NSFont) {
        self.controller = controller
        self.sink = sink
        self.font = font
        let fm = NSFontManager.shared
        self.fontBold = fm.convert(font, toHaveTrait: .boldFontMask)
        self.fontItalic = fm.convert(font, toHaveTrait: .italicFontMask)
        self.fontBoldItalic = fm.convert(fm.convert(font, toHaveTrait: .boldFontMask), toHaveTrait: .italicFontMask)
        self.cellSize = GhosttyTerminalView.measureCell(font: font)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        var st: GhosttyRenderState?
        _ = ghostty_render_state_new(nil, &st)
        renderState = st
        var it: GhosttyRenderStateRowIterator?
        _ = ghostty_render_state_row_iterator_new(nil, &it)
        rowIterator = it
        var cells: GhosttyRenderStateRowCells?
        _ = ghostty_render_state_row_cells_new(nil, &cells)
        rowCells = cells

        var enc: GhosttyMouseEncoder?
        _ = ghostty_mouse_encoder_new(nil, &enc)
        mouseEncoder = enc
        var mev: GhosttyMouseEvent?
        _ = ghostty_mouse_event_new(nil, &mev)
        mouseEvent = mev

        sink.setCellPixelSize(width: Int(cellSize.width.rounded()), height: Int(cellSize.height.rounded()))
        sink.onRender = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.needsDisplay = true
                self.probeSeamIfFrozen()
            }
        }

        history.attach(controller: controller)
        history.paletteProvider = { [weak sink] in sink?.snapshotPalette() }
        history.onRowsChanged = { [weak self] in self?.historyRowsChanged() }
        controller.onHistoryAnchorChanged = { [weak self] anchor in
            guard let self else { return }
            self.history.setAnchor(anchor, cols: self.lastCols > 0 ? self.lastCols : 80)
            self.historyScrollRows = 0
            self.historyTopAnchor = nil
            self.historyHighlight = nil
            self.virtualSelection = nil
            self.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        cursorBlinkTimer?.invalidate()
        for token in windowKeyObservers { NotificationCenter.default.removeObserver(token) }
        if let mouseEvent { ghostty_mouse_event_free(mouseEvent) }
        if let mouseEncoder { ghostty_mouse_encoder_free(mouseEncoder) }
        if let rowCells { ghostty_render_state_row_cells_free(rowCells) }
        if let rowIterator { ghostty_render_state_row_iterator_free(rowIterator) }
        if let renderState { ghostty_render_state_free(renderState) }
    }

    public override var isFlipped: Bool { true }
    // A transparent terminal (`term:transparency` > 0) must report non-opaque so AppKit
    // composites it over the window/blur behind it.
    public override var isOpaque: Bool { backgroundAlpha >= 1 }

    // MARK: - Live appearance (term:fontsize / term:fontfamily / term:transparency)

    /// Rebuild the font + cell metrics and apply the background alpha in place, then
    /// re-derive cols/rows and redraw. Called by the composition root from the
    /// config-reload watch so an open terminal re-renders without a remount. Runs on the
    /// main thread; the libghostty calls it makes (`setCellPixelSize`, `controller.resize`)
    /// take the sink lock but are NOT on the controller's feed stack, so they cannot
    /// re-enter it (the terminal-query freeze fix is preserved).
    public func applyAppearance(font: NSFont, backgroundAlpha: CGFloat) {
        let clamped = max(0, min(1, backgroundAlpha))
        // No-op when nothing changed: this is re-applied to EVERY terminal on
        // config/appearance pushes, and the full path (font cache rebuild +
        // grid recompute + resize + history reset) is far too heavy to run
        // across ~100 shells on every tab switch.
        if hasAppliedAppearance, self.font.isEqual(font), clamped == self.backgroundAlpha {
            return
        }
        hasAppliedAppearance = true
        rebuildFonts(font)
        self.backgroundAlpha = clamped
        layer?.backgroundColor = NSColor.black.withAlphaComponent(self.backgroundAlpha).cgColor
        sink.setCellPixelSize(width: Int(cellSize.width.rounded()), height: Int(cellSize.height.rounded()))
        // Force a grid recompute even when the view bounds are unchanged (only the cell
        // metrics moved), so libghostty's cols/rows track the new font. Skip the resize
        // until the view is laid out (zero bounds at creation) — `setFrameSize` /
        // `viewDidMoveToWindow` recompute once real bounds arrive.
        lastCols = 0
        lastRows = 0
        if bounds.width > 0, bounds.height > 0 { updateTerminalSize() }
        needsDisplay = true
    }

    /// Apply a resolved terminal colour palette (`term:theme`). Pushes the 16 ANSI
    /// colours + default fg/bg/cursor into libghostty (`GHOSTTY_TERMINAL_OPT_COLOR_*`),
    /// so the renderer's resolved per-cell colours pick the theme up automatically; the
    /// selection wash is overridden view-side. An empty palette resets to the built-in
    /// libghostty colours. Main-thread only; not on the feed stack.
    public func applyTheme(_ palette: TerminalColorPalette) {
        if palette == lastAppliedPalette { return }
        lastAppliedPalette = palette
        selectionColorOverride = palette.selection.map(GhosttyTerminalView.nsColor)
        sink.applyPalette(
            ansi: palette.ansi,
            foreground: palette.foreground,
            background: palette.background,
            cursor: palette.cursor)
        needsDisplay = true
    }

    private var lastAppliedPalette: TerminalColorPalette?
    private var hasAppliedAppearance = false

    private func rebuildFonts(_ base: NSFont) {
        font = base
        let fm = NSFontManager.shared
        fontBold = fm.convert(base, toHaveTrait: .boldFontMask)
        fontItalic = fm.convert(base, toHaveTrait: .italicFontMask)
        fontBoldItalic = fm.convert(fm.convert(base, toHaveTrait: .boldFontMask), toHaveTrait: .italicFontMask)
        cellSize = GhosttyTerminalView.measureCell(font: base)
    }

    // MARK: - Sizing (PROTOCOL §4 resize)

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Coalesce the grid/pty resize. A split/close animation ticks the MODEL frame every
        // animation step, and forwarding each tick to the pty makes the shell reprint its
        // prompt per SIGWINCH — a wall of duplicated prompt lines and transiently mis-wrapped
        // text for the intermediate widths. The first REAL size still applies immediately
        // (it gates the backfill replay width, TerminalController.mount).
        if lastCols == 0, lastRows == 0 {
            updateTerminalSize()
            return
        }
        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateTerminalSize() }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Trailing debounce for `updateTerminalSize` (see `setFrameSize`).
    private var resizeDebounce: DispatchWorkItem?

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowKeyState()
        guard window != nil else { return }
        onDidMoveToWindow?()
        updateTerminalSize()
        window?.makeFirstResponder(self)
    }

    /// (Re)bind the key/resign-key observers to the current window so the cursor
    /// repaints (filled ↔ hollow) when the window's key state flips. A background
    /// window's focused terminal must show a hollow cursor even though it still holds
    /// firstResponder, which only these window-level notifications can detect.
    private func observeWindowKeyState() {
        for token in windowKeyObservers { NotificationCenter.default.removeObserver(token) }
        windowKeyObservers.removeAll()
        guard let window else { return }
        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            let token = nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.needsDisplay = true
            }
            windowKeyObservers.append(token)
        }
    }

    /// Derive the grid size from the view bounds + cell metrics and, if it
    /// changed, resize the controller (which resizes the libghostty grid AND
    /// sends `ControllerInputCommand.termsize` to the pty, PROTOCOL §4).
    private func updateTerminalSize() {
        // Ignore pre-layout (zero/tiny) bounds: a degenerate 1x1 grid must not count as the
        // "real" size that gates the backfill replay width (TerminalController.mount), or the
        // replay happens at 1 column and mangles worse than the default.
        guard bounds.width > 2 * padH, bounds.height > 2 * padV else { return }
        let (cols, rows) = GhosttyTerminalView.gridSize(
            width: bounds.width, height: bounds.height, cellSize: cellSize, padH: padH, padV: padV)
        guard cols != lastCols || rows != lastRows else { return }
        let colsChanged = cols != lastCols
        lastCols = cols
        lastRows = rows
        controller.resize(TermSize(rows: rows, cols: cols))
        if colsChanged {
            // reflow: parsed history re-wraps at the new width; drop and re-page
            history.setCols(cols)
            exitHistory()
            virtualSelection = nil
        }
        needsDisplay = true
    }

    // MARK: - Rendering (render.h snapshot -> CoreText)

    private struct CellSnapshot {
        var text: String
        var fg: NSColor
        var bg: NSColor?
        var bold = false
        var italic = false
        var faint = false
        var inverse = false
        var invisible = false
        var underline = false
        var strikethrough = false
        var overline = false
    }

    public override func draw(_ dirtyRect: NSRect) {
        var defaultBg = NSColor.black
        var defaultFg = NSColor(white: 0.76, alpha: 1)
        var grid: [[CellSnapshot]] = []
        var selRanges: [ClosedRange<Int>?] = []
        var cursorVisible = false
        var cursorInViewport = false
        var cursorX = 0
        var cursorY = 0
        var cursorStyle = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK
        var cursorBlinking = false
        var cursorColor = defaultFg
        var sinkSbOffset = 0
        var sinkSbTotal = 0

        // All libghostty-vt access (update + read) under the exclusive lock.
        sink.withTerminal { [weak self] terminal in
            guard let self, let state = self.renderState else { return }
            var sb = GhosttyTerminalScrollbar()
            if ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb) == GHOSTTY_SUCCESS {
                sinkSbOffset = Int(sb.offset)
                sinkSbTotal = Int(sb.total)
            }
            guard ghostty_render_state_update(state, terminal) == GHOSTTY_SUCCESS else { return }

            var colors = GhosttyRenderStateColors()
            colors.size = MemoryLayout<GhosttyRenderStateColors>.stride
            if ghostty_render_state_colors_get(state, &colors) == GHOSTTY_SUCCESS {
                defaultBg = GhosttyTerminalView.color(colors.background)
                defaultFg = GhosttyTerminalView.color(colors.foreground)
                cursorColor = colors.cursor_has_value ? GhosttyTerminalView.color(colors.cursor) : defaultFg
            }

            ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &cursorVisible)
            ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &cursorInViewport)
            if cursorInViewport {
                var cx: UInt16 = 0
                var cy: UInt16 = 0
                ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cx)
                ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cy)
                cursorX = Int(cx)
                cursorY = Int(cy)
                ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &cursorStyle)
                ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &cursorBlinking)
            }

            guard var it = self.rowIterator, var cells = self.rowCells else { return }
            ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &it)
            while ghostty_render_state_row_iterator_next(it) {
                var rowSel = GhosttyRenderStateRowSelection()
                rowSel.size = MemoryLayout<GhosttyRenderStateRowSelection>.stride
                if ghostty_render_state_row_get(it, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &rowSel) == GHOSTTY_SUCCESS {
                    selRanges.append(Int(rowSel.start_x)...Int(rowSel.end_x))
                } else {
                    selRanges.append(nil)
                }
                guard ghostty_render_state_row_get(it, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells) == GHOSTTY_SUCCESS else {
                    grid.append([])
                    continue
                }
                grid.append(GhosttyTerminalView.snapshotRow(cells: cells, defaultFg: defaultFg, defaultBg: defaultBg))
            }
        }

        // A pane shows a FILLED cursor only when it holds key focus AND its window is the
        // key window; otherwise it's HOLLOW — so a background window's focused terminal
        // makes clear that input won't reach it (matching standard terminals).
        let filled = GhosttyTerminalView.cursorIsFilled(
            hasKeyFocus: hasKeyFocus, windowIsKey: window?.isKeyWindow ?? false)
        cursorStyle = GhosttyTerminalView.resolvedCursorStyle(reported: cursorStyle, filled: filled)

        // In history mode the cursor lives below the visible window; suppress it.
        let histOnScreen = histRowsOnScreen

        // Blink only when the focused pane's TUI requested it (render.h CURSOR_BLINKING,
        // driven by DEC mode 12). The timer runs solely while a blink is wanted; on a
        // hidden phase we drop the cursor cell (the glyph beneath still draws).
        let wantBlink = filled && cursorVisible && cursorInViewport && cursorBlinking && histOnScreen == 0
        updateBlinkTimer(active: wantBlink)
        let showCursor = cursorVisible && cursorInViewport && (!wantBlink || cursorBlinkOn) && histOnScreen == 0

        // Paint the snapshot (no terminal access below this line). Honor the terminal
        // background alpha (`term:transparency`) so the window/blur shows through.
        defaultBg.withAlphaComponent(backgroundAlpha).setFill()
        bounds.fill()

        let cw = cellSize.width
        let ch = cellSize.height

        // History rows stitched above the (top-pinned) sink content. Unparsed
        // chunks draw as blank rows until their parse lands (row(at:) kicks it).
        let totalHist = history.totalRows()
        let firstHistRow = totalHist - Swift.min(historyScrollRows, totalHist)
        for r in 0..<histOnScreen {
            let globalRow = firstHistRow + r
            guard let hrow = history.row(at: globalRow) else { continue }
            let y = padV + CGFloat(r) * ch
            let selCols = virtualSelectionCols(historyGlobalRow: globalRow, textWidth: Swift.max(hrow.cells.count, hrow.offsets.count))
            let highlightCols = historyHighlight?.rowIndex == globalRow ? historyHighlight?.cols : nil
            let width = Swift.min(lastCols, Swift.max(hrow.cells.count, 1))
            for col in 0..<width {
                let rect = NSRect(x: padH + CGFloat(col) * cw, y: y, width: cw, height: ch)
                let selected = (selCols?.contains(col) ?? false) || (highlightCols?.contains(col) ?? false)
                drawCell(
                    historyCellSnapshot(hrow, col: col, defaultFg: defaultFg),
                    in: rect, cursor: nil, cursorColor: cursorColor,
                    defaultBg: defaultBg, selected: selected)
            }
        }

        for (row, line) in grid.enumerated() {
            let drawRow = row + histOnScreen
            guard drawRow < lastRows || histOnScreen == 0 else { break }
            let y = padV + CGFloat(drawRow) * ch
            // Selection clamps to the row's text extent -- no wash over the
            // imaginary whitespace right of the last glyph.
            let textWidth = GhosttyTerminalView.textExtent(line)
            let rowSel: Range<Int>?
            if virtualSelection != nil {
                rowSel = virtualSelectionCols(sinkViewportRow: row + sinkSbOffset, textWidth: textWidth)
            } else if row < selRanges.count, let native = selRanges[row] {
                rowSel = GhosttyTerminalView.clampedSelectionCols(
                    lo: native.lowerBound, hi: native.upperBound + 1, textWidth: textWidth)
            } else {
                rowSel = nil
            }
            for (col, cell) in line.enumerated() {
                let rect = NSRect(x: padH + CGFloat(col) * cw, y: y, width: cw, height: ch)
                let isCursorCell = showCursor && col == cursorX && row == cursorY
                let selected = rowSel?.contains(col) ?? false
                drawCell(cell, in: rect, cursor: isCursorCell ? cursorStyle : nil, cursorColor: cursorColor, defaultBg: defaultBg, selected: selected)
            }
        }

        // Cmd-hover link underline, drawn from the same snapshot (no terminal access here).
        // Each spanned cell is underlined in its own fg so a colored link stays consistent.
        // hoverLink.row is a DRAW row: a history row when < histOnScreen, else a sink row.
        if let hoverLink, hoverLink.row >= 0, hoverLink.row < lastRows {
            let yUnderline = padV + CGFloat(hoverLink.row) * ch + ch - 2
            if hoverLink.row < histOnScreen {
                if let hrow = history.row(at: firstHistRow + hoverLink.row) {
                    for col in hoverLink.cols where col >= 0 {
                        let cell = historyCellSnapshot(hrow, col: col, defaultFg: defaultFg)
                        cell.fg.setFill()
                        NSRect(x: padH + CGFloat(col) * cw, y: yUnderline, width: cw, height: 1).fill()
                    }
                }
            } else if hoverLink.row - histOnScreen < grid.count {
                let line = grid[hoverLink.row - histOnScreen]
                for col in hoverLink.cols where col >= 0 && col < line.count {
                    line[col].fg.setFill()
                    NSRect(x: padH + CGFloat(col) * cw, y: yUnderline, width: cw, height: 1).fill()
                }
            }
        }

        drawScrollbar(sinkOffset: sinkSbOffset, sinkTotal: sinkSbTotal)
    }

    /// Columns of a HISTORY row covered by the virtual selection (nil = none).
    /// `textWidth` is the row's text extent (history cells are trailing-trimmed);
    /// the wash never extends past it.
    private func virtualSelectionCols(historyGlobalRow: Int, textWidth: Int) -> Range<Int>? {
        guard let sel = virtualSelection,
              let pos = history.position(ofRow: historyGlobalRow) else { return nil }
        let (start, end) = sel.ordered
        let rowStart = UnifiedPos.history(chunk: pos.chunk, row: pos.row, col: 0)
        let rowEnd = UnifiedPos.history(chunk: pos.chunk, row: pos.row, col: Int.max)
        guard rowStart <= end, start <= rowEnd else { return nil }
        var lo = 0
        var hi = textWidth
        if case let .history(c, r, x) = start, (c, r) == (pos.chunk, pos.row) { lo = x }
        if case let .history(c, r, x) = end, (c, r) == (pos.chunk, pos.row) { hi = x + 1 }
        return GhosttyTerminalView.clampedSelectionCols(lo: lo, hi: hi, textWidth: textWidth)
    }

    /// Columns of a SINK viewport row covered by the virtual selection. The sink
    /// is pinned to its top while a virtual selection exists, so viewport row ==
    /// SCREEN row.
    private func virtualSelectionCols(sinkViewportRow row: Int, textWidth: Int) -> Range<Int>? {
        guard let sel = virtualSelection else { return nil }
        let (start, end) = sel.ordered
        let rowStart = UnifiedPos.sink(screenRow: row, col: 0)
        let rowEnd = UnifiedPos.sink(screenRow: row, col: Int.max)
        guard rowStart <= end, start <= rowEnd else { return nil }
        var lo = 0
        var hi = textWidth
        if case let .sink(r, x) = start, r == row { lo = x }
        if case let .sink(r, x) = end, r == row { hi = x + 1 }
        return GhosttyTerminalView.clampedSelectionCols(lo: lo, hi: hi, textWidth: textWidth)
    }

    /// Clamp a row's selection span to its text extent: selecting past the last
    /// glyph highlights nothing "imaginary" -- a span entirely in the blank
    /// region (including fully blank rows) gets no wash at all.
    static func clampedSelectionCols(lo: Int, hi: Int, textWidth: Int) -> Range<Int>? {
        let l = Swift.max(0, lo)
        let h = Swift.min(hi, textWidth)
        guard h > l else { return nil }
        return l..<h
    }

    private func font(bold: Bool, italic: Bool) -> NSFont {
        if bold && italic { return fontBoldItalic }
        if bold { return fontBold }
        if italic { return fontItalic }
        return font
    }

    private func drawCell(
        _ cell: CellSnapshot,
        in rect: NSRect,
        cursor: GhosttyRenderStateCursorVisualStyle?,
        cursorColor: NSColor,
        defaultBg: NSColor,
        selected: Bool
    ) {
        // Resolve fg/bg, honoring SGR inverse (swap) and faint (dim fg).
        var glyphColor = cell.fg
        var fillColor = cell.bg
        if cell.inverse {
            fillColor = cell.fg
            glyphColor = cell.bg ?? defaultBg
        }
        if cell.faint { glyphColor = glyphColor.withAlphaComponent(0.55) }

        if let fillColor {
            fillColor.setFill()
            rect.fill()
        }

        if let cursor {
            switch cursor {
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
                cursorColor.setFill()
                rect.fill()
                glyphColor = defaultBg // glyph drawn in the background color over the block
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
                cursorColor.setStroke()
                let p = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
                p.lineWidth = 1
                p.stroke()
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
                cursorColor.setFill()
                NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height).fill()
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
                cursorColor.setFill()
                NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2).fill()
            default:
                break
            }
        }

        // Selection wash: over the resolved bg/cursor fill, under the glyph. A theme's
        // `selectionBackground` overrides the default translucent white wash.
        if selected {
            (selectionColorOverride ?? GhosttyTerminalView.selectionColor).setFill()
            rect.fill()
        }

        // Text decorations (drawn in the glyph color, even for blank cells).
        if cell.underline {
            glyphColor.setFill()
            NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 1).fill()
        }
        if cell.strikethrough {
            glyphColor.setFill()
            NSRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1).fill()
        }
        if cell.overline {
            glyphColor.setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
        }

        guard !cell.invisible, !cell.text.isEmpty, cell.text != " " else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font(bold: cell.bold, italic: cell.italic),
            .foregroundColor: glyphColor,
        ]
        (cell.text as NSString).draw(at: NSPoint(x: rect.minX, y: rect.minY), withAttributes: attrs)
    }

    // MARK: - Scrollback (render.h viewport)

    public override func scrollWheel(with event: NSEvent) {
        let deltaY = event.scrollingDeltaY
        guard deltaY != 0 else { return }

        // App in mouse-tracking mode: report wheel as button 4 (up) / 5 (down)
        // presses instead of scrolling the local viewport.
        if mouseTrackingEnabled() {
            let button: GhosttyMouseButton = deltaY > 0 ? GHOSTTY_MOUSE_BUTTON_FOUR : GHOSTTY_MOUSE_BUTTON_FIVE
            let steps = max(1, Int((abs(deltaY) / cellSize.height).rounded()))
            for _ in 0..<steps {
                if let data = encodeMouse(action: GHOSTTY_MOUSE_ACTION_PRESS, button: button, event: event) {
                    controller.sendInput(data)
                }
            }
            return
        }

        // Convert pixels to rows; scrolling up (deltaY > 0) reveals history, which
        // is a NEGATIVE viewport delta (terminal.h: "up is negative"). scrollUnified
        // dispatches between the sink viewport and the paged history layer.
        var rows = -Int((deltaY / cellSize.height).rounded())
        if rows == 0 { rows = deltaY > 0 ? -1 : 1 }
        scrollUnified(rows: rows)
        // A native drag whose wheel-scroll crossed into history converts to a
        // virtual selection so it keeps extending across the seam.
        if virtualSelection == nil, selectionAnchorScreen != nil, historyScrollRows > 0 {
            convertNativeSelectionToVirtual()
        }
        // Mid drag-selection: keep the selection end pinned under the pointer as the
        // viewport scrolls, so wheel-scrolling up extends the selection into history.
        if let win = window, virtualSelection != nil || selectionAnchorScreen != nil {
            let loc = convert(win.mouseLocationOutsideOfEventStream, from: nil)
            let col = min(max(Int((loc.x - padH) / cellSize.width), 0), max(0, lastCols - 1))
            let row = min(max(Int((loc.y - padV) / cellSize.height), 0), max(0, lastRows - 1))
            if virtualSelection != nil {
                extendVirtualSelection(toPoint: NSPoint(x: padH + CGFloat(col) * cellSize.width, y: padV + CGFloat(row) * cellSize.height))
            } else if historyScrollRows == 0 {
                extendSelection(toViewportCol: col, row: row)
            }
        }
        needsDisplay = true
    }

    /// Snap the scrollback viewport to the bottom (newest output). Called on each keystroke
    /// so typing while scrolled up returns to the prompt; a no-op when already at the
    /// bottom or on the alt screen. Also leaves history mode entirely.
    private func scrollViewportToBottom() {
        exitHistory()
        sink.withTerminal { terminal in
            var behavior = GhosttyTerminalScrollViewport()
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
            ghostty_terminal_scroll_viewport(terminal, behavior)
        }
        needsDisplay = true
    }

    /// Snapshot one row's cells into value types (codepoints + resolved colors),
    /// so drawing can happen after the terminal lock is released.
    private static func snapshotRow(
        cells: GhosttyRenderStateRowCells,
        defaultFg: NSColor,
        defaultBg: NSColor
    ) -> [CellSnapshot] {
        var out: [CellSnapshot] = []
        while ghostty_render_state_row_cells_next(cells) {
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

            var fgRgb = GhosttyColorRgb()
            let fg = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fgRgb) == GHOSTTY_SUCCESS
                ? color(fgRgb) : defaultFg

            var bgRgb = GhosttyColorRgb()
            let bg: NSColor? = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bgRgb) == GHOSTTY_SUCCESS
                ? color(bgRgb) : nil

            var style = GhosttyStyle()
            style.size = MemoryLayout<GhosttyStyle>.stride
            _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)

            out.append(CellSnapshot(
                text: text, fg: fg, bg: bg,
                bold: style.bold, italic: style.italic, faint: style.faint,
                inverse: style.inverse, invisible: style.invisible,
                underline: style.underline != 0, strikethrough: style.strikethrough,
                overline: style.overline))
        }
        return out
    }

    /// Text extent of a sink row: one past the last cell with visible content
    /// (glyph, explicit background, inverse video, or a text decoration). Blank
    /// cells right of this are "imaginary whitespace" the selection skips.
    private static func textExtent(_ line: [CellSnapshot]) -> Int {
        var extent = 0
        for (col, cell) in line.enumerated() {
            let hasGlyph = !cell.text.isEmpty && cell.text != " "
            if hasGlyph || cell.bg != nil || cell.inverse
                || cell.underline || cell.strikethrough || cell.overline {
                extent = col + 1
            }
        }
        return extent
    }

    private static func color(_ c: GhosttyColorRgb) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255.0, green: CGFloat(c.g) / 255.0, blue: CGFloat(c.b) / 255.0, alpha: 1)
    }

    static func nsColor(_ c: TermRGB) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r) / 255.0, green: CGFloat(c.g) / 255.0, blue: CGFloat(c.b) / 255.0, alpha: 1)
    }

    /// Derive the (cols, rows) grid for a view size + cell metrics + edge padding.
    /// Pure so the font-change cols recompute is unit-testable.
    static func gridSize(width: CGFloat, height: CGFloat, cellSize: CGSize, padH: CGFloat, padV: CGFloat) -> (cols: Int, rows: Int) {
        let cols = max(1, Int((width - 2 * padH) / cellSize.width))
        let rows = max(1, Int((height - 2 * padV) / cellSize.height))
        return (cols, rows)
    }

    static func measureCell(font: NSFont) -> CGSize {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let advance = ("M" as NSString).size(withAttributes: attrs).width
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        // ROUND (not ceil) the advance: glyphs are positioned at `col * cellWidth`, so
        // ceil over-widened every cell by up to ~1px (Hack 12 advance ≈ 7.22 -> 8),
        // producing a visible gap between characters / text that looked too wide. Round
        // tracks the font's true advance and stays consistent with the integer cell size
        // handed to libghostty.
        return CGSize(width: advance.rounded(), height: ceil(lineHeight))
    }

    // MARK: - Virtualized history (paged on-disk scrollback above the sink)

    /// History rows currently stitched above the sink content on screen.
    private var histRowsOnScreen: Int {
        Swift.min(historyScrollRows, lastRows)
    }

    /// Row counts changed (estimate resolved / chunk parsed / seam advanced):
    /// re-derive the scroll offset from the stable (chunk, row) anchor so the
    /// content on screen does not jump.
    private func historyRowsChanged() {
        guard historyScrollRows > 0 else {
            needsDisplay = true
            return
        }
        let total = history.totalRows()
        // Re-derive the offset from the stable anchor only when its chunk is
        // PARSED (exact): re-deriving through in-flux estimates walked the
        // scroll position around during rapid scrolling.
        if let anchor = historyTopAnchor, history.isParsed(anchor.chunk) {
            historyScrollRows = Swift.max(0, total - history.rowIndex(chunk: anchor.chunk, row: anchor.row))
        }
        historyScrollRows = Swift.min(historyScrollRows, total)
        if historyScrollRows == 0 { historyTopAnchor = nil }
        needsDisplay = true
    }

    /// Record the stable position of the current top visible history row.
    private func rememberTopAnchor() {
        let total = history.totalRows()
        let top = total - Swift.min(historyScrollRows, total)
        historyTopAnchor = history.position(ofRow: top)
    }

    private func sinkAtScrollbackTop() -> Bool {
        var atTop = false
        sink.withTerminal { terminal in
            var sb = GhosttyTerminalScrollbar()
            if ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb) == GHOSTTY_SUCCESS {
                atTop = sb.offset == 0
            }
        }
        return atTop
    }

    private func pinSinkToTop() {
        sink.withTerminal { terminal in
            var behavior = GhosttyTerminalScrollViewport()
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_TOP
            ghostty_terminal_scroll_viewport(terminal, behavior)
        }
    }

    /// One withTerminal block: the sink's top-K signature + row totals for the
    /// content-anchored seam.
    private func snapshotSinkTop() -> SinkTopSnapshot {
        var sig: [String] = []
        var totalRows = 0
        sink.withTerminal { terminal in
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &totalRows)
            sig = self.sinkTopSignature(terminal, rows: 8)
        }
        // The sink's coverage no longer starts at the mount anchor when it hit
        // its scrollback cap (pruning) OR when a reset sequence embedded in the
        // replayed stream wiped rows: rows >= lines always, so retaining fewer
        // rows than the anchored line span proves a gap either way.
        let anchorBase = controller.historyAnchor?.sinkBaseLine ?? 0
        let liveEnd = controller.currentEndLine ?? anchorBase
        let gapSuspected = Int64(totalRows) < (liveEnd - anchorBase)
        return SinkTopSnapshot(
            signature: sig,
            totalRows: totalRows,
            pruned: gapSuspected,
            currentEndLine: controller.currentEndLine,
            cols: lastCols)
    }

    /// Plain text of the sink's oldest K retained SCREEN rows WITHOUT moving the
    /// user's viewport: formatter over a caller-provided selection spanning
    /// SCREEN(0,0)..SCREEN(cols-1,K-1). One line per visual row (unwrap=false);
    /// the formatter omits trailing blank rows, so pad to K.
    private func sinkTopSignature(_ terminal: GhosttyTerminal, rows k: Int) -> [String] {
        var cols16: UInt16 = 0
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols16)
        guard cols16 > 0,
              let start = screenRef(terminal, col: 0, row: 0),
              let end = screenRef(terminal, col: Int(cols16) - 1, row: k - 1) else {
            return Array(repeating: "", count: k)
        }
        var sel = GhosttySelection()
        sel.size = MemoryLayout<GhosttySelection>.stride
        sel.start = start
        sel.end = end
        var text = ""
        withUnsafePointer(to: sel) { selPtr in
            var opts = GhosttyTerminalSelectionFormatOptions()
            opts.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.stride
            opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
            opts.unwrap = false
            opts.trim = true
            opts.selection = selPtr
            var ptr: UnsafeMutablePointer<UInt8>?
            var len = 0
            if ghostty_terminal_selection_format_alloc(terminal, nil, opts, &ptr, &len) == GHOSTTY_SUCCESS, let ptr {
                text = String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
                ghostty_free(nil, ptr, len)
            }
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > k { lines = Array(lines[0..<k]) }
        while lines.count < k { lines.append("") }
        return lines
    }

    /// Unified scroll: positive `rows` scrolls DOWN (toward live), negative
    /// scrolls UP (into history). Handles the three-branch dispatch: adjust the
    /// history offset, cross the seam upward (gated on a fresh anchor), or
    /// delegate to the sink viewport.
    private func scrollUnified(rows: Int) {
        guard rows != 0 else { return }
        touchScrollbar()
        if historyScrollRows > 0 {
            adjustHistoryScroll(by: -rows)
            return
        }
        if rows < 0, sinkAtScrollbackTop(), history.anchor != nil {
            enterHistory(rows: -rows)
            return
        }
        sink.withTerminal { terminal in
            var behavior = GhosttyTerminalScrollViewport()
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
            behavior.value.delta = rows
            ghostty_terminal_scroll_viewport(terminal, behavior)
        }
        needsDisplay = true
    }

    /// Move within history mode. `delta` > 0 scrolls further up (more history).
    private func adjustHistoryScroll(by delta: Int) {
        let total = history.totalRows()
        historyScrollRows = Swift.max(0, Swift.min(total, historyScrollRows + delta))
        if historyScrollRows == 0 {
            historyTopAnchor = nil
        } else {
            rememberTopAnchor()
        }
        needsDisplay = true
    }

    /// Cross the seam from the sink top into history. Entry requires a fresh
    /// seam anchor; when stale (the sink pruned since the last anchor), run the
    /// content-anchored re-anchor first and enter once it lands.
    private func enterHistory(rows: Int) {
        let snapshot = snapshotSinkTop()
        let offset = controller.currentOffset
        if history.seamFresh(currentOffset: offset, pruned: snapshot.pruned) {
            guard history.totalRows() > 0 else { return }
            pinSinkToTop()
            adjustHistoryScroll(by: Swift.max(1, rows))
            return
        }
        guard !reanchorInFlight else {
            pendingEnterRows += rows
            return
        }
        reanchorInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.history.reanchorSeam(sinkTop: snapshot, currentOffset: offset)
            self.reanchorInFlight = false
            let queued = self.pendingEnterRows
            self.pendingEnterRows = 0
            guard self.history.totalRows() > 0 else { return }
            self.pinSinkToTop()
            self.adjustHistoryScroll(by: Swift.max(1, rows + queued))
        }
    }

    /// While frozen in history mode, live prunes move the sink's top. Detect via
    /// the (throttled) signature probe and advance the seam cut forward so the
    /// stitched rows stay gap- and duplicate-free; the scroll offset grows by the
    /// advance so on-screen content does not move.
    private func probeSeamIfFrozen() {
        guard historyScrollRows > 0 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSeamProbe) >= 0.5 else { return }
        lastSeamProbe = now
        let snapshot = snapshotSinkTop()
        guard snapshot.pruned else { return }
        if let advanced = history.advanceSeam(sinkTop: snapshot, currentOffset: controller.currentOffset), advanced > 0 {
            // a .sink selection endpoint renumbers when the sink prunes -- drop it
            if let sel = virtualSelection, isSinkPos(sel.anchor) || isSinkPos(sel.head) {
                virtualSelection = nil
            }
            needsDisplay = true
        }
    }

    private func isSinkPos(_ pos: UnifiedPos) -> Bool {
        if case .sink = pos { return true }
        return false
    }

    /// Leave history mode entirely (typing, snap-to-bottom).
    private func exitHistory() {
        historyScrollRows = 0
        historyTopAnchor = nil
        historyHighlight = nil
    }

    /// Convert a packed history cell to the draw-path snapshot (cached colors).
    private func historyCellSnapshot(_ row: TermHistoryRow, col: Int, defaultFg: NSColor) -> CellSnapshot {
        let cell = col < row.cells.count ? row.cells[col] : TermPackedCell()
        let f = cell.flags
        return CellSnapshot(
            text: row.text(at: col),
            fg: f.contains(.hasFg) ? packedColor(cell.fgRGB) : defaultFg,
            bg: f.contains(.hasBg) ? packedColor(cell.bgRGB) : nil,
            bold: f.contains(.bold), italic: f.contains(.italic), faint: f.contains(.faint),
            inverse: f.contains(.inverse), invisible: f.contains(.invisible),
            underline: f.contains(.underline), strikethrough: f.contains(.strikethrough),
            overline: f.contains(.overline))
    }

    private func packedColor(_ rgb: UInt32) -> NSColor {
        if let cached = packedColorCache[rgb] { return cached }
        let color = NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xff) / 255.0,
            green: CGFloat((rgb >> 8) & 0xff) / 255.0,
            blue: CGFloat(rgb & 0xff) / 255.0,
            alpha: 1)
        packedColorCache[rgb] = color
        return color
    }

    // MARK: - Find bar (Cmd-F, full on-disk history search)

    func showFindBar() {
        if findBar == nil {
            let bar = TerminalFindBarView(frame: .zero)
            bar.onQueryChanged = { [weak self] q in self?.scheduleSearch(q) }
            bar.onNext = { [weak self] in self?.navigateMatch(step: 1) }
            bar.onPrev = { [weak self] in self?.navigateMatch(step: -1) }
            bar.onClose = { [weak self] in self?.hideFindBar() }
            addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6 - Self.scrollbarWidth),
            ])
            findBar = bar
        }
        findBar?.focusField(selectAll: true)
    }

    func hideFindBar() {
        findDebounce?.cancel()
        jumpTask?.cancel()
        findBar?.removeFromSuperview()
        findBar = nil
        searchMatches = []
        searchTruncated = false
        historyHighlight = nil
        sink.withTerminal { terminal in
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func scheduleSearch(_ query: String) {
        findDebounce?.cancel()
        historyHighlight = nil
        guard !query.isEmpty else {
            searchMatches = []
            searchTruncated = false
            findBar?.setCount(current: 0, total: 0, truncated: false)
            needsDisplay = true
            return
        }
        findDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            guard let rtn = try? await self.controller.searchScrollback(query: query) else { return }
            guard !Task.isCancelled, self.findBar?.query == query else { return }
            self.searchMatches = rtn.matches ?? []
            self.searchTruncated = rtn.truncated ?? false
            self.searchTotalLines = rtn.totallines ?? 0
            self.searchIndex = Swift.max(0, self.searchMatches.count - 1)
            self.findBar?.setCount(current: self.searchIndex, total: self.searchMatches.count, truncated: self.searchTruncated)
            self.needsDisplay = true
            if !self.searchMatches.isEmpty {
                self.jumpToMatch(self.searchMatches[self.searchIndex], query: query)
            }
        }
    }

    private func navigateMatch(step: Int) {
        guard !searchMatches.isEmpty else { return }
        searchIndex = (searchIndex + step + searchMatches.count) % searchMatches.count
        findBar?.setCount(current: searchIndex, total: searchMatches.count, truncated: searchTruncated)
        jumpToMatch(searchMatches[searchIndex], query: findBar?.query ?? "")
    }

    /// Jump to a search match: history matches page in their chunk and center
    /// with a highlight wash; sink matches scroll the live viewport by line
    /// fraction, then content-verify against the visible rows and select the
    /// hit natively. History jumps can take seconds (10k-line chunk fetch +
    /// scratch-VT parse), so the find bar shows a busy state until the jump
    /// lands and a newer jump supersedes this one.
    private func jumpToMatch(_ match: TermSearchMatch, query: String) {
        jumpTask?.cancel()
        findBar?.setBusy(true)
        jumpTask = Task { @MainActor [weak self] in
            defer { self?.findBar?.setBusy(false) }
            guard let self else { return }
            // Anchor the seam first: coverage must include every line the sink
            // no longer retains (pruned or reset-wiped) before deciding whether
            // the match lives in history or in the live sink.
            let snapshot = self.snapshotSinkTop()
            let offset = self.controller.currentOffset
            if !self.history.seamFresh(currentOffset: offset, pruned: snapshot.pruned) {
                _ = await self.history.reanchorSeam(sinkTop: snapshot, currentOffset: offset)
            }
            if Task.isCancelled { return }
            if let hit = await self.history.locateMatch(line: match.line, query: query) {
                if Task.isCancelled { return }
                self.pinSinkToTop()
                let total = self.history.totalRows()
                self.historyScrollRows = Swift.max(1, Swift.min(total, total - hit.row + self.lastRows / 2))
                self.rememberTopAnchor()
                self.historyHighlight = (hit.row, hit.cols)
                self.needsDisplay = true
                return
            }
            if Task.isCancelled { return }
            // In the sink layer: scroll to the match line's fraction and verify.
            self.exitHistory()
            self.scrollSinkToLine(match.line)
            if !self.highlightInVisibleSinkRows(query: query) {
                self.pageWalkSinkToQuery(query)
            }
            self.needsDisplay = true
        }
    }

    /// Scroll the sink viewport so the given logical line is roughly centered.
    /// The sink's rows cover [coverageEndLine, liveEnd] once the seam is
    /// anchored (NOT [mount anchor, liveEnd] — pruning/reset-wipes shrink it),
    /// so the fraction maps against the sink's actual top line.
    private func scrollSinkToLine(_ line: Int64) {
        let sinkStart = Swift.max(history.historyEndLine, history.anchor?.sinkBaseLine ?? 0)
        let liveEnd = Swift.max(controller.currentEndLine ?? searchTotalLines, sinkStart + 1)
        let frac = Double(Swift.max(0, line - sinkStart)) / Double(Swift.max(1, liveEnd - sinkStart))
        sink.withTerminal { terminal in
            var sb = GhosttyTerminalScrollbar()
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb) == GHOSTTY_SUCCESS else { return }
            let scrollable = Int(sb.total) - Int(sb.len)
            guard scrollable > 0 else { return }
            let target = Swift.max(0, Swift.min(scrollable, Int((frac * Double(sb.total)).rounded()) - Int(sb.len) / 2))
            var behavior = GhosttyTerminalScrollViewport()
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
            behavior.value.delta = target - Int(sb.offset)
            ghostty_terminal_scroll_viewport(terminal, behavior)
        }
    }

    /// Find the query in the currently visible sink rows and select it natively
    /// (the existing selection wash becomes the match highlight). Returns
    /// whether the query was found on screen.
    @discardableResult
    private func highlightInVisibleSinkRows(query: String) -> Bool {
        guard !query.isEmpty else { return false }
        let needle = query.lowercased()
        var found = false
        sink.withTerminal { [weak self] terminal in
            guard let self, let state = self.renderState,
                  ghostty_render_state_update(state, terminal) == GHOSTTY_SUCCESS,
                  var it = self.rowIterator, var cells = self.rowCells else { return }
            ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &it)
            var rowIdx = 0
            while ghostty_render_state_row_iterator_next(it) {
                defer { rowIdx += 1 }
                guard ghostty_render_state_row_get(it, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells) == GHOSTTY_SUCCESS else { continue }
                let (line, offsets) = GhosttyTerminalView.rowLine(cells: cells)
                guard let r = line.lowercased().range(of: needle) else { continue }
                let lowerOff = line.utf16.distance(from: line.utf16.startIndex, to: r.lowerBound.samePosition(in: line.utf16) ?? line.utf16.startIndex)
                let upperOff = line.utf16.distance(from: line.utf16.startIndex, to: r.upperBound.samePosition(in: line.utf16) ?? line.utf16.endIndex)
                guard let cols = GhosttyTerminalView.columnRange(offsets: offsets, utf16Lower: lowerOff, utf16Upper: upperOff),
                      let s = self.gridRef(terminal, col: cols.lowerBound, row: rowIdx),
                      let e = self.gridRef(terminal, col: cols.upperBound, row: rowIdx) else { return }
                var sel = GhosttySelection()
                sel.size = MemoryLayout<GhosttySelection>.stride
                sel.start = s
                sel.end = e
                withUnsafePointer(to: &sel) { _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, $0) }
                found = true
                return
            }
        }
        return found
    }

    /// Pages the fraction-scroll may be off by before a sink match is declared
    /// missing (wrapped rows skew the line->row mapping locally).
    private static let sinkVerifyPages = 6

    /// The line-fraction landing missed the match: probe outward page by page
    /// (nearest first) and settle on the first viewport that contains the
    /// query. Restores the landing position when nothing is found in range.
    private func pageWalkSinkToQuery(_ query: String) {
        guard let start = sinkScrollbarState(), start.total > start.len else { return }
        for delta in 1...Self.sinkVerifyPages {
            for dir in [delta, -delta] {
                let target = Swift.max(0, Swift.min(start.total - start.len, start.offset + dir * start.len))
                guard target != start.offset else { continue }
                scrollSink(toOffset: target)
                if highlightInVisibleSinkRows(query: query) { return }
            }
        }
        scrollSink(toOffset: start.offset)
    }

    private func sinkScrollbarState() -> (offset: Int, len: Int, total: Int)? {
        var result: (Int, Int, Int)?
        sink.withTerminal { terminal in
            var sb = GhosttyTerminalScrollbar()
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb) == GHOSTTY_SUCCESS else { return }
            result = (Int(sb.offset), Int(sb.len), Int(sb.total))
        }
        return result
    }

    private func scrollSink(toOffset target: Int) {
        sink.withTerminal { terminal in
            var sb = GhosttyTerminalScrollbar()
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb) == GHOSTTY_SUCCESS else { return }
            var behavior = GhosttyTerminalScrollViewport()
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
            behavior.value.delta = target - Int(sb.offset)
            ghostty_terminal_scroll_viewport(terminal, behavior)
        }
    }

    // MARK: - Line-space scrollbar + search-hit bar

    private var scrollbarVisible: Bool {
        scrollbarDragging || !searchMatches.isEmpty || Date() < scrollbarActiveUntil
    }

    /// Keep the overlay bar up while scrolling; schedule the fade-out repaint.
    private func touchScrollbar() {
        scrollbarActiveUntil = Date().addingTimeInterval(1.0)
        scrollbarFadeTimer?.invalidate()
        scrollbarFadeTimer = Timer.scheduledTimer(withTimeInterval: 1.05, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.needsDisplay = true }
        }
    }

    /// The scrollbar's logical-line domain: [0, live end line].
    private func scrollbarTotalLines() -> Int64 {
        Swift.max(controller.currentEndLine ?? searchTotalLines, 1)
    }

    /// Logical line of the top visible row (history: from the model; live: the
    /// sink viewport fraction mapped into [sink top line, live end]).
    private func scrollbarTopLine(sinkOffset: Int, sinkTotal: Int) -> Double {
        if historyScrollRows > 0 {
            let total = history.totalRows()
            let top = total - Swift.min(historyScrollRows, total)
            if let line = history.lineOfRow(top) { return Double(line) }
        }
        let sinkStart = Double(Swift.max(history.historyEndLine, history.anchor?.sinkBaseLine ?? 0))
        let liveEnd = Double(scrollbarTotalLines())
        guard sinkTotal > 0 else { return liveEnd }
        return sinkStart + (Double(sinkOffset) / Double(sinkTotal)) * (liveEnd - sinkStart)
    }

    /// Draw the overlay track + thumb + exact search-hit markers.
    private func drawScrollbar(sinkOffset: Int, sinkTotal: Int) {
        guard scrollbarVisible else { return }
        let trackHeight = bounds.height
        let totalLines = Double(scrollbarTotalLines())
        let linesOnScreen = Double(lastRows) / Swift.max(1.0, history.rowsPerLine)
        guard let geo = TermScrollbarMath.geometry(
            topLine: scrollbarTopLine(sinkOffset: sinkOffset, sinkTotal: sinkTotal),
            linesOnScreen: linesOnScreen,
            totalLines: totalLines,
            matchLines: searchMatches.map(\.line),
            trackHeight: trackHeight) else { return }
        let x = bounds.width - Self.scrollbarWidth
        NSColor(white: 1, alpha: 0.08).setFill()
        NSRect(x: x, y: 0, width: Self.scrollbarWidth, height: trackHeight).fill()
        NSColor(white: 1, alpha: 0.35).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: x + 2, y: geo.thumbY, width: Self.scrollbarWidth - 4, height: geo.thumbHeight),
            xRadius: 3, yRadius: 3
        ).fill()
        NSColor.systemYellow.withAlphaComponent(0.9).setFill()
        for y in geo.markerYs {
            NSRect(x: x + 1, y: y, width: Self.scrollbarWidth - 2, height: 2).fill()
        }
    }

    /// Jump so the given logical line is visible: history lines page in their
    /// chunk; sink lines scroll the live viewport. The seam is anchored FIRST
    /// so the history-vs-sink classification is correct even when the sink has
    /// pruned since the last anchor (Home to line 0, scrollbar clicks).
    private func jumpToLine(_ line: Int64) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.history.anchor != nil {
                let snapshot = self.snapshotSinkTop()
                let offset = self.controller.currentOffset
                if !self.history.seamFresh(currentOffset: offset, pruned: snapshot.pruned) {
                    guard !self.reanchorInFlight else { return }
                    self.reanchorInFlight = true
                    _ = await self.history.reanchorSeam(sinkTop: snapshot, currentOffset: offset)
                    self.reanchorInFlight = false
                }
            }
            if line < self.history.historyEndLine, self.history.anchor != nil {
                let total = self.history.totalRows()
                guard total > 0 else { return }
                let row = self.history.estimatedRow(forLine: line) ?? 0
                self.pinSinkToTop()
                self.historyScrollRows = Swift.max(1, Swift.min(total, total - row))
                self.rememberTopAnchor()
            } else {
                self.exitHistory()
                self.scrollSinkToLine(line)
            }
            self.needsDisplay = true
        }
    }

    /// Scrollbar-track hit handling. Returns true when the event was consumed.
    private func handleScrollbarMouse(_ event: NSEvent, isDrag: Bool) -> Bool {
        let p = convert(event.locationInWindow, from: nil)
        if !isDrag {
            guard scrollbarVisible, p.x >= bounds.width - Self.scrollbarWidth else { return false }
            scrollbarDragging = true
        } else {
            guard scrollbarDragging else { return false }
        }
        let line = TermScrollbarMath.line(
            atTrackY: min(max(p.y, 0), bounds.height),
            trackHeight: bounds.height,
            totalLines: Double(scrollbarTotalLines()))
        jumpToLine(line)
        touchScrollbar()
        return true
    }

    // MARK: - Mouse (selection.h drag/copy + mouse/encoder.h reporting)

    public override func mouseDown(with event: NSEvent) {
        // Any click focuses this pane (green border + keyboard focus), even for a
        // mouse-tracking app that consumes the event below.
        onFocusRequest?()
        if handleScrollbarMouse(event, isDrag: false) { return }
        // Multi-clicks (2+) always select locally, even when the app tracks the
        // mouse — double-click in vi/tmux should behave like double-click at the
        // shell (word highlight + Cmd+C), not vanish into the app. Single clicks
        // still forward, so cursor positioning in those apps keeps working.
        let tracking = mouseTrackingEnabled()
        if tracking, event.clickCount < 2 {
            if virtualSelection != nil {
                virtualSelection = nil
                needsDisplay = true
            }
            mouseButtonDown = true
            send(GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_LEFT, event: event)
            return
        }
        trackingLocalGesture = tracking

        // Cmd-click opens a URL as a web pane (no selection). Gated to tracking-off
        // (handled above) so it never steals the app's mouse input. We try the
        // explicit OSC-8 hyperlink FIRST (the app's declared intent), then fall back
        // to autodetecting a plain http(s)/www/file URL in the clicked row's text.
        if !tracking, event.modifierFlags.contains(.command) {
            if let uri = hyperlinkURI(for: event) {
                onOpenWebURL?(controller.blockId, uri)
                return
            }
            if let url = autodetectedURL(for: event) {
                onOpenWebURL?(controller.blockId, url)
                return
            }
            if let fileURL = autodetectedPath(for: event) {
                NSWorkspace.shared.open(fileURL)
                return
            }
        }

        // Local selection.
        let (col, row) = gridCoord(for: event)
        let p = convert(event.locationInWindow, from: nil)

        // Shift-click extends the existing selection (either model) to the
        // clicked cell; a completed native selection is adopted into the
        // unified model first so the extension can later cross the seam.
        if event.modifierFlags.contains(.shift), event.clickCount == 1 {
            if virtualSelection == nil, nativeSelectionEndpoints() != nil {
                convertCompletedNativeSelection()
            }
            if virtualSelection != nil {
                extendVirtualSelection(toPoint: p)
                dragMovedSelection = true
                return
            }
        }

        // Multi-click: word (2) / line (3+) selection in the unified model --
        // identical in live and history rows, and drags keep the granularity.
        if event.clickCount >= 2 {
            selectionAnchorScreen = nil
            guard let pos = unifiedHit(p) else { return }
            let granularity: SelectionGranularity = event.clickCount >= 3 ? .line : .word
            let range = unifiedRange(at: pos, granularity: granularity)
            selectionGranularity = granularity
            granularityAnchorRange = range
            virtualSelection = VirtualSelection(anchor: range.0, head: range.1)
            dragMovedSelection = false
            needsDisplay = true
            return
        }

        selectionGranularity = .char
        granularityAnchorRange = nil

        // History mode: all selection is virtual (spans history + sink rows).
        if histRowsOnScreen > 0 {
            selectionAnchorScreen = nil
            if let pos = unifiedHit(p) {
                virtualSelection = VirtualSelection(anchor: pos, head: pos)
            }
            dragMovedSelection = false
            needsDisplay = true
            return
        }

        virtualSelection = nil
        sink.withTerminal { terminal in
            self.selectionAnchorScreen = self.screenCoord(terminal, col: col, row: row)
        }
        dragMovedSelection = false
    }

    /// Map a view point to a unified position. Unparsed placeholder rows are
    /// momentarily unselectable (nil).
    private func unifiedHit(_ p: NSPoint) -> UnifiedPos? {
        let col = min(max(Int((p.x - padH) / cellSize.width), 0), max(0, lastCols - 1))
        let drawRow = min(max(Int((p.y - padV) / cellSize.height), 0), max(0, lastRows - 1))
        let hos = histRowsOnScreen
        if drawRow < hos {
            let total = history.totalRows()
            let globalRow = total - Swift.min(historyScrollRows, total) + drawRow
            guard let pos = history.position(ofRow: globalRow), history.isParsed(pos.chunk) else { return nil }
            return .history(chunk: pos.chunk, row: pos.row, col: col)
        }
        let viewportRow = drawRow - hos
        if hos > 0 {
            // sink pinned to top: viewport row == SCREEN row
            return .sink(screenRow: viewportRow, col: col)
        }
        var pos: UnifiedPos?
        sink.withTerminal { terminal in
            if let sc = self.screenCoord(terminal, col: col, row: viewportRow) {
                pos = .sink(screenRow: sc.row, col: sc.col)
            }
        }
        return pos
    }

    /// Word range around a column in a history row's plain text. Word
    /// characters are anything outside the boundary set (whitespace + common
    /// punctuation, mirroring ghostty's live-word feel); clicking ON a
    /// boundary char selects the contiguous run of that same char.
    static func plainWordRange(_ plain: String, col: Int) -> ClosedRange<Int>? {
        let chars = Array(plain)
        guard col >= 0, col < chars.count else { return nil }
        let boundaries: Set<Character> = [
            " ", "\t", "'", "\"", "`", "(", ")", "{", "}", "[", "]", "<", ">", "|", ",", ";", ":",
        ]
        let clicked = chars[col]
        var lo = col
        var hi = col
        if boundaries.contains(clicked) {
            while lo > 0, chars[lo - 1] == clicked { lo -= 1 }
            while hi + 1 < chars.count, chars[hi + 1] == clicked { hi += 1 }
        } else {
            while lo > 0, !boundaries.contains(chars[lo - 1]) { lo -= 1 }
            while hi + 1 < chars.count, !boundaries.contains(chars[hi + 1]) { hi += 1 }
        }
        return lo...hi
    }

    /// The word/line range covering a unified position -- ghostty-native in the
    /// sink layer, plain-text/continuation-walk in parsed history rows.
    private func unifiedRange(at pos: UnifiedPos, granularity: SelectionGranularity) -> (UnifiedPos, UnifiedPos) {
        switch granularity {
        case .char:
            return (pos, pos)
        case .word:
            return unifiedWordRange(at: pos) ?? (pos, pos)
        case .line:
            return unifiedLineRange(at: pos) ?? (pos, pos)
        }
    }

    private func unifiedWordRange(at pos: UnifiedPos) -> (UnifiedPos, UnifiedPos)? {
        switch pos {
        case let .history(chunk, rowIdx, col):
            guard let parsed = history.parsedChunk(chunk), rowIdx < parsed.rows.count else { return nil }
            let plain = parsed.rows[rowIdx].plain
            guard !plain.isEmpty,
                  let r = Self.plainWordRange(plain, col: Swift.min(col, plain.count - 1)) else { return nil }
            return (.history(chunk: chunk, row: rowIdx, col: r.lowerBound),
                    .history(chunk: chunk, row: rowIdx, col: r.upperBound))
        case let .sink(screenRow, col):
            return sinkSelectionRange(screenRow: screenRow, col: col) { terminal, ref, sel in
                var opts = GhosttyTerminalSelectWordOptions()
                opts.size = MemoryLayout<GhosttyTerminalSelectWordOptions>.stride
                opts.ref = ref
                return withUnsafePointer(to: &opts) { ghostty_terminal_select_word(terminal, $0, sel) }
            }
        }
    }

    private func unifiedLineRange(at pos: UnifiedPos) -> (UnifiedPos, UnifiedPos)? {
        switch pos {
        case let .history(chunk, rowIdx, _):
            guard let parsed = history.parsedChunk(chunk), rowIdx < parsed.rows.count else { return nil }
            var first = rowIdx
            while first > 0, parsed.rows[first].isContinuation { first -= 1 }
            var last = rowIdx
            while last + 1 < parsed.rows.count, parsed.rows[last + 1].isContinuation { last += 1 }
            let width = Swift.max(parsed.rows[last].cells.count, 1)
            return (.history(chunk: chunk, row: first, col: 0),
                    .history(chunk: chunk, row: last, col: width - 1))
        case let .sink(screenRow, col):
            return sinkSelectionRange(screenRow: screenRow, col: col) { terminal, ref, sel in
                var opts = GhosttyTerminalSelectLineOptions()
                opts.size = MemoryLayout<GhosttyTerminalSelectLineOptions>.stride
                opts.ref = ref
                return withUnsafePointer(to: &opts) { ghostty_terminal_select_line(terminal, $0, sel) }
            }
        }
    }

    /// Run a ghostty select-derivation (word/line) at a SCREEN cell and return
    /// its endpoints as unified sink positions.
    private func sinkSelectionRange(
        screenRow: Int, col: Int,
        derive: (GhosttyTerminal, GhosttyGridRef, UnsafeMutablePointer<GhosttySelection>) -> GhosttyResult
    ) -> (UnifiedPos, UnifiedPos)? {
        var result: (UnifiedPos, UnifiedPos)?
        sink.withTerminal { terminal in
            guard let ref = self.screenRef(terminal, col: col, row: screenRow) else { return }
            var sel = GhosttySelection()
            sel.size = MemoryLayout<GhosttySelection>.stride
            guard derive(terminal, ref, &sel) == GHOSTTY_SUCCESS else { return }
            var startRef = sel.start
            var endRef = sel.end
            var sc = GhosttyPointCoordinate()
            var ec = GhosttyPointCoordinate()
            guard ghostty_terminal_point_from_grid_ref(terminal, &startRef, GHOSTTY_POINT_TAG_SCREEN, &sc) == GHOSTTY_SUCCESS,
                  ghostty_terminal_point_from_grid_ref(terminal, &endRef, GHOSTTY_POINT_TAG_SCREEN, &ec) == GHOSTTY_SUCCESS
            else { return }
            result = (.sink(screenRow: Int(sc.y), col: Int(sc.x)),
                      .sink(screenRow: Int(ec.y), col: Int(ec.x)))
        }
        return result
    }

    /// Endpoints of a completed NATIVE selection in SCREEN coords, or nil.
    private func nativeSelectionEndpoints() -> (start: (row: Int, col: Int), end: (row: Int, col: Int))? {
        var result: (start: (row: Int, col: Int), end: (row: Int, col: Int))?
        sink.withTerminal { terminal in
            var sel = GhosttySelection()
            sel.size = MemoryLayout<GhosttySelection>.stride
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &sel) == GHOSTTY_SUCCESS else { return }
            var startRef = sel.start
            var endRef = sel.end
            var sc = GhosttyPointCoordinate()
            var ec = GhosttyPointCoordinate()
            guard ghostty_terminal_point_from_grid_ref(terminal, &startRef, GHOSTTY_POINT_TAG_SCREEN, &sc) == GHOSTTY_SUCCESS,
                  ghostty_terminal_point_from_grid_ref(terminal, &endRef, GHOSTTY_POINT_TAG_SCREEN, &ec) == GHOSTTY_SUCCESS
            else { return }
            result = ((Int(sc.y), Int(sc.x)), (Int(ec.y), Int(ec.x)))
        }
        return result
    }

    /// Adopt a completed native selection into the unified model (shift-click
    /// extension and keyboard selection start from it).
    @discardableResult
    private func convertCompletedNativeSelection() -> Bool {
        guard let ep = nativeSelectionEndpoints() else { return false }
        sink.withTerminal { terminal in
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
        }
        virtualSelection = VirtualSelection(
            anchor: .sink(screenRow: ep.start.row, col: ep.start.col),
            head: .sink(screenRow: ep.end.row, col: ep.end.col))
        selectionGranularity = .char
        granularityAnchorRange = nil
        return true
    }

    // MARK: keyboard selection (Shift+arrows / PageUp/PageDown / Home/End)

    /// Position arithmetic over the stitched row space: history rows first,
    /// then the sink's SCREEN rows.
    private func unifiedGlobalPosition(_ pos: UnifiedPos) -> (row: Int, col: Int) {
        switch pos {
        case let .history(chunk, row, col):
            return (history.rowIndex(chunk: chunk, row: row), col)
        case let .sink(screenRow, col):
            return (history.totalRows() + screenRow, col)
        }
    }

    private func unifiedPosAtGlobal(row: Int, col: Int) -> UnifiedPos? {
        let histTotal = history.totalRows()
        if row < histTotal {
            guard let p = history.position(ofRow: row), history.isParsed(p.chunk) else { return nil }
            return .history(chunk: p.chunk, row: p.row, col: Swift.max(0, col))
        }
        return .sink(screenRow: row - histTotal, col: Swift.max(0, col))
    }

    private func sinkTotalRows() -> Int {
        var total = 0
        sink.withTerminal { terminal in
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total)
        }
        return total
    }

    /// Scroll the stitched space just enough to bring a global row into view.
    private func ensureGlobalRowVisible(_ row: Int) {
        let histTotal = history.totalRows()
        let h = Swift.min(historyScrollRows, histTotal)
        var first: Int
        if h > 0 {
            first = histTotal - h
        } else {
            var off = 0
            sink.withTerminal { terminal in
                var sb = GhosttyTerminalScrollbar()
                if ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb) == GHOSTTY_SUCCESS {
                    off = Int(sb.offset)
                }
            }
            first = histTotal + off
        }
        if row < first {
            scrollUnified(rows: row - first)
        } else if row >= first + lastRows {
            scrollUnified(rows: row - (first + lastRows - 1))
        }
    }

    /// Whether the terminal is on the ALTERNATE screen (vim/less/htop -- DEC
    /// private modes 47/1047/1049). Nav keys encode to the pty there instead
    /// of scrolling (the alt screen has no scrollback).
    private func altScreenActive() -> Bool {
        var active = false
        sink.withTerminal { terminal in
            for mode in [47, 1047, 1049] {
                var on = false
                if ghostty_terminal_mode_get(terminal, GhosttyMode(UInt16(mode)), &on) == GHOSTTY_SUCCESS, on {
                    active = true
                    return
                }
            }
        }
        return active
    }

    /// Nav-key buffer scrolling on the primary screen: PageUp/PageDown page the
    /// unified buffer, Shift+Home jumps to the very top of the on-disk history,
    /// Shift+End back to the live prompt. Plain Home/End are NOT consumed — they
    /// encode to the pty (kitty/Ghostty convention), because primary-screen line
    /// editors (Claude Code, readline) bind them for cursor movement.
    private func handleNavScrollKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function)
        let shifted = flags == .shift
        guard flags.isEmpty || shifted else { return false }
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        let key = Int(scalar.value)
        guard [NSPageUpFunctionKey, NSPageDownFunctionKey, NSHomeFunctionKey, NSEndFunctionKey].contains(key) else {
            return false
        }
        guard !mouseTrackingEnabled(), !altScreenActive() else { return false }
        switch key {
        case NSPageUpFunctionKey:
            scrollUnified(rows: -Swift.max(1, lastRows - 1))
        case NSPageDownFunctionKey:
            scrollUnified(rows: Swift.max(1, lastRows - 1))
        case NSHomeFunctionKey:
            guard shifted else { return false }
            if history.anchor != nil {
                jumpToLine(0)
            } else {
                pinSinkToTop()
            }
        case NSEndFunctionKey:
            guard shifted else { return false }
            scrollViewportToBottom()
        default:
            return false
        }
        needsDisplay = true
        return true
    }

    /// Shift+arrow/page/home/end adjusts the selection head while a selection
    /// exists (mouse- or Cmd-A-initiated). Without one, the keys pass through
    /// to the pty untouched, so TUI shift-key encodings keep working.
    private func handleSelectionKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.shift), !flags.contains(.control),
              !flags.contains(.option), !flags.contains(.command) else { return false }
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return false }
        let key = Int(scalar.value)
        let selectionKeys: Set<Int> = [
            NSLeftArrowFunctionKey, NSRightArrowFunctionKey, NSUpArrowFunctionKey,
            NSDownArrowFunctionKey, NSPageUpFunctionKey, NSPageDownFunctionKey,
            NSHomeFunctionKey, NSEndFunctionKey,
        ]
        guard selectionKeys.contains(key) else { return false }
        if virtualSelection == nil {
            guard convertCompletedNativeSelection() else { return false }
        }
        guard let sel = virtualSelection else { return false }
        var (row, col) = unifiedGlobalPosition(sel.head)
        switch key {
        case NSLeftArrowFunctionKey: col = Swift.max(0, col - 1)
        case NSRightArrowFunctionKey: col = Swift.min(Swift.max(0, lastCols - 1), col + 1)
        case NSUpArrowFunctionKey: row -= 1
        case NSDownArrowFunctionKey: row += 1
        case NSPageUpFunctionKey: row -= Swift.max(1, lastRows - 1)
        case NSPageDownFunctionKey: row += Swift.max(1, lastRows - 1)
        case NSHomeFunctionKey: col = 0
        case NSEndFunctionKey: col = Swift.max(0, lastCols - 1)
        default: return false
        }
        let maxRow = history.totalRows() + sinkTotalRows() - 1
        row = Swift.max(0, Swift.min(maxRow, row))
        if let newHead = unifiedPosAtGlobal(row: row, col: col) {
            virtualSelection?.head = newHead
        }
        ensureGlobalRowVisible(row)
        needsDisplay = true
        return true
    }

    /// Extend the virtual selection to a view point, honoring the multi-click
    /// granularity: word/line drags select the UNION of the anchor range and
    /// the pointer's range.
    private func extendVirtualSelection(toPoint p: NSPoint) {
        guard virtualSelection != nil else { return }
        guard let pos = unifiedHit(p) else {
            needsDisplay = true
            return
        }
        if selectionGranularity != .char, let anchorRange = granularityAnchorRange {
            let headRange = unifiedRange(at: pos, granularity: selectionGranularity)
            if headRange.0 < anchorRange.start {
                virtualSelection = VirtualSelection(anchor: anchorRange.end, head: headRange.0)
            } else {
                virtualSelection = VirtualSelection(
                    anchor: anchorRange.start,
                    head: Swift.max(headRange.1, anchorRange.end))
            }
        } else {
            virtualSelection?.head = pos
        }
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        if handleScrollbarMouse(event, isDrag: true) { return }
        if mouseTrackingEnabled(), !trackingLocalGesture {
            send(GHOSTTY_MOUSE_ACTION_MOTION, button: GHOSTTY_MOUSE_BUTTON_LEFT, event: event)
            return
        }
        if virtualSelection != nil {
            dragMovedSelection = true
            lastDragEvent = event
            extendVirtualSelection(toPoint: convert(event.locationInWindow, from: nil))
            // A tracking-local gesture stays on the visible (alt) screen:
            // edge-autoscroll would page shell history over the running app.
            if !trackingLocalGesture { updateAutoScroll(for: event) }
            return
        }
        guard selectionAnchorScreen != nil else { return }
        dragMovedSelection = true
        lastDragEvent = event
        let (col, row) = gridCoord(for: event)
        extendSelection(toViewportCol: col, row: row)
        updateAutoScroll(for: event)
    }

    public override func mouseUp(with event: NSEvent) {
        stopAutoScroll()
        lastDragEvent = nil
        if scrollbarDragging {
            scrollbarDragging = false
            touchScrollbar()
            return
        }
        if mouseTrackingEnabled(), !trackingLocalGesture {
            mouseButtonDown = false
            send(GHOSTTY_MOUSE_ACTION_RELEASE, button: GHOSTTY_MOUSE_BUTTON_LEFT, event: event)
            return
        }
        trackingLocalGesture = false
        // A plain click that never dragged clears any existing selection.
        if virtualSelection != nil, !dragMovedSelection, event.clickCount < 2 {
            virtualSelection = nil
            needsDisplay = true
        }
        if selectionAnchorScreen != nil, !dragMovedSelection {
            sink.withTerminal { terminal in
                ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
            }
            needsDisplay = true
        }
        selectionAnchorScreen = nil
        dragMovedSelection = false
    }

    /// Set the selection from the stored absolute anchor to the given viewport cell.
    /// Runs on every drag tick and every auto-scroll tick; both endpoints are resolved in
    /// ABSOLUTE screen space so the selection stays put as the viewport scrolls.
    private func extendSelection(toViewportCol col: Int, row: Int) {
        guard let anchor = selectionAnchorScreen else { return }
        sink.withTerminal { terminal in
            guard let end = self.screenCoord(terminal, col: col, row: row),
                  let startRef = self.screenRef(terminal, col: anchor.col, row: anchor.row),
                  let endRef = self.screenRef(terminal, col: end.col, row: end.row) else { return }
            var sel = GhosttySelection()
            sel.size = MemoryLayout<GhosttySelection>.stride
            sel.start = startRef
            sel.end = endRef
            withUnsafePointer(to: &sel) { _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, $0) }
        }
        needsDisplay = true
    }

    /// Convert a viewport cell to its ABSOLUTE screen (scrollback-inclusive) coordinate,
    /// so a selection endpoint pins to history instead of drifting when the viewport
    /// scrolls. Must be called inside `withTerminal`.
    private func screenCoord(_ terminal: GhosttyTerminal, col: Int, row: Int) -> (col: Int, row: Int)? {
        guard var ref = gridRef(terminal, col: col, row: row) else { return nil }
        var out = GhosttyPointCoordinate()
        guard ghostty_terminal_point_from_grid_ref(terminal, &ref, GHOSTTY_POINT_TAG_SCREEN, &out) == GHOSTTY_SUCCESS
        else { return nil }
        return (Int(out.x), Int(out.y))
    }

    /// Start (or keep) the edge auto-scroll while the pointer is dragged past the top or
    /// bottom of the grid; stop it once the pointer is back inside.
    private func updateAutoScroll(for event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let outside = p.y < padV || p.y > bounds.height - padV
        guard outside else { stopAutoScroll(); return }
        guard autoScrollTimer == nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.autoScrollTick() }
        RunLoop.current.add(t, forMode: .eventTracking)
        RunLoop.current.add(t, forMode: .default)
        autoScrollTimer = t
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    /// One auto-scroll step: nudge the viewport toward the off-screen pointer and re-pin
    /// the selection end to the (clamped) edge row now under the pointer. In virtual
    /// mode the unified scroll crosses the history/live seam, so a drag held at the
    /// top edge keeps extending into paged history.
    private func autoScrollTick() {
        guard let event = lastDragEvent, selectionAnchorScreen != nil || virtualSelection != nil else {
            stopAutoScroll()
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        let above = p.y < padV
        let below = p.y > bounds.height - padV
        guard above || below else { stopAutoScroll(); return }

        // Speed ramps with how far past the edge the pointer is held, so long
        // selections don't crawl at one row per tick.
        let edgeDistance = above ? (padV - p.y) : (p.y - (bounds.height - padV))
        let step = Swift.max(1, Swift.min(25, 1 + Int(edgeDistance / 10)))

        // A native drag that hits the sink's top with paged history above it
        // converts to a virtual selection and keeps going across the seam.
        if virtualSelection == nil, above, historyScrollRows == 0,
           sinkAtScrollbackTop(), history.anchor != nil {
            convertNativeSelectionToVirtual()
        }

        if virtualSelection != nil {
            scrollUnified(rows: above ? -step : step)
            let clamped = NSPoint(
                x: min(max(p.x, padH), bounds.width - padH),
                y: min(max(p.y, padV), bounds.height - padV))
            extendVirtualSelection(toPoint: clamped)
            return
        }

        sink.withTerminal { terminal in
            var behavior = GhosttyTerminalScrollViewport()
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
            behavior.value.delta = above ? -step : step
            ghostty_terminal_scroll_viewport(terminal, behavior)
        }
        let (col, row) = gridCoord(for: event)
        extendSelection(toViewportCol: col, row: row)
    }

    /// Convert the in-flight NATIVE drag selection into a virtual one so it can
    /// extend across the seam into history. The stored absolute anchor becomes a
    /// .sink position; the native selection is cleared (the virtual wash takes
    /// over) and history mode begins.
    private func convertNativeSelectionToVirtual() {
        guard let anchor = selectionAnchorScreen else { return }
        sink.withTerminal { terminal in
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
        }
        let pos = UnifiedPos.sink(screenRow: anchor.row, col: anchor.col)
        virtualSelection = VirtualSelection(anchor: pos, head: .sink(screenRow: 0, col: 0))
        selectionAnchorScreen = nil
        if historyScrollRows == 0 {
            enterHistory(rows: 1)
        }
    }

    /// Resolve a viewport cell to an untracked grid ref. Must be called inside
    /// `withTerminal`; the returned ref is only valid until the next mutation.
    private func gridRef(_ terminal: GhosttyTerminal, col: Int, row: Int) -> GhosttyGridRef? {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(max(0, col)), y: UInt32(max(0, row)))
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.stride
        guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { return nil }
        return ref
    }

    /// The parsed history row under a DRAW row, when in history mode.
    private func historyRow(atDrawRow row: Int) -> TermHistoryRow? {
        let hos = histRowsOnScreen
        guard row >= 0, row < hos else { return nil }
        let total = history.totalRows()
        return history.row(at: total - Swift.min(historyScrollRows, total) + row)
    }

    /// Resolve the OSC-8 hyperlink URI under a mouse event, if any. Returns nil when
    /// the cell carries no hyperlink. Skipped while mouse tracking is on (the app owns
    /// the mouse then). History rows resolve from their parse-time link spans;
    /// sink rows read `ghostty_grid_ref_hyperlink_uri` inside the terminal lock.
    func hyperlinkURI(for event: NSEvent) -> String? {
        guard !mouseTrackingEnabled() else { return nil }
        let (col, row) = gridCoord(for: event)
        if row < histRowsOnScreen {
            return historyRow(atDrawRow: row)?.link(at: col)?.uri
        }
        let sinkRow = row - histRowsOnScreen
        var uri: String?
        sink.withTerminal { uri = self.hyperlinkURIAt($0, col: col, row: sinkRow) }
        return uri
    }

    /// Read the OSC-8 hyperlink URI at a viewport cell, or nil when the cell carries
    /// none. Must be called inside `withTerminal`; resolves a fresh ref, probes the
    /// length (NULL buffer → OUT_OF_SPACE with the required size), then reads the URI.
    private func hyperlinkURIAt(_ terminal: GhosttyTerminal, col: Int, row: Int) -> String? {
        guard let resolved = gridRef(terminal, col: col, row: row) else { return nil }
        var ref = resolved
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

    /// Resolve a plain (non-OSC-8) URL under a mouse event, if any. Reads the
    /// clicked viewport row's text from the render state and asks the pure
    /// `TerminalURLDetect` helper for the URL token covering the clicked column.
    /// Skipped while mouse tracking is on (the app owns the mouse then). Runs under
    /// the existing `withTerminal` lock on the same UI/draw path as rendering — no
    /// new locking on the controller feed path.
    func autodetectedURL(for event: NSEvent) -> String? {
        guard !mouseTrackingEnabled() else { return nil }
        var (col, row) = gridCoord(for: event)
        if let hrow = historyRow(atDrawRow: row) {
            guard col >= 0, col < hrow.offsets.count else { return nil }
            return TerminalURLDetect.urlAt(line: hrow.plain, column: hrow.offsets[col])
        }
        row -= histRowsOnScreen
        var result: String?
        sink.withTerminal { [weak self] terminal in
            guard let self, let state = self.renderState else { return }
            guard ghostty_render_state_update(state, terminal) == GHOSTTY_SUCCESS else { return }
            guard var it = self.rowIterator, var cells = self.rowCells else { return }
            ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &it)
            var idx = 0
            while ghostty_render_state_row_iterator_next(it) {
                if idx == row {
                    guard ghostty_render_state_row_get(it, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells) == GHOSTTY_SUCCESS else { return }
                    let (line, offsets) = GhosttyTerminalView.rowLine(cells: cells)
                    guard col >= 0, col < offsets.count else { return }
                    result = TerminalURLDetect.urlAt(line: line, column: offsets[col])
                    return
                }
                idx += 1
            }
        }
        return result
    }

    /// Resolve a filesystem path under a mouse event when the clicked token is an EXISTING
    /// file or directory. Reads the clicked row's text on the same path as `autodetectedURL`,
    /// asks the pure `TerminalPathDetect` for the path token, then resolves it against the
    /// pane's CWD and stats it — only existing paths return non-nil, so a click on ordinary
    /// `a/b` prose with no such file falls through to local selection.
    func autodetectedPath(for event: NSEvent) -> URL? {
        guard !mouseTrackingEnabled() else { return nil }
        var (col, row) = gridCoord(for: event)
        if let hrow = historyRow(atDrawRow: row) {
            guard col >= 0, col < hrow.offsets.count,
                  let path = TerminalPathDetect.pathRangeAt(line: hrow.plain, column: hrow.offsets[col])?.path
            else { return nil }
            return resolveExistingPath(path)
        }
        row -= histRowsOnScreen
        var token: String?
        sink.withTerminal { [weak self] terminal in
            guard let self, let state = self.renderState else { return }
            guard ghostty_render_state_update(state, terminal) == GHOSTTY_SUCCESS else { return }
            guard var it = self.rowIterator, var cells = self.rowCells else { return }
            ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &it)
            var idx = 0
            while ghostty_render_state_row_iterator_next(it) {
                if idx == row {
                    guard ghostty_render_state_row_get(it, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells) == GHOSTTY_SUCCESS else { return }
                    let (line, offsets) = GhosttyTerminalView.rowLine(cells: cells)
                    guard col >= 0, col < offsets.count else { return }
                    token = TerminalPathDetect.pathRangeAt(line: line, column: offsets[col])?.path
                    return
                }
                idx += 1
            }
        }
        guard let token else { return nil }
        return resolveExistingPath(token)
    }

    /// Expand a path token (absolute, `~`, or relative to the pane CWD) to a file URL,
    /// returning it only when something actually exists at that path.
    private func resolveExistingPath(_ token: String) -> URL? {
        let expanded = (token as NSString).expandingTildeInPath
        let path: String
        if expanded.hasPrefix("/") {
            path = expanded
        } else {
            let base = controller.currentCwd ?? FileManager.default.homeDirectoryForCurrentUser.path
            path = (base as NSString).appendingPathComponent(expanded)
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Flatten one render-state row into a plain string plus a per-column table of
    /// UTF-16 offsets into that string. Each `row_cells_next` step is one viewport
    /// column; blank cells contribute a single space so the click column lines up
    /// with the string offset (URLs are spaceless, so their token stays intact).
    /// Wide (multi-column) glyphs can drift the offset by a cell, but URLs are
    /// ASCII so this does not affect detection. Must be called inside `withTerminal`.
    private static func rowLine(cells: GhosttyRenderStateRowCells) -> (line: String, offsets: [Int]) {
        var line = ""
        var offsets: [Int] = []
        var utf16Len = 0
        while ghostty_render_state_row_cells_next(cells) {
            offsets.append(utf16Len)
            var len: UInt32 = 0
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &len)
            var appended = false
            if len > 0 {
                var scalars = [UInt32](repeating: 0, count: Int(len))
                scalars.withUnsafeMutableBufferPointer { buf in
                    _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, buf.baseAddress)
                }
                for v in scalars where v != 0 {
                    if let u = Unicode.Scalar(v) {
                        line.unicodeScalars.append(u)
                        utf16Len += u.value > 0xFFFF ? 2 : 1
                        appended = true
                    }
                }
            }
            if !appended {
                line.append(" ")
                utf16Len += 1
            }
        }
        return (line, offsets)
    }

    /// Map a mouse event to its (col, row) viewport cell, clamped to the grid.
    private func gridCoord(for event: NSEvent) -> (col: Int, row: Int) {
        let p = convert(event.locationInWindow, from: nil)
        let col = Int((p.x - padH) / cellSize.width)
        let row = Int((p.y - padV) / cellSize.height)
        return (min(max(col, 0), max(0, lastCols - 1)), min(max(row, 0), max(0, lastRows - 1)))
    }

    /// Whether the app has any mouse-reporting mode active (so the pointer belongs to the
    /// pty, not local selection). Reads libghostty's aggregate `MOUSE_TRACKING` flag AND
    /// the individual DEC tracking modes directly, then OR's them: a TUI like Claude Code
    /// may enable reporting via X10 (9), normal (1000), button-event (1002), or any-event
    /// (1003), and relying on a single flag risks missing one — which silently drops every
    /// click into the local-selection path (the click "does nothing" for the program). The
    /// SGR/urxvt/utf8 modes (1005/1006/1015/1016) are encodings, not tracking toggles, so
    /// they are NOT consulted here. `GhosttyMode(N)` is the DEC-private packing (ANSI flag
    /// clear), matching the bracketed-paste query in `pasteFromPasteboard`.
    private func mouseTrackingEnabled() -> Bool {
        var aggregate = false
        var x10 = false
        var normal = false
        var button = false
        var any = false
        sink.withTerminal { terminal in
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &aggregate)
            _ = ghostty_terminal_mode_get(terminal, GhosttyMode(9), &x10)
            _ = ghostty_terminal_mode_get(terminal, GhosttyMode(1000), &normal)
            _ = ghostty_terminal_mode_get(terminal, GhosttyMode(1002), &button)
            _ = ghostty_terminal_mode_get(terminal, GhosttyMode(1003), &any)
        }
        return GhosttyTerminalView.mouseReportingActive(
            aggregate: aggregate, x10: x10, normal: normal, button: button, any: any)
    }

    /// Pure "any reporting mode → enabled" decision, factored out of `mouseTrackingEnabled`
    /// so it is unit-testable without a live terminal. Reporting is on when the aggregate
    /// flag OR any individual DEC tracking mode is set.
    static func mouseReportingActive(aggregate: Bool, x10: Bool, normal: Bool, button: Bool, any: Bool) -> Bool {
        aggregate || x10 || normal || button || any
    }

    /// Encode + send a mouse event. `button` is optional so buttonless motion (any-event
    /// mode 1003 hover) can be reported; the encoder suppresses motion in modes that don't
    /// request it, so offering it whenever tracking is on is safe.
    private func send(_ action: GhosttyMouseAction, button: GhosttyMouseButton?, event: NSEvent) {
        guard let data = encodeMouse(action: action, button: button, event: event) else { return }
        controller.sendInput(data)
    }

    /// Encode a mouse event to pty bytes using the terminal's current tracking
    /// mode + format (mouse/encoder.h). Returns nil if the event produces no
    /// output (e.g. tracking disabled or a deduplicated motion).
    private func encodeMouse(action: GhosttyMouseAction, button: GhosttyMouseButton?, event: NSEvent) -> Data? {
        guard let enc = mouseEncoder, let mev = mouseEvent else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let mods = GhosttyTerminalView.mods(event.modifierFlags)

        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.stride
        size.screen_width = UInt32(max(0, bounds.width))
        size.screen_height = UInt32(max(0, bounds.height))
        size.cell_width = UInt32(max(1, cellSize.width.rounded()))
        size.cell_height = UInt32(max(1, cellSize.height.rounded()))
        size.padding_top = UInt32(padV)
        size.padding_bottom = UInt32(padV)
        size.padding_left = UInt32(padH)
        size.padding_right = UInt32(padH)

        var out: Data?
        sink.withTerminal { terminal in
            ghostty_mouse_encoder_setopt_from_terminal(enc, terminal)
            withUnsafePointer(to: &size) { ghostty_mouse_encoder_setopt(enc, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, $0) }
            var pressed = self.mouseButtonDown
            withUnsafePointer(to: &pressed) { ghostty_mouse_encoder_setopt(enc, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, $0) }

            ghostty_mouse_event_set_action(mev, action)
            if let button {
                ghostty_mouse_event_set_button(mev, button)
            } else {
                ghostty_mouse_event_clear_button(mev)
            }
            ghostty_mouse_event_set_mods(mev, mods)
            ghostty_mouse_event_set_position(mev, GhosttyMousePosition(x: Float(local.x), y: Float(local.y)))

            var buf = [CChar](repeating: 0, count: 64)
            var written = 0
            let rc = buf.withUnsafeMutableBufferPointer {
                ghostty_mouse_encoder_encode(enc, mev, $0.baseAddress, $0.count, &written)
            }
            if rc == GHOSTTY_SUCCESS, written > 0 {
                out = buf.withUnsafeBytes { Data($0.prefix(written)) }
            }
        }
        return out
    }

    private static func mods(_ flags: NSEvent.ModifierFlags) -> GhosttyMods {
        var m: GhosttyMods = 0
        if flags.contains(.shift) { m |= GhosttyMods(GHOSTTY_MODS_SHIFT) }
        if flags.contains(.control) { m |= GhosttyMods(GHOSTTY_MODS_CTRL) }
        if flags.contains(.option) { m |= GhosttyMods(GHOSTTY_MODS_ALT) }
        if flags.contains(.command) { m |= GhosttyMods(GHOSTTY_MODS_SUPER) }
        return m
    }

    // MARK: - Pointer shape + Cmd-hover links

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        // mouseMoved feeds Cmd-hover link detection; the pointer SHAPE comes from the
        // cursor rect below. The tracking area auto-enables mouse-moved delivery.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    public override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: currentMouseCursor())
    }

    /// The pointer over the grid: an I-beam for text selection by default; the arrow when
    /// a TUI owns the mouse (it manages its own pointer semantics); the pointing hand when
    /// Cmd-hovering a link (mirrors the Cmd-click-to-open affordance).
    private func currentMouseCursor() -> NSCursor {
        if mouseTrackingEnabled() { return .arrow }
        if hoverLink != nil { return .pointingHand }
        return .iBeam
    }

    public override func mouseMoved(with event: NSEvent) {
        let (col, row) = gridCoord(for: event)
        let sameCell = hoverCell.map { $0.col == col && $0.row == row } ?? false
        hoverCell = (col, row)
        // Buttonless motion (any-event mode 1003): report on cell transitions so a TUI that
        // tracks hover (Claude Code's mouse feedback) sees the pointer move. The encoder
        // suppresses motion for modes that don't request it, so it's safe to always offer
        // when tracking is on; throttling to cell changes keeps this to one report per cell.
        if !sameCell, mouseTrackingEnabled() {
            send(GHOSTTY_MOUSE_ACTION_MOTION, button: nil, event: event)
        }
        if sameCell { return } // throttle: same cell — no hover recompute needed
        updateHoverLink(cmdHeld: event.modifierFlags.contains(.command))
    }

    public override func mouseExited(with event: NSEvent) {
        hoverCell = nil
        setHoverLink(nil)
    }

    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        // Cmd press/release flips the hover affordance over the last hovered cell without
        // needing a fresh mouseMoved.
        updateHoverLink(cmdHeld: event.modifierFlags.contains(.command))
    }

    /// Recompute the Cmd-hover link from the last hovered cell. Does terminal work only
    /// when Cmd is held and a TUI is not consuming the mouse; otherwise clears the link.
    private func updateHoverLink(cmdHeld: Bool) {
        guard cmdHeld, !mouseTrackingEnabled(), let cell = hoverCell else {
            setHoverLink(nil)
            return
        }
        setHoverLink(hoveredLink(col: cell.col, row: cell.row))
    }

    /// Store the hovered link and, when it actually changed, re-evaluate the pointer shape
    /// (I-beam ↔ pointing-hand) and repaint so the underline appears/clears.
    private func setHoverLink(_ link: HoverLink?) {
        if link?.row == hoverLink?.row, link?.cols == hoverLink?.cols { return }
        hoverLink = link
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    /// Resolve the link (OSC-8 first, then an autodetected plain URL) covering a viewport
    /// cell and return its inclusive column range on that row, for the hover underline +
    /// pointer shape. Reads cells under the SAME `withTerminal` lock the draw path uses —
    /// no new locking on the controller feed path (preserves the terminal-query freeze fix).
    private func hoveredLink(col: Int, row: Int) -> HoverLink? {
        // History rows: link spans + URL/path detection from the parsed row.
        if row < histRowsOnScreen {
            guard let hrow = historyRow(atDrawRow: row) else { return nil }
            if let span = hrow.link(at: col) {
                return HoverLink(row: row, cols: span.cols)
            }
            guard col >= 0, col < hrow.offsets.count else { return nil }
            if let (_, range) = TerminalURLDetect.urlRangeAt(line: hrow.plain, column: hrow.offsets[col]),
               let cols = GhosttyTerminalView.columnRange(
                   offsets: hrow.offsets, utf16Lower: range.location, utf16Upper: range.location + range.length) {
                return HoverLink(row: row, cols: cols)
            }
            if let (path, range) = TerminalPathDetect.pathRangeAt(line: hrow.plain, column: hrow.offsets[col]),
               resolveExistingPath(path) != nil,
               let cols = GhosttyTerminalView.columnRange(
                   offsets: hrow.offsets, utf16Lower: range.location, utf16Upper: range.location + range.length) {
                return HoverLink(row: row, cols: cols)
            }
            return nil
        }
        let sinkRow = row - histRowsOnScreen
        var result: HoverLink?
        sink.withTerminal { [weak self] terminal in
            guard let self else { return }
            // OSC-8: walk left/right for the contiguous run sharing the same URI.
            if let uri = self.hyperlinkURIAt(terminal, col: col, row: sinkRow), !uri.isEmpty {
                var lo = col
                var hi = col
                while lo > 0, self.hyperlinkURIAt(terminal, col: lo - 1, row: sinkRow) == uri { lo -= 1 }
                let maxCol = max(0, self.lastCols - 1)
                while hi < maxCol, self.hyperlinkURIAt(terminal, col: hi + 1, row: sinkRow) == uri { hi += 1 }
                result = HoverLink(row: row, cols: lo...hi)
                return
            }
            // Autodetected URL: flatten the hovered row and map the URL's char range back
            // to columns via the offset table.
            guard let state = self.renderState,
                  ghostty_render_state_update(state, terminal) == GHOSTTY_SUCCESS,
                  var it = self.rowIterator, var cells = self.rowCells else { return }
            ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &it)
            var idx = 0
            while ghostty_render_state_row_iterator_next(it) {
                defer { idx += 1 }
                guard idx == sinkRow else { continue }
                guard ghostty_render_state_row_get(it, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells) == GHOSTTY_SUCCESS else { return }
                let (line, offsets) = GhosttyTerminalView.rowLine(cells: cells)
                guard col >= 0, col < offsets.count else { return }
                if let (_, range) = TerminalURLDetect.urlRangeAt(line: line, column: offsets[col]),
                   let cols = GhosttyTerminalView.columnRange(
                       offsets: offsets, utf16Lower: range.location, utf16Upper: range.location + range.length) {
                    result = HoverLink(row: row, cols: cols)
                    return
                }
                // Fall back to an existing-file path token (Cmd-click opens it too).
                if let (path, range) = TerminalPathDetect.pathRangeAt(line: line, column: offsets[col]),
                   self.resolveExistingPath(path) != nil,
                   let cols = GhosttyTerminalView.columnRange(
                       offsets: offsets, utf16Lower: range.location, utf16Upper: range.location + range.length) {
                    result = HoverLink(row: row, cols: cols)
                    return
                }
                return
            }
        }
        return result
    }

    /// Map a UTF-16 character range in a row's flattened string back to the inclusive
    /// viewport column range it covers, via the per-column offset table from `rowLine`.
    /// A column is included when its start offset lies within [lower, upper). Pure so it
    /// is unit-testable (the integration row read is not).
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

    // MARK: - Copy (selection.h format -> NSPasteboard)

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // performKeyEquivalent walks the WHOLE view tree (not the responder chain), so every
        // terminal in the window is offered the event and the FIRST-laid-out pane would grab
        // Cmd-D/M/C/V regardless of focus (splitting the wrong pane). Only the focused
        // (first-responder) terminal should act; others decline so the walk reaches it.
        // The find bar's field editor also counts as "ours" so Cmd-F re-focuses it.
        let findFocused = findBar?.ownsFirstResponder(in: window) ?? false
        guard window?.firstResponder === self || findFocused else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == "f" {
            showFindBar()
            return true
        }
        // While typing in the find field, other Cmd combos (C/V within the field)
        // belong to the field editor, not the terminal.
        if findFocused { return super.performKeyEquivalent(with: event) }
        if flags == .command, event.charactersIgnoringModifiers == "c" {
            return copySelection()
        }
        if flags == .command, event.charactersIgnoringModifiers == "a" {
            selectAll()
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "v" {
            return pasteFromPasteboard()
        }
        if flags == .command, event.charactersIgnoringModifiers == "d" {
            onSplit?(controller.blockId, "horizontal")
            return true
        }
        if flags == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "d" {
            onSplit?(controller.blockId, "vertical")
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "m" {
            onMagnify?(controller.blockId)
            return true
        }
        // Cmd+R = reverse history search: forward ^R to the pty (readline AND
        // libedit bind it, so it works in bash/zsh and psql alike). Consuming it
        // here scopes the mapping to terminals — web panes still get reload from
        // the window-level handler, which only runs after the terminal declines.
        if flags == .command, event.charactersIgnoringModifiers == "r" {
            scrollViewportToBottom()
            controller.sendInput(Data([0x12]))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// First-responder selectors for the native Edit menu (Copy/Paste). The window
    /// consults the terminal's `performKeyEquivalent` before the main menu, so
    /// Cmd-C/Cmd-V are still handled there directly — these only fire when the menu
    /// item is clicked (or its equivalent is reached). Both forward to the same paths.
    @objc func copy(_ sender: Any?) { _ = copySelection() }
    @objc func paste(_ sender: Any?) { _ = pasteFromPasteboard() }

    /// Paste pasteboard text to the pty. Honors bracketed-paste mode (DEC 2004):
    /// when the app enabled it, wrap the text in ESC[200~ … ESC[201~ so the shell
    /// treats it as literal data (no auto-execute on embedded newlines).
    private func pasteFromPasteboard() -> Bool {
        guard let raw = NSPasteboard.general.string(forType: .string), !raw.isEmpty else { return false }
        // Normalize newlines to CR (what a terminal expects from "Enter").
        let text = raw.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        var bracketed = false
        sink.withTerminal { terminal in
            var on = false
            // DEC private mode 2004 (bracketed paste); GhosttyMode encodes the bare
            // value when the ANSI flag is off, so 2004 == GHOSTTY_MODE_BRACKETED_PASTE.
            if ghostty_terminal_mode_get(terminal, GhosttyMode(2004), &on) == GHOSTTY_SUCCESS { bracketed = on }
        }
        var data = Data()
        if bracketed { data.append(contentsOf: [0x1b]); data.append(Data("[200~".utf8)) }
        data.append(Data(text.utf8))
        if bracketed { data.append(contentsOf: [0x1b]); data.append(Data("[201~".utf8)) }
        controller.sendInput(data)
        return true
    }

    /// Copy the active selection's plain text to the pasteboard. Returns false
    /// (event not handled) when there is no selection. A virtual (cross-seam)
    /// selection is assembled from parsed history rows + the sink formatter.
    private func copySelection() -> Bool {
        if fullBufferSelected {
            copyFullBufferAsync()
            return true
        }
        if virtualSelection != nil {
            copyVirtualSelectionAsync()
            return true
        }
        var text: String?
        sink.withTerminal { terminal in
            var opts = GhosttyTerminalSelectionFormatOptions()
            opts.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.stride
            opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
            opts.unwrap = true
            opts.trim = true
            opts.selection = nil
            var ptr: UnsafeMutablePointer<UInt8>?
            var len = 0
            guard ghostty_terminal_selection_format_alloc(terminal, nil, opts, &ptr, &len) == GHOSTTY_SUCCESS,
                  let ptr, len > 0 else { return }
            text = String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
            ghostty_free(nil, ptr, len)
        }
        guard let text, !text.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return true
    }

    // MARK: - Context menu (right-click, Electron term.tsx parity)

    /// Right-click. When the app has mouse tracking on, the right button is part of
    /// the application's own input (e.g. tmux/vim menus), so report it to the pty
    /// instead of popping our menu — same gate the rest of the mouse path uses. With
    /// tracking off, fall through to AppKit's default which builds `menu(for:)`.
    public override func rightMouseDown(with event: NSEvent) {
        if mouseTrackingEnabled() {
            mouseButtonDown = true
            send(GHOSTTY_MOUSE_ACTION_PRESS, button: GHOSTTY_MOUSE_BUTTON_RIGHT, event: event)
            return
        }
        super.rightMouseDown(with: event)
    }

    public override func rightMouseUp(with event: NSEvent) {
        if mouseTrackingEnabled() {
            mouseButtonDown = false
            send(GHOSTTY_MOUSE_ACTION_RELEASE, button: GHOSTTY_MOUSE_BUTTON_RIGHT, event: event)
            return
        }
        super.rightMouseUp(with: event)
    }

    /// Build the terminal content menu. Suppressed while mouse tracking is on (the
    /// right-click was already reported to the pty in `rightMouseDown`). Copy is
    /// enabled only with a live selection; Split/Close appear only when their seam
    /// is wired (the magnify/close closures come from BlockEnv via the composition
    /// root). Parity subset of `frontend/app/view/term/term-model.ts:getContextMenuItems`.
    public override func menu(for event: NSEvent) -> NSMenu? {
        guard !mouseTrackingEnabled() else { return nil }
        let menu = NSMenu()
        // Honor our own `isEnabled` (Copy gating) rather than AppKit auto-enabling
        // every item whose target responds to the action selector.
        menu.autoenablesItems = false

        // Capture the hyperlink under the clicked cell so the "Open Link" items act on
        // it (the menu fires its actions after the event location is gone).
        menuHyperlinkURI = hyperlinkURI(for: event)
        if let uri = menuHyperlinkURI, !uri.isEmpty {
            menu.addItem(selfItem("Open Link", #selector(menuOpenLink)))
            menu.addItem(selfItem("Open Link in Browser", #selector(menuOpenLinkInBrowser)))
            menu.addItem(.separator())
        }

        let copyItem = NSMenuItem(title: "Copy", action: #selector(menuCopy), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = hasSelection()
        menu.addItem(copyItem)

        menu.addItem(selfItem("Paste", #selector(menuPaste)))
        menu.addItem(selfItem("Select All", #selector(menuSelectAll)))
        menu.addItem(selfItem("Clear", #selector(menuClear)))

        menu.addItem(.separator())
        menu.addItem(selfItem("Split Right", #selector(menuSplitRight)))
        menu.addItem(selfItem("Split Down", #selector(menuSplitDown)))

        if onMagnify != nil {
            menu.addItem(.separator())
            menu.addItem(selfItem("Magnify Block", #selector(menuMagnify)))
        }
        if onClose != nil {
            menu.addItem(.separator())
            menu.addItem(selfItem("Close", #selector(menuClose)))
        }
        return menu
    }

    private func selfItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func menuCopy() { _ = copySelection() }
    @objc private func menuPaste() { _ = pasteFromPasteboard() }
    @objc private func menuSelectAll() { selectAll() }
    @objc private func menuClear() { controller.forceRestart() }
    @objc private func menuSplitRight() { onSplit?(controller.blockId, "horizontal") }
    @objc private func menuSplitDown() { onSplit?(controller.blockId, "vertical") }
    @objc private func menuMagnify() { onMagnify?(controller.blockId) }
    @objc private func menuClose() { onClose?(controller.blockId) }

    @objc private func menuOpenLink() {
        guard let uri = menuHyperlinkURI, !uri.isEmpty else { return }
        onOpenWebURL?(controller.blockId, uri)
    }

    @objc private func menuOpenLinkInBrowser() {
        guard let uri = menuHyperlinkURI, let url = URL(string: uri) else { return }
        NSWorkspace.shared.open(url)
    }

    /// First-responder Select All (Edit menu / Cmd-A): select the whole screen
    /// including scrollback by spanning SCREEN(0,0) to SCREEN(cols-1, totalRows-1).
    public override func selectAll(_ sender: Any?) { selectAll() }

    private func selectAll() {
        // With paged on-disk history, Cmd-A means the FULL buffer: wash every
        // stitched row and route Copy through the server-stripped full fetch.
        let snapshot = snapshotSinkTop()
        if history.anchor != nil, history.coverageEndLine > 0 || snapshot.pruned {
            virtualSelection = VirtualSelection(
                anchor: .history(chunk: 0, row: 0, col: 0),
                head: .sink(screenRow: Swift.max(0, snapshot.totalRows - 1), col: Swift.max(0, lastCols - 1)))
            fullBufferSelected = true
            needsDisplay = true
            return
        }
        sink.withTerminal { terminal in
            var cols16: UInt16 = 0
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols16)
            var totalRows = 0
            ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &totalRows)
            guard cols16 > 0, totalRows > 0 else { return }
            guard let start = self.screenRef(terminal, col: 0, row: 0),
                  let end = self.screenRef(terminal, col: Int(cols16) - 1, row: totalRows - 1) else { return }
            var sel = GhosttySelection()
            sel.size = MemoryLayout<GhosttySelection>.stride
            sel.start = start
            sel.end = end
            withUnsafePointer(to: &sel) { _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, $0) }
        }
        needsDisplay = true
    }

    /// Resolve a full-screen (scrollback-inclusive) cell to an untracked grid ref.
    /// Must be called inside `withTerminal`; the ref is valid until the next mutation.
    private func screenRef(_ terminal: GhosttyTerminal, col: Int, row: Int) -> GhosttyGridRef? {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_SCREEN
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(max(0, col)), y: UInt32(max(0, row)))
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.stride
        guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { return nil }
        return ref
    }

    /// Whether the terminal currently has an active selection (Copy enablement).
    private func hasSelection() -> Bool {
        if virtualSelection != nil { return true }
        var has = false
        sink.withTerminal { terminal in
            var sel = GhosttySelection()
            sel.size = MemoryLayout<GhosttySelection>.stride
            has = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &sel) == GHOSTTY_SUCCESS
        }
        return has
    }

    /// Copy the ENTIRE on-disk buffer: streamed + ANSI-stripped server-side,
    /// so it covers every line regardless of which chunks are parsed locally.
    private func copyFullBufferAsync() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let text = try? await self.controller.fetchFullPlainText(), !text.isEmpty else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
        }
    }

    /// Copy a virtual selection: page in any missing chunks first (bounded), so
    /// evicted/unparsed rows are never silently skipped. Selections spanning
    /// more chunks than the bound fall back to whole logical lines via the
    /// server-stripped range fetch (no column clipping -- acceptable at that
    /// scale).
    private func copyVirtualSelectionAsync() {
        guard let sel = virtualSelection else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let (start, end) = sel.ordered
            if case let .history(startChunk, startRow, _) = start {
                let endChunk: Int
                if case let .history(c, _, _) = end {
                    endChunk = c
                } else {
                    endChunk = Swift.max(startChunk, self.history.chunkCount - 1)
                }
                if endChunk - startChunk >= 6 {
                    let startLine = self.history.lineOfRow(self.history.rowIndex(chunk: startChunk, row: startRow)) ?? 0
                    let endLine: Int64
                    if case let .history(c1, r1, _) = end {
                        endLine = self.history.lineOfRow(self.history.rowIndex(chunk: c1, row: r1)) ?? self.history.historyEndLine
                    } else {
                        endLine = self.history.historyEndLine
                    }
                    var text = (try? await self.controller.fetchPlainText(
                        startLine: startLine, numLines: Swift.max(1, endLine - startLine + 1))) ?? ""
                    if case .sink = end, let sinkPart = self.copySinkPart(start: .sink(screenRow: 0, col: 0), end: end) {
                        text += sinkPart
                    }
                    self.setPasteboard(text)
                    return
                }
                for idx in startChunk...endChunk {
                    _ = await self.history.ensureChunk(idx)
                }
            }
            if let text = self.copyVirtualSelection() {
                self.setPasteboard(text)
            }
        }
    }

    private func setPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Assemble the plain text of a virtual (history/sink-spanning) selection:
    /// parsed history rows joined with newlines (soft-wrapped rows join without
    /// one, matching live copy's unwrap), then the sink part via the native
    /// selection formatter. Unparsed (evicted/loading) rows are skipped.
    private func copyVirtualSelection() -> String? {
        guard let sel = virtualSelection else { return nil }
        let (start, end) = sel.ordered
        var out = ""

        if case let .history(startChunk, startRow, startCol) = start {
            let startIdx = history.rowIndex(chunk: startChunk, row: startRow)
            let endIdx: Int
            var endCol = Int.max
            if case let .history(endChunk, endRow, col) = end {
                endIdx = history.rowIndex(chunk: endChunk, row: endRow)
                endCol = col
            } else {
                endIdx = history.totalRows() - 1
            }
            for idx in startIdx...Swift.max(startIdx, endIdx) {
                guard let row = history.row(at: idx) else { continue }
                var lo = 0
                var hi = Int.max
                if idx == startIdx { lo = startCol }
                if idx == endIdx, case .history = end { hi = endCol }
                out += Self.plainSlice(row, fromCol: lo, throughCol: hi)
                if !row.wrapped { out += "\n" }
            }
            if case .history = end {
                // trailing newline only when the last row ended a logical line
                if out.hasSuffix("\n") { out.removeLast() }
                return out
            }
        }

        if case .sink = end {
            if let sinkText = copySinkPart(start: start, end: end) {
                out += sinkText
            }
        }
        return out
    }

    /// Plain text of the sink-side span of a virtual selection (native
    /// formatter, soft-wrap unwrapped). `start` is used only when it is a
    /// .sink position; a .history start means the span begins at SCREEN(0,0).
    private func copySinkPart(start: UnifiedPos, end: UnifiedPos) -> String? {
        guard case let .sink(endRow, endCol) = end else { return nil }
        var startRow = 0
        var startCol = 0
        if case let .sink(r, c) = start {
            startRow = r
            startCol = c
        }
        var sinkText: String?
        sink.withTerminal { terminal in
            guard let s = self.screenRef(terminal, col: startCol, row: startRow),
                  let e = self.screenRef(terminal, col: endCol, row: endRow) else { return }
            var gsel = GhosttySelection()
            gsel.size = MemoryLayout<GhosttySelection>.stride
            gsel.start = s
            gsel.end = e
            withUnsafePointer(to: gsel) { selPtr in
                var opts = GhosttyTerminalSelectionFormatOptions()
                opts.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.stride
                opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
                opts.unwrap = true
                opts.trim = true
                opts.selection = selPtr
                var ptr: UnsafeMutablePointer<UInt8>?
                var len = 0
                if ghostty_terminal_selection_format_alloc(terminal, nil, opts, &ptr, &len) == GHOSTTY_SUCCESS, let ptr {
                    sinkText = String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
                    ghostty_free(nil, ptr, len)
                }
            }
        }
        return sinkText
    }

    /// Column-clipped slice of a history row's plain text (trailing spaces
    /// trimmed), using the per-column UTF-16 offset table for wide glyphs.
    static func plainSlice(_ row: TermHistoryRow, fromCol: Int, throughCol: Int) -> String {
        let utf16 = Array(row.plain.utf16)
        guard !utf16.isEmpty else { return "" }
        let loOff = fromCol < row.offsets.count ? row.offsets[Swift.max(0, fromCol)] : utf16.count
        let hiOff: Int
        if throughCol >= row.offsets.count - 1 {
            hiOff = utf16.count
        } else {
            hiOff = row.offsets[throughCol + 1]
        }
        guard loOff < hiOff else { return "" }
        var text = String(decoding: utf16[loOff..<Swift.min(hiOff, utf16.count)], as: UTF16.self)
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }

    // MARK: - Keyboard input (AppKit -> pty bytes, PROTOCOL §4)

    /// Whether the cursor should render as a filled block. Pure so the
    /// focus-vs-window-key decision is unit-testable without an NSWindow: filled only
    /// when this view holds key focus AND its window is the key window.
    static func cursorIsFilled(hasKeyFocus: Bool, windowIsKey: Bool) -> Bool {
        hasKeyFocus && windowIsKey
    }

    /// Resolve the cursor style to draw: honor the TUI's reported DECSCUSR shape (block /
    /// bar / underline) when the pane is focused, but force the HOLLOW block when unfocused
    /// or the window is not key, so a background pane reads as inactive regardless of shape.
    /// Pure so the shape↔focus rule is unit-testable.
    static func resolvedCursorStyle(
        reported: GhosttyRenderStateCursorVisualStyle,
        filled: Bool
    ) -> GhosttyRenderStateCursorVisualStyle {
        filled ? reported : GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW
    }

    /// Start/stop the cursor blink timer. Cheap to call every frame: a no-op when the
    /// desired state already matches. The timer toggles `cursorBlinkOn` and repaints; it
    /// is torn down (and the cursor forced visible) the moment a blink is no longer wanted.
    private func updateBlinkTimer(active: Bool) {
        if !active {
            cursorBlinkTimer?.invalidate()
            cursorBlinkTimer = nil
            cursorBlinkOn = true
            return
        }
        guard cursorBlinkTimer == nil else { return }
        cursorBlinkOn = true
        // .common mode so the cursor keeps blinking during tracking/scroll run loops.
        let timer = Timer(timeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.cursorBlinkOn.toggle()
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorBlinkTimer = timer
    }

    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool {
        hasKeyFocus = true
        needsDisplay = true // repaint the cursor as a filled block
        return true
    }
    public override func resignFirstResponder() -> Bool {
        hasKeyFocus = false
        needsDisplay = true // repaint the cursor as a hollow outline
        return true
    }

    public override func keyDown(with event: NSEvent) {
        // Cmd shortcuts are chrome concerns (handled in performKeyEquivalent), never pty input.
        if event.modifierFlags.contains(.command) { return }

        // Shift+arrow/page/home/end extends an ACTIVE selection instead of
        // reaching the pty (without a selection they pass through untouched).
        if handleSelectionKey(event) { return }

        // Plain PageUp/PageDown/Home/End scroll the stitched buffer on the
        // PRIMARY screen (macOS Terminal convention); on the alt screen (less/
        // vim/htop) they encode to the pty as usual.
        if handleNavScrollKey(event) { return }

        // Any other keystroke drops the selection (standard terminal behavior).
        if virtualSelection != nil {
            virtualSelection = nil
        }

        // Typing while scrolled up in history snaps the viewport back to the bottom so the
        // user sees their input (and its echo) — standard terminal behavior. Covers every
        // key path below (Ctrl-C, plain text, IME). A no-op when already at the bottom or
        // on the alt screen, so it is safe to call unconditionally on each keystroke.
        scrollViewportToBottom()

        // Control / Meta / navigation / Return-Tab-Backspace-Escape take the DIRECT
        // encoder: routing them through the macOS text-input system would swallow Ctrl-C,
        // break Alt-as-Meta and the CSI cursor encodings. Only ordinary text (incl. dead
        // keys and IME composition) goes through the input context so compose sequences
        // can form — that is the whole point of this path.
        if GhosttyTerminalView.isDirectlyEncodedKey(
            flags: event.modifierFlags,
            scalar: event.charactersIgnoringModifiers?.unicodeScalars.first) {
            if let data = GhosttyTerminalView.bytes(for: event) {
                controller.sendInput(data)
            }
            return
        }

        // Ordinary text: let the input context compose. A dead key sets transient marked
        // text and emits nothing now; the following key calls `insertText` with the final
        // composed glyph (which sets `pendingInputHandled`).
        pendingInputHandled = false
        _ = inputContext?.handleEvent(event)
        if pendingInputHandled {            // committed via insertText — already sent
            hideCursorWhileTyping()
            return
        }
        if hasMarkedText() { return }       // composing (preedit) — nothing to send yet

        // The IME consumed nothing and left no preedit (no input method active), so send
        // the raw characters — plain ASCII must still reach the pty.
        if let data = GhosttyTerminalView.bytes(for: event) {
            controller.sendInput(data)
            hideCursorWhileTyping()
        }
    }

    /// Hide the mouse pointer until the next mouse move (Electron parity: typing dismisses
    /// the pointer so it doesn't sit over the text being entered). AppKit reveals it
    /// automatically on the next movement, so there is no manual show and no interference
    /// with the I-beam/arrow cursor-rect logic. Called only from the text-producing paths
    /// of `keyDown` — never for Cmd shortcuts or navigation/control keys, which don't type.
    private func hideCursorWhileTyping() {
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    /// Whether a key event should bypass the macOS text-input system and use the direct
    /// `bytes(for:)` encoder. Pure (modifier flags + the unmodified scalar) so it stays
    /// unit-testable and consistent with the cases `bytes(for:)` handles. Returns true for
    /// Control / Option-as-Meta, the private-use navigation & function keys, and the C0
    /// controls + DEL (Return, Tab, Escape, Backspace). Everything else is ordinary text
    /// — incl. dead keys, which produce an EMPTY `characters` and must compose via the IME.
    static func isDirectlyEncodedKey(flags: NSEvent.ModifierFlags, scalar: Unicode.Scalar?) -> Bool {
        if flags.contains(.control) || flags.contains(.option) { return true }
        guard let scalar else { return false }
        let v = scalar.value
        // Apple's function-key private-use area: arrows, Home/End, Page, forward-delete,
        // F1…Fn. These must never reach the IME (they'd compose into garbage).
        if v >= 0xF700, v <= 0xF8FF { return true }
        // C0 controls + DEL: Return (\r), Tab (\t), Escape, Backspace.
        if v < 0x20 || v == 0x7f { return true }
        return false
    }

    private static func esc(_ tail: String) -> Data { Data([0x1b]) + Data(tail.utf8) }

    /// xterm modifier code: 1 + Shift(1) + Alt/Option(2) + Control(4).
    static func csiModifier(_ flags: NSEvent.ModifierFlags) -> Int {
        var mod = 1
        if flags.contains(.shift) { mod += 1 }
        if flags.contains(.option) { mod += 2 }
        if flags.contains(.control) { mod += 4 }
        return mod
    }

    /// Cursor/Home/End: `ESC[<final>` unmodified, else `ESC[1;<mod><final>`.
    static func csiCursor(_ final: String, _ mod: Int) -> Data {
        mod == 1 ? esc("[\(final)") : esc("[1;\(mod)\(final)")
    }

    /// Page/Delete: `ESC[<n>~` unmodified, else `ESC[<n>;<mod>~`.
    static func csiTilde(_ n: Int, _ mod: Int) -> Data {
        mod == 1 ? esc("[\(n)~") : esc("[\(n);\(mod)~")
    }

    static func bytes(for event: NSEvent) -> Data? {
        let flags = event.modifierFlags
        // Cmd shortcuts are chrome concerns, not pty input.
        if flags.contains(.command) { return nil }

        // Numpad Enter arrives as ETX (0x03, NSEnterCharacter), which the plain-text
        // fallback would pass through RAW -- i.e. a Ctrl-C to the pty. Treat it as
        // Return everywhere below.
        let isEnterKey = event.charactersIgnoringModifiers == "\r"
            || event.charactersIgnoringModifiers == "\u{3}"

        // Shift+Enter -> LF (\n) instead of the bare Return's \r. TUIs following the Ctrl-J
        // convention (Claude Code — this is what `/terminal-setup` configures for iTerm /
        // Terminal) then INSERT a newline rather than submitting, while a plain Return still
        // submits via \r. Harmless in a shell (the pty maps \n like \r in canonical mode).
        if flags.contains(.shift), !flags.contains(.control), !flags.contains(.option), isEnterKey {
            return Data([0x0a])
        }
        if isEnterKey {
            // Option+Enter keeps its Meta form (ESC CR, e.g. mc); everything else,
            // numpad included, submits like the main Return key.
            if flags.contains(.option) { return esc("\r") }
            return Data([0x0d])
        }

        // Navigation / function keys arrive as private-use unichars. Encode held
        // modifiers using the xterm CSI form (`ESC[1;<mod><final>` for cursor/Home/End,
        // `ESC[<n>;<mod>~` for Page/Delete) so Shift+arrow and Ctrl+arrow work
        // instead of sending a bare arrow.
        if let ignoring = event.charactersIgnoringModifiers, let scalar = ignoring.unicodeScalars.first {
            // Shift+Tab arrives as NSBackTabCharacter (0x19). Passing it raw would
            // send Ctrl-Y — readline's yank, i.e. it "pastes" the kill ring — so
            // encode the xterm backtab CSI Z (what Claude Code etc. expect).
            if scalar.value == 0x19 { return esc("[Z") }
            // Option-only nav chords use the emacs Meta forms, NOT xterm CSI:
            // readline binds both, but libedit (psql on macOS) only understands
            // these — CSI `ESC[1;3D` renders as `;3D` garbage there. Matches
            // Terminal.app/Ghostty (alt+left = ESC b).
            if flags.contains(.option), !flags.contains(.control), !flags.contains(.shift) {
                switch Int(scalar.value) {
                case NSLeftArrowFunctionKey: return esc("b")   // backward-word
                case NSRightArrowFunctionKey: return esc("f")  // forward-word
                case NSHomeFunctionKey: return Data([0x01])    // beginning-of-line (^A)
                case NSEndFunctionKey: return Data([0x05])     // end-of-line (^E)
                default: break
                }
            }
            let mod = csiModifier(flags)
            switch Int(scalar.value) {
            case NSUpArrowFunctionKey: return csiCursor("A", mod)
            case NSDownArrowFunctionKey: return csiCursor("B", mod)
            case NSRightArrowFunctionKey: return csiCursor("C", mod)
            case NSLeftArrowFunctionKey: return csiCursor("D", mod)
            case NSHomeFunctionKey: return csiCursor("H", mod)
            case NSEndFunctionKey: return csiCursor("F", mod)
            case NSPageUpFunctionKey: return csiTilde(5, mod)
            case NSPageDownFunctionKey: return csiTilde(6, mod)
            case NSDeleteFunctionKey: return csiTilde(3, mod)
            case NSInsertFunctionKey: return csiTilde(2, mod)
            default: break
            }

            // Control combinations -> C0 control bytes.
            if flags.contains(.control) {
                let v = scalar.value
                if v >= 0x61, v <= 0x7a { return Data([UInt8(v - 0x60)]) } // ctrl-a..z
                if v >= 0x40, v <= 0x5f { return Data([UInt8(v - 0x40)]) } // ctrl-@.._
                if v == 0x20 { return Data([0]) } // ctrl-space -> NUL
            }
        }

        // Alt/Option as Meta: ESC-prefix the unmodified character.
        if flags.contains(.option), let base = event.charactersIgnoringModifiers, !base.isEmpty {
            return esc(base)
        }

        // Plain text: Return -> \r, Tab -> \t, Backspace -> DEL, Escape -> ESC,
        // and ordinary typed characters all come through `characters`.
        if let text = event.characters, !text.isEmpty {
            return Data(text.utf8)
        }
        return nil
    }
}

// MARK: - NSTextInputClient (dead-key / IME composition)
//
// Conforming makes `inputContext` non-nil so `keyDown` can route ordinary text keys
// through the macOS text-input system. Dead keys (US-International: `'` then `e` → `é`)
// and IMEs compose here and deliver the FINAL text via `insertText`. Preedit is tracked
// logically (not drawn inline in the grid — out of scope) so uncommitted text is never
// forwarded to the pty.
extension GhosttyTerminalView: NSTextInputClient {
    /// Extract a plain String from the `Any` the text system passes (String or
    /// NSAttributedString).
    private static func inputString(_ any: Any) -> String {
        if let s = any as? String { return s }
        if let a = any as? NSAttributedString { return a.string }
        return ""
    }

    /// The composed, committed text (dead-key result / IME commit). Mark the in-flight key
    /// handled so `keyDown` doesn't also fall back to the direct encoder, drop any preedit,
    /// and forward the final bytes to the pty.
    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = GhosttyTerminalView.inputString(string)
        pendingInputHandled = true
        markedText = ""
        guard !text.isEmpty else { return }
        controller.sendInput(Data(text.utf8))
    }

    /// Uncommitted preedit (a dead key, or a multi-key composition in progress). Track it
    /// so it is NOT sent to the pty; a later `setMarkedText`/`insertText`/`unmarkText`
    /// replaces or commits it. We don't render preedit inline, so there's nothing to paint.
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = GhosttyTerminalView.inputString(string)
    }

    public func unmarkText() {
        markedText = ""
    }

    public func hasMarkedText() -> Bool {
        !markedText.isEmpty
    }

    public func markedRange() -> NSRange {
        markedText.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedText.utf16.count)
    }

    public func selectedRange() -> NSRange {
        // No editable document model here, so report "no selection".
        NSRange(location: NSNotFound, length: 0)
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// Best-effort anchor for the IME candidate window: a cell-sized rect near the view's
    /// top-left in screen coordinates. We don't track the cursor's pixel position here
    /// (preedit isn't drawn inline), so this just keeps the candidate panel attached to the
    /// terminal rather than the screen origin.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let viewRect = NSRect(x: padH, y: padV, width: cellSize.width, height: cellSize.height)
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int {
        0
    }

    /// Editing commands (insertNewline:, deleteBackward:, moveLeft:, …) are handled by the
    /// direct encoder path in `keyDown`, so this is intentionally a no-op. Crucially it does
    /// NOT call `super`/`doCommand` in a way that would beep on unhandled selectors.
    public override func doCommand(by selector: Selector) {}
}
#endif
