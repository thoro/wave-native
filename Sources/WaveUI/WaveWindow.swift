// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — the window + root content layout. STYLE.md §6 (emain-window.ts):
//   macOS hiddenInset: frameless full-size-content window with native traffic
//   lights + native rounded corners; body bg #222 opaque; traffic-light inset 74.
//   The 33px tab strip is the title-bar drag area.

import AppKit
import WaveCore

/// Pure mapping of the per-window appearance controls (gear popover) to the AppKit
/// window values, so the alpha/opaque math is unit-testable without a live NSWindow.
///
/// Two independent dimensions, deliberately decoupled (the old model conflated them,
/// which is why nothing visibly worked):
///   • `opacity`  -> `NSWindow.alphaValue` — a UNIFORM whole-window fade that works even
///     though the panes paint opaque content (the previous bg-alpha-only path was a no-op).
///   • `transparent`/`blur` -> a non-opaque window + see-through CONTENT backgrounds so
///     the behind-window blur / desktop shows behind the (still-opaque) text.
public struct WindowAppearance: Equatable, Sendable {
    public var transparent: Bool
    public var blur: Bool
    /// Whole-window opacity, clamped to [minOpacity, 1]; mapped to `NSWindow.alphaValue`.
    public var opacity: Double

    public static let defaultOpacity: Double = 1.0
    public static let minOpacity: Double = 0.3
    /// Background alpha applied to the panes (terminal/frame/root) when the window is
    /// translucent, so the blur/desktop shows through behind the text. Also consumed by
    /// the composition root to dim the terminal's own libghostty background.
    public static let translucentContentAlpha: Double = 0.55

    public init(transparent: Bool, blur: Bool, opacity: Double) {
        self.transparent = transparent
        self.blur = blur
        self.opacity = opacity
    }

    public static func from(_ settings: [String: JSONValue]) -> WindowAppearance {
        let transparent = settings["window:transparent"]?.boolValue ?? false
        let blur = settings["window:blur"]?.boolValue ?? false
        let raw = settings["window:opacity"]?.doubleValue ?? defaultOpacity
        let opacity = Swift.min(1.0, Swift.max(minOpacity, raw))
        return WindowAppearance(transparent: transparent, blur: blur, opacity: opacity)
    }

    /// Whether the window composites with what is behind it (transparency or blur). Both
    /// require a non-opaque window AND see-through content to be visible.
    public var isTranslucent: Bool { transparent || blur }
    /// `NSWindow.isOpaque`.
    public var isOpaque: Bool { !isTranslucent }
    /// `NSWindow.alphaValue` — the uniform whole-window fade (independent of transparency).
    public var windowAlpha: Double { Swift.min(1.0, Swift.max(Self.minOpacity, opacity)) }
    /// Content background alpha: 1 (opaque) unless the window is translucent, when it
    /// drops so the blur/desktop shows behind the panes.
    public var contentBackgroundAlpha: Double { isTranslucent ? Self.translucentContentAlpha : 1.0 }
}

/// A frameless, full-size-content window that keeps the native traffic lights,
/// mirroring Electron's `titleBarStyle: hiddenInset`.
/// Public window probes for the composition root (WaveWindow itself is
/// internal to WaveUI).
public enum WaveWindowInfo {
    /// Whether the window's ACTIVE tab has a background configured (color /
    /// gradient / image). Pane content dims to reveal it.
    public static func hasTabBackground(_ window: NSWindow?) -> Bool {
        (window as? WaveWindow)?.hasTabBackground ?? false
    }
}

