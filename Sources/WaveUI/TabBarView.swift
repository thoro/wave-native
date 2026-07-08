// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — the tab strip. STYLE.md §4/§6:
//   height 33; bg rgba(0,0,0,0.35) + backdrop blur 20; padding-top 3; the whole
//   strip is a window-drag region except interactive children; traffic-light
//   inset 74 (content starts at x=74). Holds the workspace switcher, pill tabs
//   (130px, dividers 1x14 white@20% hidden next to active/hover), and the
//   new-tab "+" (height 22, pad-x 8, radius 6, fa-plus).

import AppKit
import WaveCore

/// Tab-bar orientation, driven by the `app:tabbar` setting. String constants (not a
/// Swift enum) so they map 1:1 to the config values the backend stores.
enum TabBarPosition {
    static let top = "top"
    static let left = "left"
}

/// Tabs container used in the vertical (left) tab bar: flipped so the manual pill
/// frames stack from the TOP downward. In the horizontal bar the pills fill the full
/// height as a single row, so the flip is visually identical there.
private final class TabsContainerView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { true }
}

/// View-model row for a tab in the strip.
public struct TabBarItem: Equatable, Sendable {
    public let tabId: String
    public let name: String
    /// `tab:flagcolor` meta (a `#rrggbb` string), or nil when unflagged. Drives the
    /// pill's flag indicator and the "Flag Tab" submenu checkmark.
    public let flagColor: String?
    /// An unseen bell / desktop notification fired in this (background) tab. Drives the
    /// pill's unread-bell indicator; cleared when the tab is activated.
    public let hasUnread: Bool
    /// `tab:background` meta (a named preset key like `bg@blue`), or nil. Drives the
    /// "Background" submenu checkmark.
    public let backgroundPresetKey: String?
    public init(tabId: String, name: String, flagColor: String? = nil, hasUnread: Bool = false,
                backgroundPresetKey: String? = nil) {
        self.tabId = tabId
        self.name = name
        self.flagColor = flagColor
        self.hasUnread = hasUnread
        self.backgroundPresetKey = backgroundPresetKey
    }
}

final class TabBarView: NSView {
    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onNewTab: (() -> Void)?
    var onSelectWorkspace: ((String) -> Void)?
    /// New-workspace save from the switcher dropdown composer. Carries the chosen name.
    var onCreateWorkspace: ((String) -> Void)?
    /// Workspace inline-editor / save callbacks (switcher dropdown).
    var onRenameWorkspace: ((String, String) -> Void)?
    var onSetWorkspaceColor: ((String, String) -> Void)?
    var onSetWorkspaceIcon: ((String, String) -> Void)?
    var onSaveWorkspace: ((String) -> Void)?
    var onDeleteWorkspace: ((String) -> Void)?
    /// Raised from a tab's "Move to Workspace" submenu, and from a cross-workspace
    /// drag-drop. Carries (tabId, destWorkspaceId).
    var onMoveTab: ((String, String) -> Void)?
    /// Raised when a same-workspace drag reorders the tabs. Carries the full new order.
    var onReorderTabs: (([String]) -> Void)?
    /// Raised when a tab dragged from ANOTHER workspace's strip (another window) is
    /// dropped here. Carries (tabId, sourceWorkspaceId); the destination is THIS strip's
    /// workspace. The drop fires on the destination coordinator, so it must carry the
    /// origin explicitly (its own `workspaceId` is the destination, not the source).
    var onMoveTabFromDrag: ((String, String) -> Void)?
    /// Raised when a dragged pane (block) is dropped on one of this strip's pills.
    /// Carries (blockId, targetTabId). The backend derives the source tab from the
    /// block itself, so no origin is needed on the payload beyond the same-tab guard.
    var onMoveBlockToTab: ((String, String) -> Void)?
    /// Raised when an inline rename (or "Rename Tab") commits. Carries (tabId, newName).
    var onRenameTab: ((String, String) -> Void)?
    /// Raised from a tab's "Flag Tab" submenu. Carries (tabId, colorHex|nil) where nil clears.
    var onSetTabFlagColor: ((String, String?) -> Void)?
    /// Raised from a tab's "Background" submenu. Carries (tabId, metaPatch) — the
    /// `tab:background` / `bg*` SetMeta patch to apply (a `.null` value deletes a key).
    var onSetTabBackground: ((String, MetaMapType) -> Void)?
    /// Raised by the trailing config/gear button.
    var onShowSettings: (() -> Void)?
    /// Raised when a tab inline-rename session ends (commit/cancel/blur), so the owner
    /// can restore window firstResponder to the active pane's terminal.
    var onRenameSessionEnd: (() -> Void)?

