// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — block frame chrome. Implements STYLE.md §5 (block.scss):
//   container radius 8, inner bg rgba(0,0,0,0.5), header height 30 with bottom
//   border rgba(255,255,255,0.16), Inter 11/700 title; focused block = 2px solid
//   accent (#58c142) overlay border at radius 8.
//
// Loads the block object via the store (PROTOCOL §2), reads `meta.view`
// (`metaconsts.go:9`) and asks the injected `BlockViewProvider` for content
// (PROTOCOL §4/§5). Subscribes to the block's store entry so the title/view stay
// live (GUARDS §B is honored by the store; this view just re-reads on change).

import AppKit
import WaveCore

/// A plain container that is flipped (top-left origin). Used for the block's inner
/// chrome so its sublayers anchor to the TOP during pane frame animations (see
/// `BlockFrameView.isFlipped`).
final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}

/// Hosts one block: header + content, with a focus-state border overlay.
final class BlockFrameView: NSView {
    let blockRef: ORef
    private let env: BlockEnv
    private let provider: BlockViewProvider

    private let innerView = FlippedContainerView()
    private let headerView = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let iconField = NSImageView()
    /// `wsh badge` marker between the icon and the title (Electron blockframe-header).
    private let badgeView = BadgeIndicatorView(pointSize: 11)
    private var titleLeadingDefault: NSLayoutConstraint?
    private var titleLeadingAfterBadge: NSLayoutConstraint?
    private var badgeToken: SubscriptionToken?
    private var isWebHeader = false
    /// Compact `display:name` label for WEB panes (which replace the title with the
    /// nav chrome); zero-width when the pane has no name.
    private let webNameField = NSTextField(labelWithString: "")
    /// The pane's `display:name` meta (nil when unset) — overrides the derived
    /// title for terminal/generic panes and fills `webNameField` for web panes.
    private var currentDisplayName: String?
    /// Inline editor for "Rename Pane" (nil while not renaming).
    private var renameEditor: NSTextField?
    private var webNavLeadingDefault: NSLayoutConstraint?
    private var webNavLeadingAfterName: NSLayoutConstraint?
    private let magnifyButton = MagnifyButton()
    // Per-pane header buttons (Electron parity: each block header carries its own
    // magnify, settings/menu, and close buttons on the right — not a window-level gear).
    private let settingsButton = ChromeIconButton(symbol: "ellipsis", pointSize: 12)
    private let closeButton = ChromeIconButton(symbol: "xmark", pointSize: 11)
    private let borderOverlay = PointerTransparentView()

    // Web nav chrome (address bar + back/forward/reload), shown only for `view:"web"`
    // blocks. Driven through `env.webNav` (the WaveUI<->WaveWeb bridge) so this module
    // never imports WaveWeb.
    private let webNavBar = WebNavBar()

    private var isMagnifiedState = false
    private var contentView: NSView?
    private var currentViewType: String?

    // Connection state (terminal blocks only). `connClickTarget` makes the header
    // icon+title region open the connection picker; `connOverlay` reflects the
    // connecting/error status over the content.
    private let connClickTarget = HeaderClickTarget()
    private var connOverlay: ConnStatusOverlayView?
    private var currentConnName: String?
    private var isTerminalBlock = false
    private var connToken: SubscriptionToken?

    private var storeToken: SubscriptionToken?

    /// Node id of this leaf (so focus can be matched to `LayoutState.focusednodeid`).
    let nodeId: String

    var isFocused: Bool = false {
        didSet { if oldValue != isFocused { updateFocusBorder() } }
    }

    /// Called when the user clicks anywhere in the block (to request focus).
    var onRequestFocus: ((String) -> Void)?

    /// Called when the user presses down on the header (the drag handle). Carries the
    /// leaf `nodeId` and the originating event so the owning `LayoutTreeView` can run a
    /// drag-to-rearrange tracking loop in its own coordinate space.
    var onHeaderDrag: ((String, NSEvent) -> Void)?

    /// Called when the header magnify/minimize button is clicked. Carries the leaf
    /// `nodeId` so the tree view can dispatch `.magnifyNodeToggle`.
    var onToggleMagnify: ((String) -> Void)?

    /// Fired after the content view actually (re)mounts. A fresh split pane's
    /// terminal streams in async via `bindStore`, AFTER the one-shot deferred
    /// `focusActiveBlock()` has already run — this lets the owner re-claim focus for
    /// the focused pane once its content lands (focus-follows-split).
    var onContentMounted: (() -> Void)?

    /// Whether magnify is offered (only meaningful with >1 pane). Hides the button
    /// when false (a single-pane tab has nothing to magnify).
    var canMagnify: Bool = false {
        didSet { if oldValue != canMagnify { updateMagnifyButton() } }
    }

    /// The buttons shown on the right of a block header. Settings + close are always
    /// present; magnify only when the tab has more than one pane (`canMagnify`).
    enum HeaderButton: String, Equatable {
        case magnify, settings, close
    }

    /// Pure mapping of header chrome state → the button set, so the per-view-type header
    /// layout is unit-testable without AppKit.
    static func headerButtons(canMagnify: Bool) -> [HeaderButton] {
        var buttons: [HeaderButton] = []
        if canMagnify { buttons.append(.magnify) }
        buttons.append(.settings)
        buttons.append(.close)
        return buttons
    }

    /// What the header's content region shows for a given `meta.view`. Web blocks get
    /// the address-bar nav chrome; terminals get the connection label; everything else
    /// gets a plain title. Pure so the per-view-type selection is unit-testable.
    enum HeaderMode: String, Equatable {
        case terminal, web, generic
    }

    static func headerMode(forView view: String?) -> HeaderMode {
        switch view {
        case "term": return .terminal
        case "web": return .web
        default: return .generic
        }
    }

    /// Stable identifiers for the per-block settings menu, in display order. Submenu
    /// PARENTS (`clearOnRestart`, `runOnStartup`, `debugConnection`, `userAgentType`,
    /// `zoom`) are one id each; the AppKit builder attaches their checkbox children.
    /// Kept separate from NSMenu construction so the per-view-type item set is a pure,
    /// AppKit-free unit test (mirrors Electron's `getSettingsMenuItems` shape).
    enum BlockMenuItemID: String, Equatable {
        case magnify, minimize, separator
        case splitRight, splitDown
        case copy, paste, selectAll
        case themes
        case forceRestart, termClearBuffer, resetTerminal, clearOnRestart, runOnStartup, debugConnection
        case reload, copyURL, openExternal, setBlockHomepage
        case hideNav, unhideNav, userAgentType, zoom
        case renamePane, copyBlockId, copyLink, close
    }

    /// The ordered menu-item ids for a block, by view type + chrome state. Structure
    /// mirrors Electron (`blockframe-header.tsx`): a common magnify/split prefix, a
    /// VIEW-SPECIFIC section (the per-view `getSettingsMenuItems`), then a common
    /// Copy-BlockId + Close suffix. Pure: no AppKit, no I/O.
    static func blockMenuItems(
        view: HeaderMode, canMagnify: Bool, isMagnified: Bool, isNavHidden: Bool
    ) -> [BlockMenuItemID] {
        var items: [BlockMenuItemID] = []
        if canMagnify {
            items.append(isMagnified ? .minimize : .magnify)
            items.append(.separator)
        }
        items.append(.splitRight)
        items.append(.splitDown)
        items.append(contentsOf: viewSpecificMenuItems(view: view, isNavHidden: isNavHidden))
        items.append(.separator)
        items.append(.renamePane)
        items.append(.copyBlockId)
        items.append(.copyLink)
        items.append(.separator)
        items.append(.close)
        return items
    }