final class WaveWindow: NSWindow {
    /// App-global keyboard shortcut handler (wired by `WaveWindowController` to the
    /// `AppCoordinator`). Returns true to consume the event. It is consulted only
    /// AFTER the focused view's own `performKeyEquivalent` declines, so the terminal
    /// keeps its Cmd-C/V/D/M and a rename field keeps its edit keys.
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    /// Consulted BEFORE the responder chain, for the few shortcuts that must never
    /// be swallowed by the focused view: a focused WKWebView claims every ⌘-key
    /// equivalent (it forwards them to the page and returns true), which would trap
    /// ⌘⌥-arrow pane navigation inside a web pane. The handler must consume ONLY
    /// such shortcuts; everything else keeps the "block declines first" ordering.
    var onPreemptKeyEquivalent: ((NSEvent) -> Bool)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false   // dragging is opt-in per view (STYLE §4)
        // NO native drag region at all. On a frameless fullSizeContentView window the
        // window server owns the title-bar drag region and captures the gesture BEFORE
        // the app sees the mouseDown — a tab-pill drag also dragged the whole window
        // (freezing isMovable inside the pill's mouseDown was already too late). With
        // isMovable off permanently, window dragging is provided ONLY by the explicit
        // `DragView` fillers, which run `performDrag(with:)` themselves.
        isMovable = false
        backgroundColor = Theme.windowBackground
        appearance = NSAppearance(named: .darkAqua)
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        minSize = NSSize(width: 600, height: 400)
    }

    // Keep keyboard focus working on a borderless-ish window.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Apply this window's PER-WINDOW appearance (transparency / opacity / blur), driven
    /// live by the gear popover. Cocoa renders the changes immediately; the traffic-light
    /// / full-size-content style is unaffected.
    func applyAppearance(_ appearance: WindowAppearance) {
        // Opacity is a UNIFORM whole-window fade via alphaValue — this is the fix that
        // makes the slider actually do something, even with opaque panes on top.
        alphaValue = CGFloat(appearance.windowAlpha)
        isOpaque = appearance.isOpaque
        let contentAlpha = CGFloat(appearance.contentBackgroundAlpha)
        // A translucent window needs a low-alpha backing so the blur view / desktop shows;
        // an opaque window keeps the solid #222 backing.
        backgroundColor = appearance.isOpaque
            ? Theme.windowBackground
            : Theme.windowBackground.withAlphaComponent(contentAlpha)
        (contentView as? RootContentView)?.applyAppearance(
            backgroundAlpha: contentAlpha, blur: appearance.blur, translucent: appearance.isTranslucent)
    }

    /// Let the responder chain (the focused terminal / text field) consume the event
    /// first, then offer it to the app-global handler. `performKeyEquivalent` bubbles
    /// up to the window only after the focused view declines, which is exactly the
    /// "let the block decline first" ordering Electron uses for Cmd-arrow tab switch.
    /// Whether the ACTIVE tab has a background configured — pane content dims
    /// to reveal it. Read by the composition root when deriving terminal
    /// background alpha (same seam as `isOpaque` for window translucency).
    var hasTabBackground: Bool {
        (contentView as? RootContentView)?.hasTabBackground ?? false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onPreemptKeyEquivalent?(event) == true { return true }
        if super.performKeyEquivalent(with: event) { return true }
        return onKeyEquivalent?(event) ?? false
    }

    /// Double-click on the tab strip (our custom title bar) zooms/minimizes per the user's
    /// "Double-click a window's title bar to…" setting. The strip's drag regions use
    /// `mouseDownCanMoveWindow`, which AppKit consumes for the window drag BEFORE the view
    /// sees mouseDown — so the view can't detect the double-click. `sendEvent` runs first, so
    /// we catch it here, and hit-test to a drag region (not a tab/button, which handle their
    /// own double-click, e.g. inline rename) so only the empty strip triggers it.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, event.clickCount == 2,
           let hit = contentView?.hitTest(event.locationInWindow),
           hit is TabStripBackgroundView || hit is DragView {
            performTitleBarDoubleClickAction()
            return
        }
        super.sendEvent(event)
    }

    private func performTitleBarDoubleClickAction() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": performMiniaturize(nil)
        case "None", "Off": break
        default: performZoom(nil)
        }
    }
}

/// Root content view: tab strip pinned to the top (33px), the tiled content area
/// fills the remainder. Solid #222 (STYLE §6).
final class RootContentView: NSView {
    let tabBar: TabBarView
    let contentArea = NSView()
    /// The right-edge launcher strip. Starts hidden (zero width) until the coordinator
    /// pushes widget items, so an empty config leaves the layout full-width.
    let widgetBar = WidgetBarView()

    /// `top` (horizontal top strip) or `left` (vertical left strip). Driven by the
    /// `app:tabbar` setting via `setTabBarPosition(_:)`.
    private(set) var tabBarPosition: String = TabBarPosition.top