    private let background = TabStripBackgroundView()
    private let tintLayer = CALayer()
    let workspaceSwitcher = WorkspaceSwitcherView()
    private let tabsContainer = TabsContainerView()
    /// Window-drag handle over the genuinely-empty part of the strip. The backdrop is
    /// deliberately non-draggable (see DragViews.swift), so this is what lets the user
    /// move/tile the window by the strip — laid out so it never overlaps the pills.
    private let dragFiller = DragView()
    private let newTabButton = PlusButton()
    private let settingsButton = ChromeIconButton(symbol: "gearshape", pointSize: 13)
    /// Thin line shown between pills at the drop index during a drag. A subview of the
    /// flipped tabs container, so it positions in the same coordinate space as the pills.
    private let insertionIndicator = NSView()

    private var items: [TabBarItem] = []
    private var activeTabId: String?
    private var pills: [TabPillView] = []
    private var tabsWidthConstraint: NSLayoutConstraint?
    /// Sizes the tabs container to its pills' total HEIGHT in the vertical (left) strip,
    /// the mirror of `tabsWidthConstraint` in the horizontal strip. Shrinking the
    /// container to fit means the empty area below the last pill is free for the drag
    /// filler instead of being covered by the (non-draggable) container.
    private var tabsHeightConstraint: NSLayoutConstraint?
    private var workspaceItems: [WorkspaceMenuItem] = []
    private var activeWorkspaceId: String?
    /// Config-defined background presets, pushed to each pill's "Background" submenu.
    private var backgroundPresets: [TabBackgroundPreset] = []

    /// Constraint sets for the two orientations; exactly one is active at a time. Built
    /// once in `setup()`, swapped by `applyPosition()` when the `app:tabbar` setting changes.
    private var topConstraints: [NSLayoutConstraint] = []
    private var leftConstraints: [NSLayoutConstraint] = []

    /// `top` (horizontal strip) or `left` (vertical strip). Driven by `app:tabbar`.
    var position: String = TabBarPosition.top {
        didSet { if oldValue != position { applyPosition() } }
    }

    /// Pill frames, exposed for layout tests (vertical vs horizontal arrangement).
    var pillFrames: [CGRect] { pills.map { $0.frame } }

    /// The gear button view, so the owner can anchor the per-window appearance popover to it.
    var settingsAnchorView: NSView { settingsButton }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Hide the blurred backdrop while the active tab has a background: the
    /// visual-effect view blends BEHIND the window (desktop), so it would mask
    /// the in-window background view; the pills carry their own contrast.
    func setTabBackgroundActive(_ active: Bool) {
        background.isHidden = active
    }

    private func setup() {
        // Blurred translucent backdrop (STYLE §4: blur 20 + rgba(0,0,0,0.35)).
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .active
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        tintLayer.backgroundColor = Theme.tabBarBackground.cgColor
        background.wantsLayer = true
        background.layer?.addSublayer(tintLayer)

        workspaceSwitcher.translatesAutoresizingMaskIntoConstraints = false
        workspaceSwitcher.onSelectWorkspace = { [weak self] id in self?.onSelectWorkspace?(id) }
        workspaceSwitcher.onCreateWorkspace = { [weak self] name in self?.onCreateWorkspace?(name) }
        workspaceSwitcher.onRenameWorkspace = { [weak self] id, name in self?.onRenameWorkspace?(id, name) }
        workspaceSwitcher.onSetWorkspaceColor = { [weak self] id, hex in self?.onSetWorkspaceColor?(id, hex) }
        workspaceSwitcher.onSetWorkspaceIcon = { [weak self] id, icon in self?.onSetWorkspaceIcon?(id, icon) }
        workspaceSwitcher.onSaveWorkspace = { [weak self] id in self?.onSaveWorkspace?(id) }
        workspaceSwitcher.onDeleteWorkspace = { [weak self] id in self?.onDeleteWorkspace?(id) }
        addSubview(workspaceSwitcher)

        tabsContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabsContainer)

