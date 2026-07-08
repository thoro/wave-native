// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — a single pill tab. STYLE.md §4 (tab.scss):
//   outer width 130; inner width calc(100%-6px), radius 6, height ~26;
//   label Inter 11/500 text-secondary, centered + ellipsis;
//   active/hover inner bg = white @10%; active label #fff weight 600;
//   close button 20x20 right 4px, hidden until hover (or active); hover color
//   text-primary. Double-click the label to rename inline (Enter/blur commit,
//   Esc cancels). A `tab:flagcolor` renders as a small colored flag indicator.

import AppKit
import WaveCore

/// Pasteboard types carried by a dragged tab. The tabId identifies the tab; the source
/// workspaceId lets the destination strip tell a REORDER (same workspace) from a MOVE
/// (a different workspace, i.e. another window's strip).
enum TabDragPayload {
    static let tabIdType = NSPasteboard.PasteboardType("dev.wave.tab.id")
    static let workspaceIdType = NSPasteboard.PasteboardType("dev.wave.tab.workspaceid")
}

/// Pasteboard types carried by a dragged pane (block). The blockId identifies the
/// block; the source tabId lets a drop target treat a same-tab drop as a no-op. The
/// drag starts from a pane header (LayoutTreeView) and drops onto a tab pill — this
/// window's strip or another window's.
enum BlockDragPayload {
    static let blockIdType = NSPasteboard.PasteboardType("dev.wave.block.id")
    static let tabIdType = NSPasteboard.PasteboardType("dev.wave.block.tabid")
}

final class TabPillView: NSView, NSTextFieldDelegate {
    let tabId: String

    /// The workspace this pill belongs to. Written into the drag pasteboard so the drop
    /// target can distinguish a reorder from a cross-workspace move. Set by the strip.
    var sourceWorkspaceId: String?

    /// Movement (in points) past which a press becomes a drag, so a click/double-click is
    /// never misread as a drag.
    private static let dragThreshold: CGFloat = 4

    /// Window-space location of the press in flight, or nil once a drag started / the
    /// mouse went up. Drives the drag-threshold check in `mouseDragged`.
    private var pressLocation: NSPoint?

    var onSelect: ((String) -> Void)?
    var onClose: ((String) -> Void)?
    /// Raised when the user picks a destination from the "Move to Workspace" submenu.
    /// Carries (tabId, destinationWorkspaceId).
    var onMoveToWorkspace: ((String, String) -> Void)?
    /// Raised on an inline rename commit (Enter/blur). Carries (tabId, newName).
    var onRename: ((String, String) -> Void)?
    /// Raised from the "Flag Tab" submenu. Carries (tabId, colorHex|nil) where nil clears.
    var onSetFlagColor: ((String, String?) -> Void)?
    /// Raised from the "Background" submenu. Carries (tabId, metaPatch) where the patch is
    /// the `tab:background` / `bg*` meta to SetMeta (a `.null` value deletes a key). Built
    /// by `TabBackgroundMenu`. Mirrors `onSetFlagColor`'s SetMeta plumbing.
    var onSetTabBackground: ((String, MetaMapType) -> Void)?
    /// Raised when an inline-rename session ends (commit/cancel/blur). The owner restores
    /// window firstResponder to the active pane's terminal — the editor previously
    /// resigned to `nil`, leaving the terminal unable to receive keys after a rename.
    var onRenameSessionEnd: (() -> Void)?

    /// Workspaces this tab can be moved to (current workspace excluded, and empty when
    /// the tab is the last in its workspace). Set by the strip; drives the submenu.
    var moveTargets: [WorkspaceMenuItem] = []

    /// Config-defined background presets (the `backgrounds` map), ordered by `display:order`.
    /// Set by the strip; drives the "Background" submenu's preset rows.
    var backgroundPresets: [TabBackgroundPreset] = []

    /// The tab's current `tab:background` preset key (or nil), for the submenu checkmark.
    var backgroundPresetKey: String?

    /// The standard Wave flag colors (Electron `tabcontextmenu.ts` `FlagColors`).
    private struct FlagColor { let label: String; let value: String }
    private static let flagColors: [FlagColor] = [
        FlagColor(label: "Green", value: "#58C142"),
        FlagColor(label: "Teal", value: "#00FFDB"),
        FlagColor(label: "Blue", value: "#429DFF"),
        FlagColor(label: "Purple", value: "#BF55EC"),
        FlagColor(label: "Red", value: "#FF453A"),
        FlagColor(label: "Orange", value: "#FF9500"),
        FlagColor(label: "Yellow", value: "#FFE900"),
    ]