    /// Behind-window blur layer (`window:blur`), installed below the content as the
    /// bottom-most subview so it shows through wherever the chrome is translucent.
    private var blurView: NSVisualEffectView?

    /// The active tab's background (color / gradient / image), rendered as the bottom-most
    /// subview of `contentArea` — behind the panes but above the window chrome. Follows the
    /// active tab via `setTabBackground(_:)`.
    private let tabBackgroundView = TabBackgroundView()
    private var tabBackgroundConfig: TabBackgroundConfig?

    /// This window's active tab, so a pane dropped on the content area resolves to it
    /// (and a drop back into the pane's own tab shows no affordance). Set by the
    /// controller, which owns tab state.
    var activeTabIdProvider: (() -> String?)?
    /// Raised when a dragged pane (block) is dropped on the content area. Carries
    /// (blockId, targetTabId) where the target is this window's active tab.
    var onBlockDrop: ((String, String) -> Void)?
    /// Accent ring shown over the content area while a dragged pane hovers it — the
    /// visible "drop here to move the pane into this tab" affordance.
    private let blockDropHighlight = NSView()

    /// Apply the window background alpha + blur (driven by `WaveWindow.applyAppearance`).
    /// When translucent the root + content-area layers drop their alpha so the blur /
    /// desktop shows through; each pane frame's inner bg is dimmed to match. The terminal
    /// content view's own libghostty background is dimmed by the composition root (which
    /// sees WaveTerminal), so WaveUI stays free of WaveTerminal.
    func applyAppearance(backgroundAlpha: CGFloat, blur: Bool, translucent: Bool) {
        let bg = translucent
            ? Theme.windowBackground.withAlphaComponent(backgroundAlpha)
            : Theme.windowBackground
        currentWindowBg = bg
        layer?.backgroundColor = bg.cgColor
        setBlurEnabled(blur)
        if tabBackgroundConfig != nil {
            applyTabBackgroundToPanes()
        } else {
            contentArea.layer?.backgroundColor = bg.cgColor
            RootContentView.forEachBlockFrame(in: self) {
                $0.setContentBackgroundAlpha(translucent ? backgroundAlpha : 1)
            }
        }
    }

    /// The window background last applied by `applyAppearance` (translucency-aware),
    /// restored to the content area when a tab background is removed.
    private var currentWindowBg: NSColor = Theme.windowBackground

    /// Walk the view tree applying `body` to every `BlockFrameView` (pane frame). Used to
    /// thread the window-translucency alpha into the panes' inner backgrounds.
    static func forEachBlockFrame(in view: NSView, _ body: (BlockFrameView) -> Void) {
        for sub in view.subviews {
            if let frame = sub as? BlockFrameView { body(frame) }
            forEachBlockFrame(in: sub, body)
        }
    }

    private func setBlurEnabled(_ enabled: Bool) {
        if !enabled {
            blurView?.removeFromSuperview()
            blurView = nil
            return
        }
        guard blurView == nil else { return }
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        addSubview(effect, positioned: .below, relativeTo: nil)
        blurView = effect
    }

    /// Apply the `app:tabbar` position: re-orient the tab bar and re-flow the root so the
    /// content area insets to the right of a left strip (or below a top strip).
    func setTabBarPosition(_ position: String) {
        tabBarPosition = position
        tabBar.position = position
        needsLayout = true
    }

    /// Apply the active tab's background. The panes' container (`LayoutTreeView`) paints an
    /// opaque window background, so when a tab background is present the VISIBLE layout
    /// view is made clear to let the background show through the inter-tile gaps and any
    /// translucent panes; with no background it keeps the default opaque fill (preserving
    /// the existing per-window appearance untouched).
    func setTabBackground(_ config: TabBackgroundConfig?) {
        tabBackgroundConfig = config
        tabBackgroundView.config = config
        applyTabBackgroundToPanes()
    }

    /// Whether the active tab currently has a background (color/gradient/image).
    /// Pane content (block frames, terminal backgrounds) dims to reveal it.
    var hasTabBackground: Bool { tabBackgroundConfig != nil }