        // Above the backdrop (added first) so it hit-tests for the window drag, but it is
        // constrained to empty regions only, so it never sits in front of a pill/button.
        dragFiller.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dragFiller)

        insertionIndicator.wantsLayer = true
        insertionIndicator.layer?.backgroundColor = Theme.accent.cgColor
        insertionIndicator.isHidden = true
        tabsContainer.addSubview(insertionIndicator)

        // Accept dropped tabs (reorder within this strip, or move from another window's)
        // and dropped panes (a block moving into one of this strip's tabs).
        registerForDraggedTypes([TabDragPayload.tabIdType, BlockDragPayload.blockIdType])

        newTabButton.translatesAutoresizingMaskIntoConstraints = false
        newTabButton.onTap = { [weak self] in self?.onNewTab?() }
        addSubview(newTabButton)

        // Trailing config/gear button (Electron's tab-bar app-menu/ellipsis slot).
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.onTap = { [weak self] in self?.onShowSettings?() }
        addSubview(settingsButton)

        // Shared (always active): the backdrop fills the whole strip, and the chrome
        // buttons keep their fixed 22pt height in either orientation.
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            workspaceSwitcher.heightAnchor.constraint(equalToConstant: 22),
            newTabButton.heightAnchor.constraint(equalToConstant: 22),
            settingsButton.heightAnchor.constraint(equalToConstant: 22),
        ])

        let widthC = tabsContainer.widthAnchor.constraint(equalToConstant: 0)
        tabsWidthConstraint = widthC
        let heightC = tabsContainer.heightAnchor.constraint(equalToConstant: 0)
        tabsHeightConstraint = heightC

        // Horizontal strip: switcher | tabs | + ......... gear, all centered vertically.
        topConstraints = [
            // Content starts past the traffic lights (STYLE §6: inset 74).
            workspaceSwitcher.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.trafficLightInset),
            workspaceSwitcher.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1.5),

            tabsContainer.leadingAnchor.constraint(equalTo: workspaceSwitcher.trailingAnchor, constant: 8),
            tabsContainer.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            tabsContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthC,

            newTabButton.leadingAnchor.constraint(equalTo: tabsContainer.trailingAnchor, constant: 4),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1.5),

            settingsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            settingsButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1.5),

            // Drag handle: the empty span between the "+" and the gear, full height.
            dragFiller.leadingAnchor.constraint(equalTo: newTabButton.trailingAnchor, constant: 4),
            dragFiller.trailingAnchor.constraint(equalTo: settingsButton.leadingAnchor, constant: -4),
            dragFiller.topAnchor.constraint(equalTo: topAnchor),
            dragFiller.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]

        // Vertical strip: switcher pinned TOP, tabs stacked below, "+" then gear pinned
        // to the BOTTOM. The tabs container is sized to its pills (heightC); the empty
        // gap below it down to the "+" is the drag handle.
        leftConstraints = [
            workspaceSwitcher.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            workspaceSwitcher.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            workspaceSwitcher.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            tabsContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabsContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabsContainer.topAnchor.constraint(equalTo: workspaceSwitcher.bottomAnchor, constant: 8),
            heightC,

            newTabButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            newTabButton.bottomAnchor.constraint(equalTo: settingsButton.topAnchor, constant: -8),

            settingsButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            settingsButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            // Drag handle: the empty span below the last pill down to the "+", full width.
            dragFiller.leadingAnchor.constraint(equalTo: leadingAnchor),
            dragFiller.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragFiller.topAnchor.constraint(equalTo: tabsContainer.bottomAnchor),
            dragFiller.bottomAnchor.constraint(equalTo: newTabButton.topAnchor),
        ]

        applyPosition()
    }

    /// Swap the active constraint set for the current `position` and re-flow the pills.
    private func applyPosition() {
        let isLeft = (position == TabBarPosition.left)
        NSLayoutConstraint.deactivate(isLeft ? topConstraints : leftConstraints)
        NSLayoutConstraint.activate(isLeft ? leftConstraints : topConstraints)
        needsLayout = true
        layoutPills()
    }

    override func layout() {
        super.layout()
        tintLayer.frame = background.bounds
        layoutPills()
    }

    // MARK: Data

    func setWorkspace(name: String?, icon: String?, color: String?, workspaceId: String?) {
        workspaceSwitcher.setActive(name: name, icon: icon, color: color, workspaceId: workspaceId)
        activeWorkspaceId = workspaceId
        // Keep live pills' drag source workspace in sync (setWorkspace can arrive after
        // setTabs), so a drag started before the next rebuild carries the right source.
        for pill in pills { pill.sourceWorkspaceId = workspaceId }
        refreshMoveTargets()
    }

    func setWorkspaceItems(_ items: [WorkspaceMenuItem]) {
        workspaceSwitcher.setItems(items)
        workspaceItems = items
        refreshMoveTargets()
    }

    /// Provide the selectable color/icon palettes to the switcher's inline editor.
    func setWorkspacePalette(colors: [String], icons: [String]) {
        workspaceSwitcher.setPalette(colors: colors, icons: icons)
    }

    /// Provide the config-defined background presets to each pill's "Background" submenu.
    /// Pushed to live pills too, since this can arrive after `setTabs`.
    func setBackgroundPresets(_ presets: [TabBackgroundPreset]) {
        backgroundPresets = presets
        for pill in pills { pill.backgroundPresets = presets }
    }

    /// Recompute the per-tab "Move to Workspace" target list and push it to the live
    /// pills. Excludes the current workspace; empty when only one tab remains (the
    /// backend refuses to move the last tab out, so the gesture is hidden).
    private func refreshMoveTargets() {
        let canMove = items.count > 1
        let targets = canMove ? workspaceItems.filter { $0.workspaceId != activeWorkspaceId } : []
        for pill in pills { pill.moveTargets = targets }
    }

    /// Set the full tab list and which one is active.
    func setTabs(_ items: [TabBarItem], activeTabId: String?) {
        self.items = items
        self.activeTabId = activeTabId
        rebuildPills()
    }

    private func rebuildPills() {
        pills.forEach { $0.removeFromSuperview() }
        pills.removeAll()
        for item in items {
            let pill = TabPillView(tabId: item.tabId, title: item.name)
            pill.isActive = (item.tabId == activeTabId)
            pill.flagColor = item.flagColor
            pill.hasUnread = item.hasUnread
            pill.backgroundPresets = backgroundPresets
            pill.backgroundPresetKey = item.backgroundPresetKey
            pill.sourceWorkspaceId = activeWorkspaceId
            pill.onSelect = { [weak self] id in self?.onSelectTab?(id) }
            pill.onClose = { [weak self] id in self?.onCloseTab?(id) }
            pill.onMoveToWorkspace = { [weak self] tabId, wsId in self?.onMoveTab?(tabId, wsId) }
            pill.onRename = { [weak self] tabId, name in self?.onRenameTab?(tabId, name) }
            pill.onSetFlagColor = { [weak self] tabId, color in self?.onSetTabFlagColor?(tabId, color) }
            pill.onSetTabBackground = { [weak self] tabId, patch in self?.onSetTabBackground?(tabId, patch) }
            pill.onRenameSessionEnd = { [weak self] in self?.onRenameSessionEnd?() }
            // Pills are positioned by manual frames (see layoutPills), so keep
            // autoresizing translation on (the default) — do NOT disable it.
            tabsContainer.addSubview(pill)
            pills.append(pill)
        }
        refreshMoveTargets()
        needsLayout = true
        layoutPills()
    }

    private func layoutPills() {
        if position == TabBarPosition.left {
            layoutPillsVertical()
            return
        }
        var x: CGFloat = 0
        let h = tabsContainer.bounds.height
        for pill in pills {
            pill.frame = CGRect(x: x, y: 0, width: Theme.tabWidth, height: h)
            x += Theme.tabWidth
        }
        // Size the container to fit its pills so the new-tab button sits flush.
        tabsWidthConstraint?.constant = x
    }

    /// Stack the pills as full-width rows from the top (the container is flipped, so
    /// y grows downward). Each pill is a full-width row of the strip.
    private func layoutPillsVertical() {
        let w = tabsContainer.bounds.width
        let rowH = Theme.tabBarLeftRowHeight
        var y: CGFloat = 0
        for pill in pills {
            pill.frame = CGRect(x: 0, y: y, width: w, height: rowH)
            y += rowH
        }
        // Fit the container to its pills so the empty area below is a drag handle, not a
        // non-draggable container (the vertical mirror of the horizontal width fit).
        tabsHeightConstraint?.constant = y
    }

    // MARK: Drag destination (reorder + cross-workspace move)

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        dndLog("bar draggingEntered hasTabId=\(pb.string(forType: TabDragPayload.tabIdType) != nil) hasBlockId=\(pb.string(forType: BlockDragPayload.blockIdType) != nil) ws=\(activeWorkspaceId?.suffix(4) ?? "nil")")
        // A drag hovering directly over a background window's strip raises that window
        // immediately (the content area raises with a spring delay — RootContentView).
        if pb.string(forType: TabDragPayload.tabIdType) != nil
            || pb.string(forType: BlockDragPayload.blockIdType) != nil {
            window?.orderFront(nil)
        }
        return updateDrag(sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrag(sender)
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        hideInsertionIndicator()
        highlightDropPill(nil)
    }

    public override func draggingEnded(_ sender: NSDraggingInfo) {
        hideInsertionIndicator()
        highlightDropPill(nil)
    }

    private func updateDrag(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        // A dragged pane targets a PILL (the block lands IN that tab), not an
        // insertion point between pills.
        if pb.string(forType: BlockDragPayload.blockIdType) != nil {
            let target = pill(at: convert(sender.draggingLocation, from: nil))
            highlightDropPill(target)
            return target != nil ? .move : []
        }
        guard pb.string(forType: TabDragPayload.tabIdType) != nil else { return [] }
        showInsertionIndicator(atIndex: dropIndex(at: convert(sender.draggingLocation, from: nil)))
        return .move
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideInsertionIndicator()
        highlightDropPill(nil)
        let pb = sender.draggingPasteboard
        if let blockId = pb.string(forType: BlockDragPayload.blockIdType) {
            return performBlockDrop(blockId: blockId, sender: sender)
        }
        guard let tabId = pb.string(forType: TabDragPayload.tabIdType) else {
            dndLog("bar performDrag: no tabId on pasteboard")
            return false
        }
        let sourceWs = pb.string(forType: TabDragPayload.workspaceIdType) ?? ""
        let destWs = activeWorkspaceId ?? ""
        let index = dropIndex(at: convert(sender.draggingLocation, from: nil))
        dndLog("bar performDrag tab=\(tabId.suffix(4)) srcWs=\(sourceWs.suffix(4)) destWs=\(destWs.suffix(4)) index=\(index) reorder=\(Self.dropIsReorder(sourceWorkspaceId: sourceWs, destWorkspaceId: destWs))")

        // Same workspace -> reorder; a different (or empty) source -> cross-workspace move
        // (the tab came from another window's strip). See `dropIsReorder`.
        if Self.dropIsReorder(sourceWorkspaceId: sourceWs, destWorkspaceId: destWs) {
            let current = items.map { $0.tabId }
            let reordered = Self.reorderedTabIds(current, moving: tabId, toIndex: index)
            dndLog("bar reorder changed=\(reordered != current) order=\(reordered.map { $0.suffix(4) })")
            if reordered != current { onReorderTabs?(reordered) }
            return true
        }
        // A tab dropped from another window should leave THIS window active: the raise
        // -on-hover only ordered it front, so the SOURCE window is still key — the very
        // next Cmd-D would go there and split the wrong tab.
        window?.makeKeyAndOrderFront(nil)
        onMoveTabFromDrag?(tabId, sourceWs)
        return true
    }

    /// A dragged pane dropped on one of this strip's pills: move the block into that
    /// tab. A drop on the strip's empty area (no pill) or back onto its own tab's pill
    /// is a no-op.
    private func performBlockDrop(blockId: String, sender: NSDraggingInfo) -> Bool {
        guard let target = pill(at: convert(sender.draggingLocation, from: nil)) else {
            dndLog("bar performBlockDrop: no pill under drop point")
            return false
        }
        let sourceTabId = sender.draggingPasteboard.string(forType: BlockDragPayload.tabIdType) ?? ""
        dndLog("bar performBlockDrop block=\(blockId.suffix(4)) srcTab=\(sourceTabId.suffix(4)) destTab=\(target.tabId.suffix(4))")
        guard target.tabId != sourceTabId else { return false }
        // Leave THIS window active after the drop (mirror the tab-drop path): the raise
        // -on-hover only ordered it front, so the source window would still be key.
        window?.makeKeyAndOrderFront(nil)
        onMoveBlockToTab?(blockId, target.tabId)
        return true
    }

    /// The pill under a point in this view's coordinates, or nil over the strip's
    /// empty regions/chrome.
    private func pill(at barPoint: NSPoint) -> TabPillView? {
        let p = tabsContainer.convert(barPoint, from: self)
        return pills.first { $0.frame.contains(p) }
    }

    /// Move the pane-drop highlight ring to `target` (nil clears it).
    private func highlightDropPill(_ target: TabPillView?) {
        for pill in pills { pill.isDropTarget = (pill === target) }
    }

    /// Whether a drop is a reorder (same workspace) rather than a cross-workspace move.
    /// Pure, so the reorder-vs-move decision is unit-testable.
    static func dropIsReorder(sourceWorkspaceId: String, destWorkspaceId: String) -> Bool {
        !sourceWorkspaceId.isEmpty && sourceWorkspaceId == destWorkspaceId
    }

    /// Reorder `tabIds` by moving `tabId` to `dropIndex` (an insertion point in the
    /// ORIGINAL list, 0...count). Pure, so the index math is unit-testable.
    static func reorderedTabIds(_ tabIds: [String], moving tabId: String, toIndex dropIndex: Int) -> [String] {
        guard let from = tabIds.firstIndex(of: tabId) else { return tabIds }
        var result = tabIds
        result.remove(at: from)
        // Removing the moving tab shifts every insertion point past it left by one.
        var insertAt = dropIndex > from ? dropIndex - 1 : dropIndex
        insertAt = max(0, min(insertAt, result.count))
        result.insert(tabId, at: insertAt)
        return result
    }

    /// The insertion index for a point in this view's coordinates: the number of pills
    /// whose midpoint along the layout axis the point has passed. Works in both
    /// orientations (X for top, Y for the flipped left container).
    func dropIndex(at barPoint: NSPoint) -> Int {
        let p = tabsContainer.convert(barPoint, from: self)
        if position == TabBarPosition.left {
            return pills.filter { p.y > $0.frame.midY }.count
        }
        return pills.filter { p.x > $0.frame.midX }.count
    }

    private func showInsertionIndicator(atIndex index: Int) {
        let thickness: CGFloat = 2
        let frame: CGRect
        if position == TabBarPosition.left {
            let y: CGFloat
            if index < pills.count {
                y = pills[index].frame.minY
            } else {
                y = pills.last?.frame.maxY ?? 0
            }
            frame = CGRect(x: 0, y: y - thickness / 2, width: tabsContainer.bounds.width, height: thickness)
        } else {
            let x: CGFloat
            if index < pills.count {
                x = pills[index].frame.minX
            } else {
                x = pills.last?.frame.maxX ?? 0
            }
            frame = CGRect(x: x - thickness / 2, y: 0, width: thickness, height: tabsContainer.bounds.height)
        }
        insertionIndicator.frame = frame
        insertionIndicator.isHidden = false
        // Keep the indicator above the pills (pills are re-added on every rebuild).
        tabsContainer.addSubview(insertionIndicator, positioned: .above, relativeTo: nil)
    }

    private func hideInsertionIndicator() {
        insertionIndicator.isHidden = true
    }
}