    private let inner = NonDragView()
    private let label = NSTextField(labelWithString: "")
    private let editor = NSTextField()
    /// Active only while renaming: commits the rename on a mouse-down outside the editor
    /// (AppKit doesn't blur the field editor here because the clicked panes/chrome don't
    /// take first responder, so `controlTextDidEndEditing` would otherwise never fire).
    private var outsideClickMonitor: Any?
    private let flagIndicator = NSImageView()
    private let bellIndicator = NSImageView()
    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isRenaming = false

    var isActive: Bool = false {
        didSet { if oldValue != isActive { refreshAppearance() } }
    }

    /// A dragged pane is hovering over this pill (it is the drop target). Draws an
    /// accent ring — a whole-pill highlight, not the reorder insertion line, since a
    /// dropped block lands IN the tab rather than between tabs.
    var isDropTarget: Bool = false {
        didSet { if oldValue != isDropTarget { needsDisplay = true } }
    }
    private var isHovered = false {
        didSet { if oldValue != isHovered { refreshAppearance() } }
    }

    var title: String = "" {
        didSet { label.stringValue = title }
    }

    /// `tab:flagcolor` (a `#rrggbb` string) or nil. Drives the flag indicator and the
    /// "Flag Tab" submenu checkmark.
    var flagColor: String? {
        didSet { if oldValue != flagColor { refreshFlag() } }
    }

    /// An unseen bell / desktop notification in this tab. Shows a small bell glyph on
    /// the (background) pill; cleared when the tab becomes active.
    var hasUnread: Bool = false {
        didSet { if oldValue != hasUnread { refreshAppearance() } }
    }

    init(tabId: String, title: String) {
        self.tabId = tabId
        super.init(frame: .zero)
        self.title = title
        wantsLayer = true
        setup()
        refreshAppearance()
        refreshFlag()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    private func setup() {
        inner.wantsLayer = true
        inner.layer?.cornerRadius = Theme.tabInnerRadius
        inner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inner)

        flagIndicator.imageScaling = .scaleProportionallyDown
        flagIndicator.isHidden = true
        flagIndicator.translatesAutoresizingMaskIntoConstraints = false
        inner.addSubview(flagIndicator)

        let bellConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        bellIndicator.image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "Unread bell")?
            .withSymbolConfiguration(bellConfig)
        bellIndicator.contentTintColor = Theme.tabActiveLabel
        bellIndicator.imageScaling = .scaleProportionallyDown
        bellIndicator.isHidden = true
        bellIndicator.translatesAutoresizingMaskIntoConstraints = false
        inner.addSubview(bellIndicator)

        label.font = Theme.tabLabelFont
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        inner.addSubview(label)

        // Inline rename editor, overlaid on the label and hidden until invoked.
        editor.font = Theme.tabLabelFont
        editor.alignment = .center
        editor.textColor = Theme.textPrimary
        editor.isBordered = false
        editor.focusRingType = .none
        editor.drawsBackground = true
        editor.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        editor.isHidden = true
        editor.delegate = self
        editor.translatesAutoresizingMaskIntoConstraints = false
        inner.addSubview(editor)

        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.imagePosition = .imageOnly
        closeButton.image = Self.xmarkImage
        closeButton.contentTintColor = Theme.textSecondary
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.isHidden = true
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        inner.addSubview(closeButton)

        NSLayoutConstraint.activate([
            // inner = width calc(100% - 6px), centered, ~26px tall.
            inner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            inner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            inner.centerYAnchor.constraint(equalTo: centerYAnchor),
            inner.heightAnchor.constraint(equalToConstant: Theme.tabInnerHeight),

            flagIndicator.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 6),
            flagIndicator.centerYAnchor.constraint(equalTo: inner.centerYAnchor),
            flagIndicator.widthAnchor.constraint(equalToConstant: 10),
            flagIndicator.heightAnchor.constraint(equalToConstant: 10),

            label.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: inner.centerYAnchor),