    /// The active tab's background config (nil when none) — read by a magnified
    /// pane's backdrop so it can reproduce the exact stack behind the pane.
    var currentTabBackgroundConfig: TabBackgroundConfig? { tabBackgroundConfig }

    /// Re-sync each layout view's opacity to the current tab background. Safe to call after
    /// a tab switch (when the visible layout view changes) or after `setTabBackground`.
    func applyTabBackgroundToPanes() {
        let active = tabBackgroundConfig != nil
        let windowOpaque = window?.isOpaque ?? true
        // The content area sits over the root-level background view; it must be
        // clear while a background is active or it would mask everything below
        // the tab bar strip.
        contentArea.layer?.backgroundColor = (active ? NSColor.clear : currentWindowBg).cgColor
        tabBar.setTabBackgroundActive(active)
        widgetBar.setTabBackgroundActive(active)
        for sub in contentArea.subviews {
            guard let layoutView = sub as? LayoutTreeView else { continue }
            let clear = active && !layoutView.isHidden
            layoutView.layer?.backgroundColor = (clear ? NSColor.clear : Theme.windowBackground).cgColor
            // With a tab background the frame fill goes FULLY clear: the terminal's
            // own 0.5 background is the single contrast layer, so pane bodies show
            // the background as strongly as the header instead of stacking two dims
            // into near-black. Window translucency (no tab bg) keeps its softer dim.
            guard !layoutView.isHidden else { continue }
            let contentAlpha: CGFloat = active ? 0 : (windowOpaque ? 1 : CGFloat(WindowAppearance.translucentContentAlpha))
            Self.forEachBlockFrame(in: layoutView) { $0.setContentBackgroundAlpha(contentAlpha) }
        }
    }

    private static func forEachBlockFrame(in view: NSView, depth: Int = 0, _ body: (BlockFrameView) -> Void) {
        guard depth < 6 else { return }
        for sub in view.subviews {
            if let frame = sub as? BlockFrameView {
                body(frame)
            } else {
                forEachBlockFrame(in: sub, depth: depth + 1, body)
            }
        }
    }

    init(tabBar: TabBarView) {
        self.tabBar = tabBar
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.windowBackground.cgColor
        // Round the BOTTOM window corners so the bottom panes' focus border follows the
        // macOS window curve rather than being clipped square by it. The view is flipped,
        // so the visual bottom corners are the layer's maxY corners.
        layer?.cornerRadius = Theme.windowCornerRadius
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer?.masksToBounds = true
        contentArea.wantsLayer = true
        contentArea.layer?.backgroundColor = Theme.windowBackground.cgColor
        // The content area is a SEPARATE opaque layer that hosts the panes reaching the
        // window's bottom corners; relying on RootContentView's mask alone left a square
        // black wedge poking past the window curve at the bottom-left. Clip its bottom
        // corners here too. contentArea is NOT flipped (a plain NSView), so its visual-bottom
        // corners are the layer's MIN-Y corners (unlike RootContentView, which is flipped).
        contentArea.layer?.cornerRadius = Theme.windowCornerRadius
        contentArea.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        contentArea.layer?.masksToBounds = true
        // The tab background colors the WHOLE window chrome (tab bar strip
        // included), matching Electron's app-root background — so it lives on
        // the root, beneath the content area / bars; layout() keeps it full-size.
        tabBackgroundView.frame = bounds
        addSubview(tabBackgroundView)
        blockDropHighlight.wantsLayer = true
        blockDropHighlight.layer?.borderColor = Theme.accent.cgColor
        blockDropHighlight.layer?.borderWidth = 2
        blockDropHighlight.layer?.cornerRadius = Theme.windowCornerRadius
        blockDropHighlight.isHidden = true
        widgetBar.isHidden = true
        addSubview(contentArea)
        addSubview(widgetBar)
        addSubview(tabBar)
        // Raise-on-hover for cross-window tab AND pane drags: dragging over ANY part of
        // a background window brings it forward (after a short spring delay), so its
        // strip becomes reachable as a drop target. The tab bar itself raises immediately.
        registerForDraggedTypes([TabDragPayload.tabIdType, BlockDragPayload.blockIdType])
    }