/// The new-tab "+" button. STYLE §4: height 22, pad-x 8, radius 6, font 12,
/// text-secondary -> hover text-primary on white@20%.
final class PlusButton: NSView {
    var onTap: (() -> Void)?
    private let label = NSTextField(labelWithString: "+")
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { refresh() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Theme.radiusMedium
        label.font = NSFont.systemFont(ofSize: 14)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 28),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    private func refresh() {
        label.textColor = isHovered ? Theme.textPrimary : Theme.textSecondary
        layer?.backgroundColor = (isHovered ? Theme.highlightBackground : NSColor.clear).cgColor
    }

    override func mouseDown(with event: NSEvent) { onTap?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// A small SF-Symbol chrome button (config/gear). Mirrors `PlusButton`'s look:
/// text-secondary -> hover text-primary on white@20%, radius 6.
final class ChromeIconButton: NSView {
    var onTap: (() -> Void)?
    private let iconView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { refresh() } }

    init(symbol: String, pointSize: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.radiusMedium
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 28),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    private func refresh() {
        iconView.contentTintColor = isHovered ? Theme.textPrimary : Theme.textSecondary
        layer?.backgroundColor = (isHovered ? Theme.highlightBackground : NSColor.clear).cgColor
    }

    override func mouseDown(with event: NSEvent) { onTap?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // A clickable chrome button shows the pointing hand (Electron parity: block.scss
    // `cursor: pointer`). Without this it inherits the underlying content cursor — the
    // terminal's I-beam — when the header sits over a terminal.
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}