    private static func viewSpecificMenuItems(view: HeaderMode, isNavHidden: Bool) -> [BlockMenuItemID] {
        switch view {
        case .terminal:
            // Themes is live (per-pane `term:theme` → palette re-render). TODO(defer):
            // Font Size, Cursor, Transparency, Allow Bracketed Paste, File Browser, Save
            // Session As…, Session Durability, Close Toolbar — those need features the
            // native Ghostty view lacks; only the backend-honored setMeta items + the
            // live Themes submenu are built here.
            return [.separator, .themes,
                    .separator, .copy, .paste, .selectAll,
                    .separator, .forceRestart, .termClearBuffer, .resetTerminal, .clearOnRestart, .runOnStartup, .debugConnection]
        case .web:
            // TODO(defer): Open/Close DevTools, Clear History, Clear Cookies and Storage,
            // and the GLOBAL "Set Default Homepage" — these need WKWebsiteDataStore / Web
            // Inspector / SetConfig seams not present natively.
            return [.separator, .reload, .copyURL, .openExternal, .setBlockHomepage,
                    .separator, isNavHidden ? .unhideNav : .hideNav, .userAgentType, .zoom]
        case .generic:
            return []
        }
    }

    init(nodeId: String, env: BlockEnv, provider: BlockViewProvider) {
        self.nodeId = nodeId
        self.blockRef = env.blockRef
        self.env = env
        self.provider = provider
        super.init(frame: .zero)
        wantsLayer = true
        setupChrome()
        bindStore()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Flipped (with the flipped `innerView`) so the chrome + content are TOP-anchored in
    /// layer geometry. During a split/close frame animation the content's layout is applied
    /// at the FINAL geometry immediately; only top-anchored sublayers stay glued to the
    /// pane's top edge while the height animates. Unflipped (bottom-anchored) panes made the
    /// content hang off the moving bottom edge — on a vertical split the original pane's
    /// content visibly jumped down and rode back up, and the new pane's header/border stayed
    /// clipped out until the grow finished (reading as "no animation at all").
    override var isFlipped: Bool { true }

    deinit { storeToken?.cancel(); connToken?.cancel(); badgeToken?.cancel() }

    /// Dim the pane's inner background so a translucent window shows the blur/desktop
    /// behind it. Driven by `RootContentView.applyAppearance`; 1 restores the solid bg.
    func setContentBackgroundAlpha(_ alpha: CGFloat) {
        innerView.layer?.backgroundColor = Theme.blockBg.withAlphaComponent(alpha).cgColor
        updateMagnifyBackdrop()
    }

    /// Seed the inner-bg alpha from the (possibly translucent) window a fresh pane lands
    /// in, so a split/new tab created while the window is transparent matches immediately.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if (window as? WaveWindow)?.hasTabBackground == true {
            setContentBackgroundAlpha(0)
        } else {
            setContentBackgroundAlpha(window.isOpaque ? 1 : CGFloat(WindowAppearance.translucentContentAlpha))
        }
    }

    // MARK: Setup

    private func setupChrome() {
        // Outer container: 1px padding, 8px radius (STYLE §5).
        innerView.wantsLayer = true
        innerView.layer?.cornerRadius = Theme.radiusLarge
        innerView.layer?.masksToBounds = true
        innerView.layer?.backgroundColor = Theme.blockBg.cgColor
        innerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(innerView)

        headerView.wantsLayer = true
        headerView.translatesAutoresizingMaskIntoConstraints = false
        innerView.addSubview(headerView)

        // Header bottom border.
        let headerBorder = NSView()
        headerBorder.wantsLayer = true
        headerBorder.layer?.backgroundColor = Theme.border.cgColor
        headerBorder.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(headerBorder)

        iconField.imageScaling = .scaleProportionallyDown
        iconField.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        iconField.contentTintColor = Theme.textSecondary.withAlphaComponent(0.5)
        iconField.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(iconField)

        badgeView.isHidden = true
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(badgeView)

        titleField.font = Theme.headerFont
        titleField.textColor = Theme.textPrimary.withAlphaComponent(0.7)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(titleField)

        webNameField.font = Theme.headerFont
        webNameField.textColor = Theme.textPrimary.withAlphaComponent(0.7)
        webNameField.lineBreakMode = .byTruncatingTail
        webNameField.isHidden = true
        webNameField.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(webNameField)

        // Clickable connection target over the icon+title region (Electron's
        // ConnectionButton): opens the typeahead picker. Hidden/disabled for
        // non-terminal blocks (which have no connection). Sits above the labels so it
        // receives the click instead of the header's drag handler.
        connClickTarget.isHidden = true
        connClickTarget.onClick = { [weak self] in
            guard let self else { return }
            self.onRequestFocus?(self.nodeId)
            self.env.onPickConnection?(self.blockRef.oid)
        }
        connClickTarget.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(connClickTarget)

        // Magnify / minimize button (Electron's OptMagnifyButton / MagnifyIcon): two
        // diagonal arrows that flip inward<->outward on the magnified state. Hidden on
        // a single-pane tab.
        magnifyButton.isHidden = true
        magnifyButton.onClick = { [weak self] in
            guard let self else { return }
            self.onToggleMagnify?(self.nodeId)
        }
        magnifyButton.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(magnifyButton)
        updateMagnifyButton()

        // Settings/menu button: opens the same per-block menu as the header right-click.
        settingsButton.toolTip = "Block Menu"
        settingsButton.onTap = { [weak self] in self?.showBlockMenu() }
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(settingsButton)

        // Close button: reuses the existing onClose seam (closes the pane, or the tab
        // when it is the last pane).
        closeButton.toolTip = "Close Block"
        closeButton.onTap = { [weak self] in
            guard let self else { return }
            self.env.onClose?(self.blockRef.oid)
        }
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(closeButton)

        // Web nav bar (address bar + back/forward/reload). Hidden until a web block
        // mounts. Its actions/url flow through `env.webNav` — the provider wires that
        // bridge to the live WebBlockView, so this module stays free of WaveWeb.
        webNavBar.isHidden = true
        webNavBar.onBack = { [weak self] in self?.env.webNav.goBack?() }
        webNavBar.onForward = { [weak self] in self?.env.webNav.goForward?() }
        webNavBar.onReload = { [weak self] in self?.env.webNav.reload?() }
        webNavBar.onSubmit = { [weak self] raw in self?.env.webNav.load?(raw) }
        webNavBar.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(webNavBar)
        env.webNav.onURLChange = { [weak self] url in
            self?.webNavBar.urlString = url ?? ""
        }

        // Focus border overlay (2px accent), drawn on top, non-interactive.
        borderOverlay.wantsLayer = true
        borderOverlay.layer?.cornerRadius = Theme.radiusLarge
        borderOverlay.layer?.borderWidth = Theme.focusedBlockBorderWidth
        borderOverlay.layer?.borderColor = NSColor.clear.cgColor
        borderOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(borderOverlay)

        NSLayoutConstraint.activate([
            innerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            innerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            innerView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            innerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),

            borderOverlay.leadingAnchor.constraint(equalTo: innerView.leadingAnchor),
            borderOverlay.trailingAnchor.constraint(equalTo: innerView.trailingAnchor),
            borderOverlay.topAnchor.constraint(equalTo: innerView.topAnchor),
            borderOverlay.bottomAnchor.constraint(equalTo: innerView.bottomAnchor),

            headerView.leadingAnchor.constraint(equalTo: innerView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: innerView.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: innerView.topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: Theme.blockHeaderHeight),

            headerBorder.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            headerBorder.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            headerBorder.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
            headerBorder.heightAnchor.constraint(equalToConstant: 1),

            // header padding 4px 5px 4px 7px, gap 8.
            iconField.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 7),
            iconField.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            iconField.widthAnchor.constraint(equalToConstant: 16),

            badgeView.leadingAnchor.constraint(equalTo: iconField.trailingAnchor, constant: Theme.headerGap),
            badgeView.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            titleField.trailingAnchor.constraint(lessThanOrEqualTo: magnifyButton.leadingAnchor, constant: -5),
            titleField.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            connClickTarget.leadingAnchor.constraint(equalTo: iconField.leadingAnchor, constant: -2),
            connClickTarget.trailingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 2),
            connClickTarget.topAnchor.constraint(equalTo: headerView.topAnchor),
            connClickTarget.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),

            // Right-aligned button group: magnify, settings, close (left → right).
            closeButton.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            closeButton.heightAnchor.constraint(equalToConstant: 18),

            settingsButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor),
            settingsButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            settingsButton.heightAnchor.constraint(equalToConstant: 18),

            magnifyButton.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -2),
            magnifyButton.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            magnifyButton.widthAnchor.constraint(equalToConstant: 18),
            magnifyButton.heightAnchor.constraint(equalToConstant: 18),

            // The web nav bar fills the same region as the title (icon → button group).
            // Active even while hidden — only one of {title, nav bar} is visible at a
            // time, and the title uses a non-required trailing relation so neither
            // constraint conflicts with the other.
            webNavBar.trailingAnchor.constraint(equalTo: magnifyButton.leadingAnchor, constant: -5),
            webNavBar.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 3),
            webNavBar.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -3),

            // The compact web-pane name sits between the icon and the nav chrome
            // (visible only when the pane has a `display:name`).
            webNameField.leadingAnchor.constraint(equalTo: iconField.trailingAnchor, constant: Theme.headerGap),
            webNameField.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            webNameField.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
        ])
        // The nav bar's leading swaps between "right after the icon" (unnamed pane)
        // and "after the name label" (named pane); applyBlock activates one of them.
        webNavLeadingDefault = webNavBar.leadingAnchor.constraint(
            equalTo: iconField.trailingAnchor, constant: Theme.headerGap)
        webNavLeadingAfterName = webNavBar.leadingAnchor.constraint(
            equalTo: webNameField.trailingAnchor, constant: Theme.headerGap)
        webNavLeadingDefault?.isActive = true
        titleLeadingDefault = titleField.leadingAnchor.constraint(
            equalTo: iconField.trailingAnchor, constant: Theme.headerGap)
        titleLeadingAfterBadge = titleField.leadingAnchor.constraint(
            equalTo: badgeView.trailingAnchor, constant: Theme.headerGap)
        titleLeadingDefault?.isActive = true
    }

    private func mountContent(viewType: String?) {
        // Only rebuild content if the view type actually changed.
        if contentView != nil && currentViewType == viewType { return }
        contentView?.removeFromSuperview()
        currentViewType = viewType
        let content = provider.makeContentView(view: viewType, env: env)
        content.translatesAutoresizingMaskIntoConstraints = false
        innerView.addSubview(content, positioned: .below, relativeTo: headerView)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: innerView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: innerView.trailingAnchor),
            content.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: innerView.bottomAnchor),
        ])
        contentView = content
        onContentMounted?()
    }

    // MARK: Store binding

    private func bindStore() {
        // Reflect whatever is already cached, then subscribe for live changes.
        applyBlock(env.store.get(blockRef)?.asBlock)
        // The store handler is @Sendable; capture only the Sendable `block` and
        // hop to main before touching this (non-Sendable) view.
        storeToken = env.store.subscribe(blockRef) { obj in
            let block = obj?.asBlock
            DispatchQueue.main.async { [weak self] in self?.applyBlock(block) }
        }
        // Trigger a load if it isn't cached yet.
        if env.store.get(blockRef) == nil {
            let store = env.store
            let ref = blockRef
            Task.detached { _ = try? await store.load(ref) }
        }
        // Live connection status: re-render the header tint + overlay when the store
        // changes (seeded by connstatus, kept current by connchange). Captures only
        // the Sendable closure; hops to main to touch this view.
        connToken = env.connections?.subscribe { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.refreshConnectionState() }
        }
        badgeToken = env.badges?.subscribe { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.refreshBadge() }
        }
    }

    private func applyBlock(_ block: Block?) {
        let viewType = block?.view
        let mode = Self.headerMode(forView: viewType)
        isTerminalBlock = (mode == .terminal)
        let isWebBlock = (mode == .web)
        currentDisplayName = block?.meta[BlockMeta.displayName]?.stringValue.flatMap {
            $0.isEmpty ? nil : $0
        }

        // The web nav bar replaces the title for web blocks; show it only then. A
        // named web pane additionally shows its compact `display:name` label
        // between the icon and the nav chrome.
        webNavBar.isHidden = !isWebBlock
        titleField.isHidden = isWebBlock
        isWebHeader = isWebBlock
        refreshBadge()
        webNameField.stringValue = isWebBlock ? (currentDisplayName ?? "") : ""
        webNameField.isHidden = !isWebBlock || currentDisplayName == nil
        let named = isWebBlock && currentDisplayName != nil
        webNavLeadingDefault?.isActive = false
        webNavLeadingAfterName?.isActive = false
        (named ? webNavLeadingAfterName : webNavLeadingDefault)?.isActive = true
        if isWebBlock {
            webNavBar.urlString = env.webNav.currentURL ?? ""
        }

        // Terminal blocks title from their CONNECTION (Electron's ConnectionButton):
        // local → the local display name, remote → "user@host". Other view types keep
        // their generic title (controller/title/view) and no connection affordance.
        // A `display:name` (Rename Pane) overrides the derived title in both cases.
        if isTerminalBlock {
            currentConnName = block?.meta[ConnectionLabel.metaKey]?.stringValue
            connClickTarget.isHidden = (env.onPickConnection == nil)
            refreshConnectionState()
        } else {
            currentConnName = nil
            connClickTarget.isHidden = true
            removeConnOverlay()
            let title = currentDisplayName
                ?? block?.meta["controller"]?.stringValue
                ?? block?.meta[BlockMeta.frameTitle]?.stringValue
                ?? block?.meta["title"]?.stringValue
                ?? viewType
                ?? "block"
            titleField.stringValue = title
            iconField.image = Self.icon(forView: viewType)
            iconField.contentTintColor = Theme.textSecondary.withAlphaComponent(0.5)
        }
        mountContent(viewType: viewType)
    }

    /// Show this block's badge next to the title. Web headers have no title slot (the
    /// nav bar fills it), so they show only the tab-pill badge.
    private func refreshBadge() {
        let badge = isWebHeader ? nil : env.badges?.blockBadge(blockRef.oid)
        badgeView.badges = badge.map { [$0] } ?? []
        titleLeadingDefault?.isActive = false
        titleLeadingAfterBadge?.isActive = false
        (badge == nil ? titleLeadingDefault : titleLeadingAfterBadge)?.isActive = true
    }

    /// Re-derive the terminal header's connection title/icon/tint from the current
    /// `connection` meta + the live `ConnectionStore`, and update the connect overlay.
    private func refreshConnectionState() {
        guard isTerminalBlock else { return }
        let localName = env.connections?.localDisplayName ?? ConnectionLabel.defaultLocalDisplayName()
        let derived = ConnectionLabel.derive(connection: currentConnName, localDisplayName: localName)
        // Rename Pane wins over the connection label; the connection icon + tint keep
        // showing where the shell runs, and the tooltip preserves the full conn title.
        titleField.stringValue = currentDisplayName ?? derived.title
        iconField.image = Self.symbol(derived.icon)

        let status = currentConnName.flatMap { env.connections?.status(for: $0) }
        iconField.contentTintColor = Self.iconTint(isLocal: derived.isLocal, status: status)
        titleField.toolTip = derived.title
        updateConnOverlay(connName: currentConnName, isLocal: derived.isLocal, status: status)
    }

    /// Header icon tint by connection status (mirrors Electron's ConnectionButton
    /// colour cases). Local is always the muted secondary colour.
    private static func iconTint(isLocal: Bool, status: ConnStatus?) -> NSColor {
        if isLocal { return Theme.textSecondary }
        switch status?.status {
        case ConnStatusValue.connecting: return Theme.warning
        case ConnStatusValue.error: return Theme.error
        case ConnStatusValue.connected: return Theme.accent
        default: return Theme.textSecondary.withAlphaComponent(0.6)
        }
    }

    /// Show/refresh the connect-status overlay (Electron's ConnStatusOverlay): only
    /// for a REMOTE connection that is connecting / errored / disconnected. A connected
    /// (or local) connection clears it.
    private func updateConnOverlay(connName: String?, isLocal: Bool, status: ConnStatus?) {
        guard isTerminalBlock, !isLocal, let connName else { removeConnOverlay(); return }
        let s = status?.status
        let connected = (s == ConnStatusValue.connected)
        if connected { removeConnOverlay(); return }

        let overlay = connOverlay ?? makeConnOverlay()
        overlay.update(connName: connName, status: status)
    }

    private func makeConnOverlay() -> ConnStatusOverlayView {
        let overlay = ConnStatusOverlayView()
        overlay.onRetry = { [weak self] connName in
            guard let self else { return }
            let req = ConnRequest(host: connName, logblockid: self.blockRef.oid)
            let transport = self.env.transport
            let store = self.env.store
            Task.detached {
                let client = ServiceClient(transport: transport, store: store)
                try? await client.connConnect(req)
            }
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        innerView.addSubview(overlay, positioned: .above, relativeTo: headerView)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: innerView.leadingAnchor, constant: 6),
            overlay.trailingAnchor.constraint(equalTo: innerView.trailingAnchor, constant: -6),
            overlay.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 6),
        ])
        connOverlay = overlay
        return overlay
    }

    private func removeConnOverlay() {
        connOverlay?.removeFromSuperview()
        connOverlay = nil
    }

    private static func icon(forView view: String?) -> NSImage? {
        switch view {
        case "term": return symbol("terminal")
        case "web": return symbol("globe")
        case TasksPaneView.viewType: return symbol("checklist")
        default: return symbol("squareshape")
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    // MARK: Focus

    private func updateFocusBorder() {
        let color = (isFocused ? Theme.focusedBlockBorderColor : NSColor.clear).cgColor
        borderOverlay.layer?.borderColor = color
        splitBorderLayer?.borderColor = color
    }

    // MARK: Split transition styling

    /// Monotonic token for the split-transition styling. A second transition can start
    /// while the first is still animating (rapid ⌘D, or a close mid-split); the FIRST
    /// completion must then NOT tear down the styling the newer transition owns — its
    /// cleanup is gated on the token still being current.
    private var splitTransitionGen = 0
    /// Border box tracking the pane's animating presentation bounds (inset 1px so it
    /// matches the resting `borderOverlay`, which hugs the 1px-inset `innerView`).
    private var splitBorderLayer: CALayer?
    /// The temporary scrim behind the edge-tracking header buttons.
    private var pinnedButtonScrim: NSView?

    /// Style this pane for a split/close frame transition running from `startSize` to the
    /// CURRENT (final) bounds. The content is laid out ONCE at the final geometry; every
    /// piece that must visually track the animating edge is driven by explicit CA
    /// animations on the SAME timeline as the pane's frame animation:
    ///   * clip + rounding + background on the pane layer (presentation-accurate),
    ///   * a border sublayer inset 1px (matches the resting overlay border exactly),
    ///   * the trailing header buttons + their scrim tracking the right edge.
    /// Returns the token to pass to `endSplitTransition` from the animation's completion.
    func beginSplitTransition(startSize: CGSize, duration: TimeInterval) -> Int {
        removeSplitTransitionStyling()
        splitTransitionGen += 1

        layer?.masksToBounds = true
        layer?.cornerRadius = Theme.radiusLarge
        layer?.backgroundColor = innerView.layer?.backgroundColor
        borderOverlay.isHidden = true

        let border = CALayer()
        border.anchorPoint = .zero
        border.position = CGPoint(x: 1, y: 1)
        border.bounds = CGRect(x: 0, y: 0, width: max(bounds.width - 2, 0), height: max(bounds.height - 2, 0))
        border.cornerRadius = Theme.radiusLarge
        border.borderWidth = Theme.focusedBlockBorderWidth
        border.borderColor = (isFocused ? Theme.focusedBlockBorderColor : NSColor.clear).cgColor
        border.zPosition = 5
        layer?.addSublayer(border)
        let borderAnim = CABasicAnimation(keyPath: "bounds")
        borderAnim.fromValue = CGRect(x: 0, y: 0, width: max(startSize.width - 2, 0),
                                      height: max(startSize.height - 2, 0))
        borderAnim.toValue = border.bounds
        borderAnim.duration = duration
        borderAnim.timingFunction = CAMediaTimingFunction(name: .linear)
        border.add(borderAnim, forKey: "splitBorder")
        splitBorderLayer = border

        pinTrailingButtons(deltaX: bounds.width - startSize.width, duration: duration)
        return splitTransitionGen
    }

    /// Tear down the transition styling IF `token` is still the current transition
    /// (see `splitTransitionGen`); a stale completion is a no-op. Returns whether it
    /// actually cleaned up.
    @discardableResult
    func endSplitTransition(token: Int) -> Bool {
        guard token == splitTransitionGen else { return false }
        removeSplitTransitionStyling()
        return true
    }

    private func removeSplitTransitionStyling() {
        layer?.masksToBounds = false
        layer?.cornerRadius = 0
        layer?.backgroundColor = nil
        borderOverlay.isHidden = false
        splitBorderLayer?.removeFromSuperlayer()
        splitBorderLayer = nil
        pinnedButtonScrim?.removeFromSuperview()
        pinnedButtonScrim = nil
    }

    /// The content is laid out at the FINAL geometry and anchored to the pane's top-left
    /// in layer space, so on a width transition the right-anchored header buttons would
    /// ride the LEFT edge (sliding in from beyond the pane on a grow-from-the-right,
    /// or lagging the divider on a shrink). Animate their layer positions by the width
    /// delta so they track the pane's RIGHT edge throughout.
    private func pinTrailingButtons(deltaX: CGFloat, duration: TimeInterval) {
        guard abs(deltaX) > 0.5 else { return }
        // The icon+title ride the left edge while the buttons track the right one, so the
        // two cross while the pane is narrow. Back the button cluster with one
        // header-colored scrim (below the buttons, above the title) so the crossing
        // occludes cleanly. It replicates the header's 1px bottom separator, which it
        // would otherwise cover.
        let buttons = [magnifyButton, settingsButton, closeButton].filter { !$0.isHidden }
        if let first = buttons.first {
            let cluster = buttons.dropFirst().reduce(first.frame) { $0.union($1.frame) }
            let scrim = NSView()
            scrim.wantsLayer = true
            scrim.layer?.backgroundColor = innerView.layer?.backgroundColor
            scrim.frame = NSRect(x: cluster.minX - 6, y: 0,
                                 width: headerView.bounds.maxX - cluster.minX + 6,
                                 height: headerView.bounds.height)
            let line = NSView(frame: NSRect(x: 0, y: 0, width: scrim.bounds.width, height: 1))
            line.wantsLayer = true
            line.layer?.backgroundColor = Theme.border.cgColor
            line.autoresizingMask = [.width]
            scrim.addSubview(line)
            headerView.addSubview(scrim, positioned: .below, relativeTo: first)
            pinnedButtonScrim = scrim
        }
        for view in ([pinnedButtonScrim].compactMap { $0 }) + buttons {
            guard let layer = view.layer else { continue }
            let anim = CABasicAnimation(keyPath: "position.x")
            anim.fromValue = layer.position.x - deltaX
            anim.toValue = layer.position.x
            anim.duration = duration
            anim.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(anim, forKey: "pinTrailing")
        }
    }

    // MARK: Magnify

    /// Reflect magnified state: flip the header icon to "minimize" and float the
    /// block with a drop shadow (Electron's magnified block sits above the others).
    /// Opaque backing under a magnified pane. The pane body is translucent when
    /// a tab background (or window translucency) is active, so without this the
    /// still-tiled sibling panes shine through the floating magnified pane. The
    /// backdrop reproduces the stack the pane normally sits on: the opaque
    /// window base plus the tab background, clipped to the pane's corners.
    private var magnifyBackdrop: NSView?
    private var magnifyBackdropBg: TabBackgroundView?

    private func updateMagnifyBackdrop() {
        let root = window?.contentView as? RootContentView
        let cfg = root?.currentTabBackgroundConfig
        let needed = isMagnifiedState && (cfg != nil || window?.isOpaque == false)
        guard needed else {
            magnifyBackdrop?.removeFromSuperview()
            magnifyBackdrop = nil
            magnifyBackdropBg = nil
            return
        }
        if magnifyBackdrop == nil {
            let backdrop = NSView()
            backdrop.wantsLayer = true
            backdrop.layer?.backgroundColor = Theme.windowBackground.cgColor
            backdrop.layer?.cornerRadius = Theme.radiusLarge
            backdrop.layer?.masksToBounds = true
            backdrop.translatesAutoresizingMaskIntoConstraints = false
            let bg = TabBackgroundView()
            bg.frame = .zero
            bg.autoresizingMask = [.width, .height]
            backdrop.addSubview(bg)
            addSubview(backdrop, positioned: .below, relativeTo: innerView)
            NSLayoutConstraint.activate([
                backdrop.leadingAnchor.constraint(equalTo: innerView.leadingAnchor),
                backdrop.trailingAnchor.constraint(equalTo: innerView.trailingAnchor),
                backdrop.topAnchor.constraint(equalTo: innerView.topAnchor),
                backdrop.bottomAnchor.constraint(equalTo: innerView.bottomAnchor),
            ])
            backdrop.layoutSubtreeIfNeeded()
            bg.frame = backdrop.bounds
            magnifyBackdrop = backdrop
            magnifyBackdropBg = bg
        }
        magnifyBackdropBg?.config = cfg
    }

    func setMagnified(_ on: Bool) {
        isMagnifiedState = on
        updateMagnifyBackdrop()
        // masksToBounds off so the magnify drop shadow can render OUTSIDE the bounds —
        // but never while a split transition is clipping the sweep: this runs on EVERY
        // rebuild (incl. the non-structural echo right after a split), and dropping the
        // clip mid-animation let the black pane background/scrim paint past the border.
        if splitBorderLayer == nil { layer?.masksToBounds = false }
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = on ? 0.45 : 0
        layer?.shadowRadius = on ? 16 : 0
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        updateMagnifyButton()
    }

    private func updateMagnifyButton() {
        magnifyButton.isHidden = !canMagnify
        magnifyButton.isMagnified = isMagnifiedState
        magnifyButton.toolTip = isMagnifiedState ? "Minimize" : "Magnify"
    }

    // MARK: Context menu

    /// Block right-click menu (Electron parity). Restricted to the header so it does
    /// not shadow the terminal content's own right-click (paste). Reuses the existing
    /// seams: magnify via `onToggleMagnify` (same as the header button), split via
    /// `env.onSplit`, close via `env.onClose`.
    override func menu(for event: NSEvent) -> NSMenu? {
        let headerPoint = headerView.convert(event.locationInWindow, from: nil)
        guard headerView.bounds.contains(headerPoint) else { return nil }
        onRequestFocus?(nodeId)
        return makeBlockMenu()
    }

    /// Block `meta` keys driven by the settings menu. Held as plain strings here (not
    /// imported from WaveWeb/WaveTerminal) so the chrome stays free of the content
    /// modules — every item is just a `setMeta` on `blockRef`, exactly as Electron does.
    private enum BlockMeta {
        static let frameTitle = "frame:title"
        static let clearOnStart = "cmd:clearonstart"
        static let runOnStart = "cmd:runonstart"
        static let connDebug = "term:conndebug"
        static let webHideNav = "web:hidenav"
        static let webUserAgentType = "web:useragenttype"
        static let webZoom = "web:zoom"
        static let pinnedURL = "pinnedurl"
        static let termTheme = "term:theme"
        static let displayName = "display:name"
    }

    /// Web zoom presets (Electron `webview.tsx` Set-Zoom submenu). The live web view
    /// clamps on apply, so the chrome just persists the chosen factor.
    private static let zoomFactors: [(label: String, factor: Double)] = [
        ("25%", 0.25), ("50%", 0.5), ("70%", 0.7), ("80%", 0.8), ("90%", 0.9),
        ("100%", 1), ("110%", 1.1), ("120%", 1.2), ("130%", 1.3),
        ("150%", 1.5), ("175%", 1.75), ("200%", 2),
    ]

    /// The block's current `meta` from the store (empty if not cached yet) — the source
    /// for each toggle/submenu's checked state.
    private func blockMeta() -> MetaMapType {
        env.store.get(blockRef)?.asBlock?.meta ?? [:]
    }

    /// The per-block menu shared by the header right-click and the settings/gear button.
    /// View-specific: terminals/web blocks get their own section between the common
    /// magnify/split prefix and the Copy-BlockId/Close suffix (Electron parity).
    private func makeBlockMenu() -> NSMenu {
        let menu = NSMenu()
        let mode = Self.headerMode(forView: currentViewType)
        let meta = blockMeta()
        let isNavHidden = meta[BlockMeta.webHideNav]?.boolValue ?? false
        let ids = Self.blockMenuItems(
            view: mode, canMagnify: canMagnify, isMagnified: isMagnifiedState, isNavHidden: isNavHidden)
        for id in ids {
            switch id {
            case .separator: menu.addItem(.separator())
            case .magnify: menu.addItem(menuItem("Magnify", #selector(menuToggleMagnify)))
            case .minimize: menu.addItem(menuItem("Minimize", #selector(menuToggleMagnify)))
            case .splitRight: menu.addItem(menuItem("Split Right", #selector(menuSplitRight)))
            case .splitDown: menu.addItem(menuItem("Split Down", #selector(menuSplitDown)))
            case .copy: menu.addItem(menuItem("Copy", #selector(menuCopyContent)))
            case .paste: menu.addItem(menuItem("Paste", #selector(menuPasteContent)))
            case .selectAll: menu.addItem(menuItem("Select All", #selector(menuSelectAllContent)))
            case .themes: menu.addItem(makeThemesItem(meta: meta))
            case .forceRestart: menu.addItem(menuItem("Force Restart Controller", #selector(menuForceRestart)))
            case .termClearBuffer: menu.addItem(menuItem("Clear Buffer", #selector(menuTermClearBuffer)))
            case .resetTerminal: menu.addItem(menuItem("Reset Terminal", #selector(menuResetTerminal)))
            case .clearOnRestart: menu.addItem(makeClearOnRestartItem(meta: meta))
            case .runOnStartup: menu.addItem(makeRunOnStartupItem(meta: meta))
            case .debugConnection: menu.addItem(makeDebugConnectionItem(meta: meta))
            case .reload: menu.addItem(menuItem("Reload", #selector(menuReloadWeb)))
            case .copyURL: menu.addItem(menuItem("Copy URL to Clipboard", #selector(menuCopyURL)))
            case .openExternal: menu.addItem(menuItem("Open in External Browser", #selector(menuOpenExternal)))
            case .setBlockHomepage: menu.addItem(menuItem("Set Block Homepage", #selector(menuSetBlockHomepage)))
            case .hideNav: menu.addItem(menuItem("Hide Navigation", #selector(menuToggleHideNav)))
            case .unhideNav: menu.addItem(menuItem("Un-Hide Navigation", #selector(menuToggleHideNav)))
            case .userAgentType: menu.addItem(makeUserAgentItem(meta: meta))
            case .zoom: menu.addItem(makeZoomItem(meta: meta))
            case .renamePane: menu.addItem(menuItem("Rename Pane", #selector(menuRenamePane)))
            case .copyBlockId: menu.addItem(menuItem("Copy BlockId", #selector(menuCopyBlockId)))
            case .copyLink: menu.addItem(menuItem("Copy Link", #selector(menuCopyLink)))
            case .close: menu.addItem(menuItem("Close Block", #selector(menuCloseBlock)))
            }
        }
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// Two-state On/Off checkbox submenu over a boolean `meta` key.
    private func makeBoolToggleItem(
        title: String, key: String, current: Bool, onSel: Selector, offSel: Selector
    ) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let onItem = menuItem("On", onSel); onItem.state = current ? .on : .off
        let offItem = menuItem("Off", offSel); offItem.state = current ? .off : .on
        sub.addItem(onItem); sub.addItem(offItem)
        parent.submenu = sub
        return parent
    }

    private func makeClearOnRestartItem(meta: MetaMapType) -> NSMenuItem {
        makeBoolToggleItem(
            title: "Clear Output On Restart", key: BlockMeta.clearOnStart,
            current: meta[BlockMeta.clearOnStart]?.boolValue ?? false,
            onSel: #selector(menuClearOnRestartOn), offSel: #selector(menuClearOnRestartOff))
    }

    private func makeRunOnStartupItem(meta: MetaMapType) -> NSMenuItem {
        makeBoolToggleItem(
            title: "Run On Startup", key: BlockMeta.runOnStart,
            current: meta[BlockMeta.runOnStart]?.boolValue ?? false,
            onSel: #selector(menuRunOnStartupOn), offSel: #selector(menuRunOnStartupOff))
    }

    private func makeDebugConnectionItem(meta: MetaMapType) -> NSMenuItem {
        let cur = meta[BlockMeta.connDebug]?.stringValue
        let parent = NSMenuItem(title: "Debug Connection", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let off = menuItem("Off", #selector(menuDebugConnOff)); off.state = (cur?.isEmpty ?? true) ? .on : .off
        let info = menuItem("Info", #selector(menuDebugConnInfo)); info.state = cur == "info" ? .on : .off
        let verbose = menuItem("Verbose", #selector(menuDebugConnVerbose)); verbose.state = cur == "debug" ? .on : .off
        sub.addItem(off); sub.addItem(info); sub.addItem(verbose)
        parent.submenu = sub
        return parent
    }

    /// Per-pane terminal "Theme" submenu. "Default" clears the block's `term:theme`
    /// override (falls back to the global/default theme); each named entry writes
    /// `term:theme` on this block. The composition root re-applies the palette when the
    /// resulting `waveobj:update` lands (the provider watches the block meta).
    private func makeThemesItem(meta: MetaMapType) -> NSMenuItem {
        let parent = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let override = meta[BlockMeta.termTheme]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let effective = override ?? env.defaultTermThemeName

        let def = menuItem("Default", #selector(menuSetTermThemeDefault))
        def.state = (override == nil) ? .on : .off
        sub.addItem(def)
        if !env.termThemes.isEmpty { sub.addItem(.separator()) }
        for theme in env.termThemes {
            let item = menuItem(theme.displayName, #selector(menuSetTermTheme(_:)))
            item.representedObject = theme.name
            item.state = (effective == theme.name) ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    private func makeUserAgentItem(meta: MetaMapType) -> NSMenuItem {
        let cur = meta[BlockMeta.webUserAgentType]?.stringValue ?? "default"
        let parent = NSMenuItem(title: "User Agent Type", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        let def = menuItem("Default", #selector(menuUserAgentDefault))
        def.state = (cur.isEmpty || cur == "default") ? .on : .off
        let iphone = menuItem("Mobile: iPhone", #selector(menuUserAgentIPhone))
        iphone.state = cur == "mobile:iphone" ? .on : .off
        let android = menuItem("Mobile: Android", #selector(menuUserAgentAndroid))
        android.state = cur == "mobile:android" ? .on : .off
        sub.addItem(def); sub.addItem(iphone); sub.addItem(android)
        parent.submenu = sub
        return parent
    }

    private func makeZoomItem(meta: MetaMapType) -> NSMenuItem {
        let cur = meta[BlockMeta.webZoom]?.doubleValue ?? 1
        let parent = NSMenuItem(title: "Set Zoom Factor", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(menuItem("Reset", #selector(menuResetZoom)))
        for preset in Self.zoomFactors {
            let item = menuItem(preset.label, #selector(menuSetZoom(_:)))
            // Carry the factor on the item so a single action handles all presets.
            item.representedObject = preset.factor
            item.state = abs(cur - preset.factor) < 0.0001 ? .on : .off
            sub.addItem(item)
        }
        parent.submenu = sub
        return parent
    }

    /// Pop the block menu under the settings/gear button.
    private func showBlockMenu() {
        onRequestFocus?(nodeId)
        let menu = makeBlockMenu()
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: settingsButton.bounds.maxY), in: settingsButton)
    }

    // MARK: Menu actions

    @objc private func menuToggleMagnify() { onToggleMagnify?(nodeId) }
    @objc private func menuSplitRight() { env.onSplit?(blockRef.oid, "horizontal") }
    @objc private func menuSplitDown() { env.onSplit?(blockRef.oid, "vertical") }
    @objc private func menuCloseBlock() { env.onClose?(blockRef.oid) }
    @objc private func menuCopyBlockId() { copyToClipboard(blockRef.oid) }
    @objc private func menuCopyLink() { copyToClipboard(DeepLink.block(blockRef.oid).urlString) }
    @objc private func menuRenamePane() { beginRenamePane() }

    // MARK: Rename Pane (inline editor over the title region)

    /// Overlay an inline editor on the header title, prefilled with the current
    /// `display:name`. Enter/blur commit (empty clears the override, restoring the
    /// derived title); Esc cancels. Mirrors the tab pill's inline rename.
    func beginRenamePane() {
        guard renameEditor == nil else { return }
        let editor = RenamePaneField()
        editor.stringValue = currentDisplayName ?? ""
        editor.placeholderString = "Pane name"
        editor.font = Theme.headerFont
        editor.textColor = Theme.textPrimary
        editor.wantsLayer = true
        editor.layer?.cornerRadius = Theme.radiusSmall
        // NSTextField ignores backgroundColor unless drawsBackground is on; without
        // it the editor is transparent and the title/connection label bleeds through.
        editor.drawsBackground = true
        editor.backgroundColor = NSColor(srgbRed: 0.16, green: 0.16, blue: 0.16, alpha: 1)
        editor.isBordered = false
        editor.focusRingType = .none
        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.onCommit = { [weak self] name in self?.endRenamePane(commit: true, name: name) }
        editor.onCancel = { [weak self] in self?.endRenamePane(commit: false, name: nil) }
        // The editor covers the title region; hide the chrome underneath (title or
        // web nav bar + name label, and the connection click target) so nothing
        // shows through and clicks can't open the connection picker mid-rename.
        titleField.isHidden = true
        webNavBar.isHidden = true
        webNameField.isHidden = true
        connClickTarget.isHidden = true
        headerView.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: iconField.trailingAnchor, constant: 4),
            editor.trailingAnchor.constraint(equalTo: magnifyButton.leadingAnchor, constant: -5),
            editor.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
        ])
        renameEditor = editor
        window?.makeFirstResponder(editor)
        editor.currentEditor()?.selectAll(nil)
    }

    private func endRenamePane(commit: Bool, name: String?) {
        guard let editor = renameEditor else { return }
        renameEditor = nil
        editor.removeFromSuperview()
        let isWebBlock = Self.headerMode(forView: currentViewType) == .web
        titleField.isHidden = isWebBlock
        webNavBar.isHidden = !isWebBlock
        webNameField.isHidden = !isWebBlock || currentDisplayName == nil
        connClickTarget.isHidden = !isTerminalBlock || (env.onPickConnection == nil)
        if commit {
            let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            chromeSetMeta([BlockMeta.displayName: trimmed.isEmpty ? .null : .string(trimmed)])
        }
        // Return keyboard focus to the pane's content (the editor stole first
        // responder; without this the pane looks focused but eats no keys).
        onRequestFocus?(nodeId)
    }

    // Terminal: route the standard Edit actions to the content view (GhosttyTerminalView
    // implements copy:/paste:/selectAll:). The chrome never imports WaveTerminal, so it
    // dispatches the bare selectors through the responder chain instead.
    @objc private func menuCopyContent() { sendToContent(Selector(("copy:"))) }
    @objc private func menuPasteContent() { sendToContent(Selector(("paste:"))) }
    @objc private func menuSelectAllContent() { sendToContent(Selector(("selectAll:"))) }

    @objc private func menuSetTermThemeDefault() { chromeSetMeta([BlockMeta.termTheme: .null]) }
    @objc private func menuSetTermTheme(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        chromeSetMeta([BlockMeta.termTheme: .string(name)])
    }

    @objc private func menuForceRestart() { restartController() }
    @objc private func menuTermClearBuffer() { termClearBuffer() }
    @objc private func menuResetTerminal() { sendToContent(Selector(("resetTerminalState:"))) }
    @objc private func menuClearOnRestartOn() { chromeSetMeta([BlockMeta.clearOnStart: .bool(true)]) }
    @objc private func menuClearOnRestartOff() { chromeSetMeta([BlockMeta.clearOnStart: .bool(false)]) }
    @objc private func menuRunOnStartupOn() { chromeSetMeta([BlockMeta.runOnStart: .bool(true)]) }
    @objc private func menuRunOnStartupOff() { chromeSetMeta([BlockMeta.runOnStart: .bool(false)]) }
    @objc private func menuDebugConnOff() { chromeSetMeta([BlockMeta.connDebug: .null]) }
    @objc private func menuDebugConnInfo() { chromeSetMeta([BlockMeta.connDebug: .string("info")]) }
    @objc private func menuDebugConnVerbose() { chromeSetMeta([BlockMeta.connDebug: .string("debug")]) }

    // Web: reload routes through the nav bridge; URL-derived actions read the live URL.
    @objc private func menuReloadWeb() { env.webNav.reload?() }
    @objc private func menuCopyURL() {
        guard let url = env.webNav.currentURL, !url.isEmpty else { return }
        copyToClipboard(url)
    }
    @objc private func menuOpenExternal() {
        guard let raw = env.webNav.currentURL, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func menuSetBlockHomepage() {
        guard let url = env.webNav.currentURL, !url.isEmpty else { return }
        chromeSetMeta([BlockMeta.pinnedURL: .string(url)])
    }
    @objc private func menuToggleHideNav() {
        let hidden = blockMeta()[BlockMeta.webHideNav]?.boolValue ?? false
        chromeSetMeta([BlockMeta.webHideNav: .bool(!hidden)])
    }
    @objc private func menuUserAgentDefault() { chromeSetMeta([BlockMeta.webUserAgentType: .null]) }
    @objc private func menuUserAgentIPhone() { chromeSetMeta([BlockMeta.webUserAgentType: .string("mobile:iphone")]) }
    @objc private func menuUserAgentAndroid() { chromeSetMeta([BlockMeta.webUserAgentType: .string("mobile:android")]) }
    @objc private func menuResetZoom() { chromeSetMeta([BlockMeta.webZoom: .null]) }
    @objc private func menuSetZoom(_ sender: NSMenuItem) {
        guard let factor = sender.representedObject as? Double else { return }
        chromeSetMeta([BlockMeta.webZoom: .double(factor)])
    }

    // MARK: Menu action helpers

    /// Persist `meta` on this block via the universal `setMeta` lever. Detached because
    /// the menu action is sync; the backend broadcasts the resulting `waveobj:update`,
    /// so the live content view (which already watches these keys) re-renders on its own.
    private func chromeSetMeta(_ meta: MetaMapType) {
        let transport = env.transport
        let store = env.store
        let ref = blockRef
        Task.detached {
            let client = ServiceClient(transport: transport, store: store)
            try? await client.setMeta(oref: ref, meta: meta)
        }
    }

    /// Truncate this block's persisted term buffer ("Clear Buffer"). The backend
    /// publishes the blockfile truncate event, so the live pane clears through its
    /// normal subscription -- no local call needed.
    private func termClearBuffer() {
        let transport = env.transport
        let store = env.store
        let blockId = blockRef.oid
        Task.detached {
            let client = ServiceClient(transport: transport, store: store)
            try? await client.termClearBuffer(blockId: blockId)
        }
    }

    /// Force-restart this block's controller (terminal "Force Restart Controller").
    private func restartController() {
        let transport = env.transport
        let store = env.store
        let blockId = blockRef.oid
        let tabId = env.tabId
        Task.detached {
            let client = ServiceClient(transport: transport, store: store)
            try? await client.controllerResync(tabId: tabId, blockId: blockId, forceRestart: true)
        }
    }

    private func copyToClipboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Dispatch a standard Edit selector to the content view (or its responder chain).
    /// Used for the terminal Copy/Paste/Select All items without importing WaveTerminal.
    private func sendToContent(_ selector: Selector) {
        guard let contentView else { return }
        if contentView.responds(to: selector) {
            _ = contentView.perform(selector, with: nil)
            return
        }
        window?.makeFirstResponder(contentView)
        NSApp.sendAction(selector, to: nil, from: contentView)
    }

    /// Whether the block's content view has mounted (it streams in async via
    /// `bindStore`). While false, `focusContent()` is a no-op and the owner must
    /// re-focus on mount (LayoutTreeView's `pendingFocusBlockId`).
    var hasMountedContent: Bool { contentView != nil }

    /// Whether `responder` sits inside this block's mounted WEB content (the
    /// WKWebView subtree) — the one responder that claims every ⌘ key equivalent
    /// for the page. The header's URL field is NOT page content: it edits in the
    /// window field editor, which lives beside the header text field, so header
    /// editing keeps normal key routing.
    func ownsWebPageResponder(_ responder: NSView) -> Bool {
        guard currentViewType == "web", let contentView else { return false }
        return responder.isDescendant(of: contentView)
    }

    /// Make this block's content the window firstResponder so the user can type
    /// without clicking. No-op until content has mounted (it streams in async via
    /// `bindStore`); fresh tabs rely on the content view's own
    /// `viewDidMoveToWindow` for first focus instead.
    func focusContent() {
        guard let contentView, let window else { return }
        // A web pane's content view never STAYS firstResponder — its
        // becomeFirstResponder hands responder status to the inner WKWebView. So
        // compare by descent, not identity: without this guard every re-focus
        // re-runs the full responder dance, whose focus-request echo
        // (becomeFirstResponder → onRequestFocus → focusBlock → here) livelocked
        // the main thread at 100% CPU when a web pane was added. Only PROPER
        // descendants are skipped — makeFirstResponder on the contentView itself is
        // already idempotent (AppKit early-returns), and re-asserting it lets a pane
        // whose deferred inner hand-off hasn't landed yet recover.
        if let responder = window.firstResponder as? NSView, responder !== contentView,
           responder.isDescendant(of: contentView) {
            return
        }
        window.makeFirstResponder(contentView)
    }

    /// Reload this block's web content (Cmd-R). Routed through `env.webNav` — the
    /// WaveUI↔WaveWeb bridge the provider wires to the live WebBlockView — so this
    /// module never imports WaveWeb. A no-op for a terminal/generic block, whose
    /// bridge has no reload action wired.
    func reloadContent() {
        env.webNav.reload?()
    }

    override func mouseDown(with event: NSEvent) {
        onRequestFocus?(nodeId)
        let headerPoint = headerView.convert(event.locationInWindow, from: nil)
        if headerView.bounds.contains(headerPoint) {
            // Double-click on the header toggles magnify (same seam as the header
            // button / Cmd-M), gated like the button: single-pane tabs don't magnify.
            // The first click of the pair already ran the drag tracking loop and
            // resolved as a no-op move, so no drag conflicts.
            if event.clickCount >= 2 {
                if canMagnify { onToggleMagnify?(nodeId) }
                return
            }
            // The header is the drag handle: hand a press there to the tree view,
            // which runs the rearrange tracking loop (a plain click resolves to a
            // no-op move).
            if let onHeaderDrag {
                onHeaderDrag(nodeId, event)
                return
            }
        }
        // Swallow (no super): AppKit re-routes a mouseDown that bubbles up unhandled
        // to a view visually BEHIND this one. Panes only overlap while one is
        // magnified (it floats by zPosition), so a click on the magnified pane's
        // chrome was re-delivered to a dimmed sibling underneath, whose terminal
        // then stole focus from the zoomed pane.
    }

    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override var mouseDownCanMoveWindow: Bool { false }

    /// Test seam for header hit-region math (mouseDown routing).
    var headerViewForTesting: NSView { headerView }
}

/// Electron's `MagnifyIcon` (`frontend/app/element/magnify.svg`/`.scss`): two
/// diagonal arrows on the bottom-left↔top-right axis. While NOT magnified they
/// point INWARD (toward the center); while magnified they point OUTWARD (to the
/// corners). The flip crossfades over 300ms (Electron animates a rotation). 15x15
/// glyph centered in an 18x18 hit area; tint follows hover (text-secondary →
/// text-primary), matching the SF-Symbol button it replaced.
final class MagnifyButton: NSView {
    var onClick: (() -> Void)?

    var isMagnified: Bool = false {
        didSet {
            guard oldValue != isMagnified else { return }
            needsDisplay = true
        }
    }

    private var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat = 15
        let ox = (bounds.width - side) / 2
        let oy = (bounds.height - side) / 2
        let color = isHovered ? Theme.textPrimary : Theme.textSecondary
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x, y: oy + y) }

        // Electron's MagnifyIcon (frontend/app/asset/magnify.svg) is TWO right-angle
        // corner chevrons on the bottom-left ↔ top-right diagonal (no diagonal shaft).
        // The SVG animates a 180° rotation between states: NOT magnified → the chevrons
        // point OUTWARD, framing the corners (expand affordance); magnified → they point
        // INWARD toward the center (shrink). We swap the vertex/arm geometry to match.
        if isMagnified {
            drawChevron(tip: p(6.5, 6.5), arms: (p(6.5, 0.5), p(0.5, 6.5)), color: color)     // BL, inward
            drawChevron(tip: p(8.5, 8.5), arms: (p(8.5, 14.5), p(14.5, 8.5)), color: color)   // TR, inward
        } else {
            drawChevron(tip: p(1.5, 1.5), arms: (p(1.5, 7.5), p(7.5, 1.5)), color: color)     // BL, outward
            drawChevron(tip: p(13.5, 13.5), arms: (p(13.5, 7.5), p(7.5, 13.5)), color: color) // TR, outward
        }
    }

    /// One corner chevron: two perpendicular arms meeting at `tip` (round join/caps),
    /// reproducing a single `magnify.svg` arrow.
    private func drawChevron(tip: CGPoint, arms: (CGPoint, CGPoint), color: NSColor) {
        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: arms.0)
        path.line(to: tip)
        path.line(to: arms.1)
        color.setStroke()
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // Pointing hand over the clickable button (Electron parity: cursor: pointer),
    // overriding the underlying terminal's I-beam.
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// Transparent click target over the header icon+title region (Electron's
/// ConnectionButton hit area). A faint hover highlight signals it is clickable.
final class HeaderClickTarget: NSView {
    var onClick: (() -> Void)?

    private var isHovered = false { didSet { if oldValue != isHovered { refresh() } } }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Theme.radiusSmall
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { onClick?() }

    private func refresh() {
        layer?.backgroundColor = (isHovered ? Theme.hoverBackground : .clear).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // Pointing hand over the clickable header icon/title area (Electron parity).
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// Connect-status overlay over a remote terminal's content (Electron's
/// ConnStatusOverlay): a rounded banner showing "Connecting to …" or a
/// disconnected/error state with a Retry button. Shown only while a remote
/// connection is not yet connected.
final class ConnStatusOverlayView: NSView {
    /// Fired when the user clicks Retry. Carries the connection name to (re)connect.
    var onRetry: ((String) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private var connName: String = ""

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.radiusSmall
        layer?.backgroundColor = Theme.modalBackground.withAlphaComponent(0.92).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.border.cgColor

        label.font = Theme.uiFont
        label.textColor = Theme.textPrimary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(retryButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: retryButton.leadingAnchor, constant: -8),
            retryButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Update the banner text + Retry visibility from the live status. Mirrors
    /// Electron's ConnStatusOverlay statusText/showReconnect logic.
    func update(connName: String, status: ConnStatus?) {
        self.connName = connName
        let s = status?.status
        switch s {
        case ConnStatusValue.connecting:
            label.stringValue = "Connecting to \"\(connName)\"…"
            retryButton.isHidden = true
        case ConnStatusValue.error:
            let err = status?.error.flatMap { $0.isEmpty ? nil : $0 }
            label.stringValue = err.map { "Error connecting to \"\(connName)\": \($0)" }
                ?? "Error connecting to \"\(connName)\""
            retryButton.isHidden = false
        default:
            label.stringValue = "Disconnected from \"\(connName)\""
            retryButton.isHidden = false
        }
    }

    @objc private func retryClicked() { onRetry?(connName) }
}

/// Web block navigation chrome shown in the header (Electron's webview nav bar):
/// back / forward / reload buttons + an editable address bar. The buttons and the
/// Enter-to-load action are surfaced as closures so the host (`BlockFrameView`)
/// can route them through `env.webNav` to the live WebBlockView — this view knows
/// nothing about WaveWeb.
final class WebNavBar: NSView, NSTextFieldDelegate {
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    /// Fired on Enter with the raw (un-normalized) address-bar text.
    var onSubmit: ((String) -> Void)?

    /// The address shown in the bar. Setting it does not steal focus mid-edit.
    var urlString: String {
        get { urlField.stringValue }
        set { if !isEditing { urlField.stringValue = newValue } }
    }

    private let backButton = ChromeIconButton(symbol: "chevron.left", pointSize: 11)
    private let forwardButton = ChromeIconButton(symbol: "chevron.right", pointSize: 11)
    private let reloadButton = ChromeIconButton(symbol: "arrow.clockwise", pointSize: 11)
    private let urlField = CenteredURLField()
    private var isEditing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backButton.onTap = { [weak self] in self?.onBack?() }
        forwardButton.onTap = { [weak self] in self?.onForward?() }
        reloadButton.onTap = { [weak self] in self?.onReload?() }

        urlField.isEditable = true
        urlField.isBordered = false
        urlField.drawsBackground = true
        urlField.backgroundColor = Theme.blockBg.withAlphaComponent(0.6)
        urlField.textColor = Theme.textPrimary
        urlField.font = Theme.uiFont
        urlField.focusRingType = .none
        urlField.lineBreakMode = .byTruncatingTail
        urlField.cell?.usesSingleLineMode = true
        urlField.cell?.wraps = false
        urlField.cell?.isScrollable = true
        urlField.placeholderString = "Enter URL or search"
        urlField.wantsLayer = true
        urlField.layer?.cornerRadius = Theme.radiusSmall
        urlField.delegate = self
        urlField.target = self
        urlField.action = #selector(submit)

        for v in [backButton, forwardButton, reloadButton, urlField] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            backButton.heightAnchor.constraint(equalTo: heightAnchor),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor),
            forwardButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            forwardButton.heightAnchor.constraint(equalTo: heightAnchor),

            reloadButton.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor),
            reloadButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            reloadButton.heightAnchor.constraint(equalTo: heightAnchor),

            urlField.leadingAnchor.constraint(equalTo: reloadButton.trailingAnchor, constant: 4),
            urlField.trailingAnchor.constraint(equalTo: trailingAnchor),
            urlField.centerYAnchor.constraint(equalTo: centerYAnchor),
            urlField.topAnchor.constraint(equalTo: topAnchor),
            urlField.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    @objc private func submit() {
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        onSubmit?(raw)
    }

    func controlTextDidBeginEditing(_ obj: Notification) { isEditing = true }
    func controlTextDidEndEditing(_ obj: Notification) { isEditing = false }
}

/// Address field whose single-line text is vertically centered. A plain NSTextField
/// top-aligns its text in a field taller than the text (the address bar fills the
/// header height), so the URL sat near the top.
final class CenteredURLField: NSTextField {
    override class var cellClass: AnyClass? {
        get { VCenterTextFieldCell.self }
        set { _ = newValue }
    }
}

/// NSTextFieldCell that vertically centers its (single-line) content + field editor.
final class VCenterTextFieldCell: NSTextFieldCell {
    private func centered(_ rect: NSRect) -> NSRect {
        let textHeight = cellSize(forBounds: rect).height
        guard textHeight < rect.height else { return rect }
        var r = rect
        r.origin.y += (rect.height - textHeight) / 2
        r.size.height = textHeight
        return r
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: centered(rect))
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: controlView, editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText,
                         delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: centered(rect), in: controlView, editor: editor, delegate: delegate, start: start, length: length)
    }
}

/// The "Rename Pane" inline editor: Enter/blur commit, Esc cancels. Commit/cancel
/// are dedicated closures so the frame can tear the editor down without juggling
/// delegate state.
final class RenamePaneField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private var finished = false

    init() {
        super.init(frame: .zero)
        delegate = self
        (cell as? NSTextFieldCell)?.usesSingleLineMode = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finish { $0.onCancel?() }
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finish { $0.onCommit?($0.stringValue) }
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finish { $0.onCommit?($0.stringValue) }
    }

    /// Run exactly one terminal action: Enter fires BOTH insertNewline and (via the
    /// responder chain teardown) textDidEndEditing, which would double-commit.
    private func finish(_ action: (RenamePaneField) -> Void) {
        guard !finished else { return }
        finished = true
        action(self)
    }
}

extension BlockFrameView: ViewDumpAnnotating {
    var dumpAnnotation: String {
        "node=\(nodeId) block=\(blockRef.oid) content=\(hasMountedContent ? "mounted" : "NONE")"
            + (isMagnifiedState ? " magnified" : "") + (isFocused ? " focused" : "")
    }
}