    /// Spring-load timer for raise-on-hover during a tab drag (see `draggingEntered`).
    private var raiseTimer: Timer?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        armRaiseIfBackground(sender)
        // Tabs have no content-area drop target (the strip, a deeper registered view,
        // handles them); a dragged PANE can drop anywhere on the content.
        return updateBlockDrag(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateBlockDrag(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        raiseTimer?.invalidate()
        raiseTimer = nil
        setBlockDropHighlight(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        raiseTimer?.invalidate()
        raiseTimer = nil
        setBlockDropHighlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setBlockDropHighlight(false)
        let pb = sender.draggingPasteboard
        let sourceTabId = pb.string(forType: BlockDragPayload.tabIdType) ?? ""
        guard let blockId = pb.string(forType: BlockDragPayload.blockIdType),
              let activeTabId = activeTabIdProvider?(), activeTabId != sourceTabId else {
            dndLog("root performDrag: not a block drop (or same-tab)")
            return false
        }
        dndLog("root performBlockDrop block=\(blockId.suffix(4)) destTab=\(activeTabId.suffix(4))")
        // Leave THIS window active after the drop (mirror the strip's drop path): the
        // raise-on-hover only ordered it front, so the source window would still be key.
        window?.makeKeyAndOrderFront(nil)
        onBlockDrop?(blockId, activeTabId)
        return true
    }

    /// Raise-on-hover: dragging over a BACKGROUND window brings it forward after a
    /// short spring delay, so its strip/content become reachable as drop targets.
    private func armRaiseIfBackground(_ sender: NSDraggingInfo) {
        let pb = sender.draggingPasteboard
        guard pb.string(forType: TabDragPayload.tabIdType) != nil
                || pb.string(forType: BlockDragPayload.blockIdType) != nil,
              let window, window.isVisible, NSApp.orderedWindows.first !== window else { return }
        dndLog("root draggingEntered — arming raise for window \(window.windowNumber)")
        raiseTimer?.invalidate()
        raiseTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak window] _ in
            dndLog("root raising window \(window?.windowNumber ?? -1)")
            window?.orderFront(nil)
        }
    }

    /// A dragged pane hovering the content area targets this window's ACTIVE tab (a
    /// specific background tab is targeted via its pill instead). Back into its own
    /// tab is a no-op, so it gets no affordance.
    private func updateBlockDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        guard pb.string(forType: BlockDragPayload.blockIdType) != nil,
              let activeTabId = activeTabIdProvider?(),
              activeTabId != (pb.string(forType: BlockDragPayload.tabIdType) ?? "") else {
            setBlockDropHighlight(false)
            return []
        }
        setBlockDropHighlight(true)
        return .move
    }

    /// Show/hide the content-area drop ring. Re-added on show so it stays above the
    /// layout views (which are added to `contentArea` after init, on every tab load).
    private func setBlockDropHighlight(_ on: Bool) {
        if on {
            blockDropHighlight.frame = contentArea.bounds
            contentArea.addSubview(blockDropHighlight, positioned: .above, relativeTo: nil)
        }
        blockDropHighlight.isHidden = !on
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        tabBackgroundView.frame = bounds
        // Inset the content area by the bar width so the tiling tree (splitters / drag
        // math, which read contentArea.bounds) reflows to the narrower region rather
        // than rendering under the strip.
        let w = widgetBar.isHidden ? 0 : Theme.widgetBarWidth

        if tabBarPosition == TabBarPosition.left {
            // Vertical left strip: tab bar owns the left edge, content sits between it and
            // the widget bar (which keeps the right edge), both at full height.
            let lw = Theme.tabBarLeftWidth
            tabBar.frame = CGRect(x: 0, y: 0, width: lw, height: bounds.height)
            widgetBar.frame = CGRect(x: bounds.width - w, y: 0, width: w, height: bounds.height)
            contentArea.frame = CGRect(
                x: lw, y: 0, width: max(bounds.width - lw - w, 0), height: bounds.height)
            return
        }

        let h = Theme.tabBarHeight
        tabBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        widgetBar.frame = CGRect(x: bounds.width - w, y: h, width: w, height: max(bounds.height - h, 0))
        contentArea.frame = CGRect(x: 0, y: h, width: max(bounds.width - w, 0), height: max(bounds.height - h, 0))
    }
}