            editor.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 6),
            editor.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -6),
            editor.centerYAnchor.constraint(equalTo: inner.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: inner.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),

            bellIndicator.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -6),
            bellIndicator.centerYAnchor.constraint(equalTo: inner.centerYAnchor),
            bellIndicator.widthAnchor.constraint(equalToConstant: 12),
            bellIndicator.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    /// `xmark` SF Symbol at ~10pt (matches Electron's `fa-xmark`; lighter than the
    /// literal "✕" glyph this replaced).
    private static let xmarkImage: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        return NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")?
            .withSymbolConfiguration(config)
    }()

    private func refreshAppearance() {
        label.textColor = isActive ? Theme.tabActiveLabel : Theme.textSecondary
        label.font = isActive
            ? NSFontManager.shared.convert(Theme.tabLabelFont, toHaveTrait: .boldFontMask)
            : Theme.tabLabelFont
        // Close button shows on hover OR on the active tab (parity with tab.scss).
        closeButton.isHidden = isRenaming || !(isHovered || isActive)
        closeButton.contentTintColor = Theme.textPrimary
        // The unread bell sits where the close button would; show it only when the close
        // button is hidden (background tab, not hovered, not renaming) so they never overlap.
        bellIndicator.isHidden = !isUnreadVisible
        bellIndicator.needsDisplay = true
        needsDisplay = true // the active/hover fill is painted in draw(_:)
    }

    /// Whether the unread-bell indicator is currently visible. Pure mapping (an unread
    /// background tab that is not hovered/renaming), exposed for unit tests.
    var isUnreadVisible: Bool {
        hasUnread && !isActive && !isHovered && !isRenaming
    }

    /// Whether the flag indicator is currently visible. Pure mapping from `flagColor`
    /// to display state, exposed so the redraw-on-toggle behavior is unit-testable.
    var isFlagVisible: Bool {
        guard let flagColor else { return false }
        return WorkspaceSwitcherView.color(from: flagColor) != nil
    }

    private func refreshFlag() {
        guard let flagColor, let color = WorkspaceSwitcherView.color(from: flagColor) else {
            flagIndicator.isHidden = true
            flagIndicator.needsDisplay = true
            return
        }
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        flagIndicator.image = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        flagIndicator.contentTintColor = color
        flagIndicator.isHidden = false
        // Invalidate immediately so a flag set/cleared shows without waiting for an
        // unrelated relayout pass.
        flagIndicator.needsDisplay = true
        needsLayout = true
    }

    // Paint the active/hover pill fill in draw() (not a nested layer background) so
    // it composites reliably — the pill is positioned by a manual frame and a nested
    // inner layer's backgroundColor was not rendering in all paths.
    override func draw(_ dirtyRect: NSRect) {
        let innerRect = CGRect(
            x: 3, y: (bounds.height - Theme.tabInnerHeight) / 2,
            width: bounds.width - 6, height: Theme.tabInnerHeight)
        if isActive || isHovered {
            let path = NSBezierPath(
                roundedRect: innerRect, xRadius: Theme.tabInnerRadius, yRadius: Theme.tabInnerRadius)
            Theme.tabActiveFill.setFill()
            path.fill()
        }
        if isDropTarget {
            let ring = NSBezierPath(
                roundedRect: innerRect.insetBy(dx: 1, dy: 1),
                xRadius: Theme.tabInnerRadius, yRadius: Theme.tabInnerRadius)
            ring.lineWidth = 2
            Theme.accent.setStroke()
            ring.stroke()
        }
    }

    @objc private func closeTapped() {
        onClose?(tabId)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            startRename()
            return
        }
        // Record the press but do NOT select yet: selecting re-publishes the strip, and
        // setTabs removes+recreates every pill — destroying THIS view mid-gesture, after
        // which the drag falls through to the window-drag background and moves the whole
        // window. Select on mouseUp only when no drag began; a real drag starts in
        // mouseDragged (the NSDraggingSession is robust once started).
        pressLocation = event.locationInWindow
        dndLog("pill mouseDown tab=\(tabId.suffix(4)) clicks=\(event.clickCount)")
        // No window-movement freeze needed: the window has NO native drag region at all
        // (WaveWindow.isMovable == false; the strip fillers run performDrag themselves),
        // so a pill drag can never carry the window along.
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isRenaming, let start = pressLocation else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        guard (dx * dx + dy * dy) >= Self.dragThreshold * Self.dragThreshold else { return }
        pressLocation = nil
        dndLog("pill dragThreshold passed tab=\(tabId.suffix(4)) — beginning session")
        beginTabDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        // A press that never became a drag is a click → select now (deferred from mouseDown
        // so the re-publish doesn't kill this pill before a drag can start).
        guard pressLocation != nil else { return }
        pressLocation = nil
        onSelect?(tabId)
    }

    // MARK: Drag source

    /// Begin a dragging session carrying this tab, using a rendered snapshot of the pill
    /// as the drag image. NSDragging crosses NSWindows on real HID, so the snapshot can
    /// land on another window's strip (a cross-workspace move).
    private func beginTabDrag(with event: NSEvent) {
        let item = NSPasteboardItem()
        item.setString(tabId, forType: TabDragPayload.tabIdType)
        item.setString(sourceWorkspaceId ?? "", forType: TabDragPayload.workspaceIdType)

        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(bounds, contents: snapshotImage())
        beginDraggingSession(with: [dragItem], event: event, source: self)
        dndLog("pill session begun tab=\(tabId.suffix(4)) ws=\(sourceWorkspaceId?.suffix(4) ?? "nil") window=\(window != nil)")
    }

    /// A rendered snapshot of the pill (its current visual state) for use as the drag
    /// image. Exposed for a smoke test (the gesture itself needs HID).
    func snapshotImage() -> NSImage {
        let image = NSImage(size: bounds.size)
        guard bounds.width > 0, bounds.height > 0,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return image
        }
        cacheDisplay(in: bounds, to: rep)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Inline rename

    func startRename() {
        guard !isRenaming else { return }
        isRenaming = true
        editor.stringValue = title
        label.isHidden = true
        editor.isHidden = false
        closeButton.isHidden = true
        window?.makeFirstResponder(editor)
        editor.currentEditor()?.selectAll(nil)

        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isRenaming else { return event }
            if event.window !== self.window {
                self.commitRename() // click in another window → commit
                return event
            }
            let p = self.editor.convert(event.locationInWindow, from: nil)
            if !self.editor.bounds.contains(p) {
                self.commitRename()
            }
            return event
        }
    }

    func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let newName = editor.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        finishEditing()
        if !newName.isEmpty && newName != title {
            onRename?(tabId, newName)
        }
    }

    func cancelRename() {
        guard isRenaming else { return }
        isRenaming = false
        finishEditing()
    }

    private func finishEditing() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
        editor.isHidden = true
        label.isHidden = false
        refreshAppearance()
        // Resign the editor's field editor, then let the owner move firstResponder onto
        // the active pane's terminal. Resigning to `nil` alone (the old behavior) left
        // the window with NO responder, so the terminal stopped receiving keys.
        if window?.firstResponder === editor.currentEditor() {
            window?.makeFirstResponder(nil)
        }
        onRenameSessionEnd?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commitRename()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelRename()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Only reached for a blur; Enter/Esc clear `isRenaming` before resigning.
        guard isRenaming else { return }
        commitRename()
    }

    // MARK: Context menu

    /// Tab right-click menu (Electron `tabcontextmenu.ts` parity, native backing only):
    /// Rename, Copy TabId, Flag Tab ▸, Move to Workspace ▸ (when there is somewhere to
    /// move to), Close Tab.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        menu.addItem(selfItem("Rename Tab", #selector(renameMenuSelected)))
        menu.addItem(selfItem("Copy TabId", #selector(copyTabIdSelected)))
        menu.addItem(.separator())

        let flagItem = NSMenuItem(title: "Flag Tab", action: nil, keyEquivalent: "")
        let flagMenu = NSMenu()
        let none = selfItem("None", #selector(flagNoneSelected))
        none.state = (flagColor == nil) ? .on : .off
        flagMenu.addItem(none)
        for fc in Self.flagColors {
            let item = selfItem(fc.label, #selector(flagColorSelected(_:)))
            item.representedObject = fc.value
            item.image = Self.swatch(hex: fc.value)
            item.state = (flagColor?.caseInsensitiveCompare(fc.value) == .orderedSame) ? .on : .off
            flagMenu.addItem(item)
        }
        flagItem.submenu = flagMenu
        menu.addItem(flagItem)
        menu.addItem(.separator())

        menu.addItem(buildBackgroundItem())
        menu.addItem(.separator())

        if !moveTargets.isEmpty {
            let moveItem = NSMenuItem(title: "Move to Workspace", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for target in moveTargets {
                let item = selfItem(
                    target.name.isEmpty ? "Workspace" : target.name, #selector(moveToWorkspaceSelected(_:)))
                item.representedObject = target.workspaceId
                submenu.addItem(item)
            }
            moveItem.submenu = submenu
            menu.addItem(moveItem)
            menu.addItem(.separator())
        }

        menu.addItem(selfItem("Close Tab", #selector(closeMenuSelected)))
        return menu
    }

    private func selfItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// A small filled-circle color swatch for the flag submenu rows.
    private static func swatch(hex: String) -> NSImage? {
        guard let color = WorkspaceSwitcherView.color(from: hex) else { return nil }
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    @objc private func renameMenuSelected() { startRename() }

    @objc private func copyTabIdSelected() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tabId, forType: .string)
    }

    @objc private func flagNoneSelected() { onSetFlagColor?(tabId, nil) }

    @objc private func flagColorSelected(_ sender: NSMenuItem) {
        onSetFlagColor?(tabId, sender.representedObject as? String)
    }

    /// The "Background" submenu: config presets (checkmark on the active one), a few solid
    /// color swatches, and "Clear Background". Each row carries the SetMeta patch it should
    /// apply (built by `TabBackgroundMenu`) in `representedObject`, so the selection handler
    /// is a single pass-through — the same shape as the flag submenu.
    private func buildBackgroundItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Background", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let clear = selfItem("Clear Background", #selector(backgroundSelected(_:)))
        clear.representedObject = TabBackgroundMenu.clearPatch()
        clear.state = (backgroundPresetKey == nil) ? .on : .off
        submenu.addItem(clear)

        if !backgroundPresets.isEmpty {
            submenu.addItem(.separator())
            for preset in backgroundPresets {
                let row = selfItem(preset.displayName, #selector(backgroundSelected(_:)))
                row.representedObject = TabBackgroundMenu.presetPatch(preset.key)
                row.state = (backgroundPresetKey == preset.key) ? .on : .off
                submenu.addItem(row)
            }
        }

        submenu.addItem(.separator())
        for color in TabBackgroundMenu.solidColors {
            let row = selfItem(color.label, #selector(backgroundSelected(_:)))
            row.representedObject = TabBackgroundMenu.colorPatch(hex: color.value)
            row.image = Self.swatch(hex: color.value)
            submenu.addItem(row)
        }

        item.submenu = submenu
        return item
    }

    @objc private func backgroundSelected(_ sender: NSMenuItem) {
        guard let patch = sender.representedObject as? MetaMapType else { return }
        onSetTabBackground?(tabId, patch)
    }

    @objc private func moveToWorkspaceSelected(_ sender: NSMenuItem) {
        guard let workspaceId = sender.representedObject as? String else { return }
        onMoveToWorkspace?(tabId, workspaceId)
    }

    @objc private func closeMenuSelected() { onClose?(tabId) }

    // MARK: Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// Pure builders for the SetMeta patches the tab "Background" submenu applies. Kept
/// free of AppKit so the patch a preset / solid color / clear produces is unit-testable.
/// The keys match `pkg/waveobj/metaconsts.go` (`tab:background` / `bg` / `bg:opacity` /
/// `bg:blendmode`); a `.null` value is SetMeta's delete sentinel.
enum TabBackgroundMenu {
    static let keyTabBackground = "tab:background"
    static let keyBg = "bg"
    static let keyBgOpacity = "bg:opacity"
    static let keyBgBlendMode = "bg:blendmode"

    /// Element opacity defaulted for a solid color, matching `TabBackgroundView`'s
    /// renderer default (0.5) so a freshly-picked color reads as a tint, not a fill.
    static let defaultColorOpacity: Double = 0.5

    struct SolidColor { let label: String; let value: String }

    /// A small palette of solid tab backgrounds (the same hues as the flag colors).
    static let solidColors: [SolidColor] = [
        SolidColor(label: "Blue", value: "#429DFF"),
        SolidColor(label: "Green", value: "#58C142"),
        SolidColor(label: "Red", value: "#FF453A"),
        SolidColor(label: "Purple", value: "#BF55EC"),
        SolidColor(label: "Orange", value: "#FF9500"),
    ]

    /// Apply a named preset: set `tab:background`, and clear inline `bg*` so the preset is
    /// the unambiguous source (the renderer prefers `tab:background` over inline `bg`).
    static func presetPatch(_ key: String) -> MetaMapType {
        [keyTabBackground: .string(key), keyBg: .null, keyBgOpacity: .null, keyBgBlendMode: .null]
    }

    /// Apply a solid color via inline `bg` + a default opacity, clearing any named preset.
    static func colorPatch(hex: String, opacity: Double = defaultColorOpacity) -> MetaMapType {
        [keyBg: .string(hex), keyBgOpacity: .double(opacity),
         keyTabBackground: .null, keyBgBlendMode: .null]
    }

    /// Remove every background key (no preset, no inline color).
    static func clearPatch() -> MetaMapType {
        [keyTabBackground: .null, keyBg: .null, keyBgOpacity: .null, keyBgBlendMode: .null]
    }
}

extension TabPillView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // .move works both within the strip (reorder) and across windows (move).
        .move
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        dndLog("pill session ended tab=\(tabId.suffix(4)) op=\(operation.rawValue)")
    }
}
