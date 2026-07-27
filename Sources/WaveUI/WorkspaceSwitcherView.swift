// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — workspace switcher button + dropdown. STYLE.md §4
// (workspaceswitcher.scss):
//   button height 22, pad 0 12, radius 6, gap 6, bg white@10% -> hover white@14%,
//   icon 15px, name 12/500 text-primary max-width 160.
//   dropdown panel width 256, radius 8, shadow 0 8px 24px rgba(0,0,0,0.8).

import AppKit
import WaveCore

/// One row in the dropdown.
public struct WorkspaceMenuItem: Equatable, Sendable {
    /// `Workspace.Meta` key under which a workspace stores its self-snapshot (mirrors Go
    /// `waveobj.MetaKey_WorkspaceSavedLayout`). Presence of this key => `hasSavedLayout`.
    public static let savedLayoutMetaKey = "workspace:savedlayout"

    public let workspaceId: String
    public let name: String
    public let icon: String?
    public let color: String?
    /// This workspace is shown in a live NSWindow right now (from the WindowManager's
    /// open windows — NOT the backend `windowid`, which lingers after a window closes).
    public let isOpen: Bool
    /// This workspace is the one shown in THIS window. Drives the checkmark badge
    /// (Electron `workspaceswitcher.tsx`: `isCurrentWorkspace ? "check" : "window"`).
    public let isCurrent: Bool
    /// A layout snapshot has been saved for this workspace — enables "Reset to Saved
    /// Layout" in the row's right-click menu.
    public let hasSavedLayout: Bool
    public init(workspaceId: String, name: String, icon: String?, color: String?,
                isOpen: Bool = false, isCurrent: Bool = false, hasSavedLayout: Bool = false) {
        self.workspaceId = workspaceId
        self.name = name
        self.icon = icon
        self.color = color
        self.isOpen = isOpen
        self.isCurrent = isCurrent
        self.hasSavedLayout = hasSavedLayout
    }
}

final class WorkspaceSwitcherView: NSView {
    var onSelectWorkspace: ((String) -> Void)?
    /// "Save" from the new-workspace composer. Carries the chosen (non-empty) name —
    /// nothing is created or persisted until the user saves.
    var onCreateWorkspace: ((String) -> Void)?
    /// Inline-rename / editor commit. Carries (workspaceId, newName).
    var onRenameWorkspace: ((String, String) -> Void)?
    /// Color-swatch pick from the editor. Carries (workspaceId, hex).
    var onSetWorkspaceColor: ((String, String) -> Void)?
    /// Icon-grid pick from the editor. Carries (workspaceId, iconName).
    var onSetWorkspaceIcon: ((String, String) -> Void)?
    /// "Save workspace" action (the active workspace is ephemeral/unsaved).
    var onSaveWorkspace: ((String) -> Void)?
    /// Editor "Delete workspace" (after confirmation). Carries the workspaceId.
    var onDeleteWorkspace: ((String) -> Void)?
    /// Row right-click "Save Layout": snapshot this workspace's tabs/panes. Carries the workspaceId.
    var onSaveWorkspaceLayout: ((String) -> Void)?
    /// Row right-click "Reset to Saved Layout": rebuild this workspace to its snapshot. Carries the workspaceId.
    var onResetWorkspaceLayout: ((String) -> Void)?

    private let button = NonDragView()
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { refreshButton() } }

    private var items: [WorkspaceMenuItem] = []
    private var activeWorkspaceId: String?
    /// Whether the ACTIVE workspace is saved (name && icon non-empty). Drives the
    /// "Save workspace" vs "Create new workspace" action in the dropdown.
    private var activeIsSaved = true
    private var paletteColors: [String] = []
    private var paletteIcons: [String] = []
    private var dropdown: LeftArrowPopover?

    /// A workspace is "saved" once it has BOTH a name and an icon; an ephemeral
    /// (unsaved) workspace is hidden from `ListWorkspaces` until saved. Mirrors
    /// Electron's `isActiveWorkspaceSaved`.
    static func isSaved(name: String?, icon: String?) -> Bool {
        (name?.isEmpty == false) && (icon?.isEmpty == false)
    }

    /// Provide the selectable color/icon palettes (from `GetColors`/`GetIcons`).
    func setPalette(colors: [String], icons: [String]) {
        paletteColors = colors
        paletteIcons = icons
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setup()
        refreshButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var mouseDownCanMoveWindow: Bool { false }

    private func setup() {
        button.wantsLayer = true
        button.layer?.cornerRadius = Theme.radiusMedium
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(iconView)

        nameField.font = NSFont(name: "Inter", size: 12) ?? .systemFont(ofSize: 12, weight: .medium)
        nameField.textColor = Theme.textPrimary
        nameField.lineBreakMode = .byTruncatingTail
        nameField.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(nameField)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.heightAnchor.constraint(equalToConstant: 22),

            iconView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),

            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Theme.actionGap),
            nameField.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -12),
            nameField.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            nameField.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
        ])
    }

    private func refreshButton() {
        button.layer?.backgroundColor = (isHovered ? NSColor.white.withAlphaComponent(0.14)
                                                    : NSColor.white.withAlphaComponent(0.10)).cgColor
    }

    /// Set the active workspace label. An ephemeral workspace (no name/icon) falls back
    /// to a generic label + symbol, and flips the dropdown to offer "Save workspace".
    func setActive(name: String?, icon: String?, color: String?, workspaceId: String?) {
        activeWorkspaceId = workspaceId
        activeIsSaved = Self.isSaved(name: name, icon: icon)
        nameField.stringValue = (name?.isEmpty == false) ? name! : "Workspace"
        let tint = (color.flatMap(Self.color(from:))) ?? Theme.accent
        iconView.image = Self.iconImage(forWaveIcon: icon)
        iconView.contentTintColor = tint
    }

    /// The default fallback SF Symbol for an unrecognized Wave icon.
    static let defaultIconSymbol = "circle.fill"

    /// Map a Wave/FontAwesome icon name to a native SF Symbol name (we don't bundle
    /// FontAwesome). Strips the `solid@`/`regular@`/`custom@` style prefix. Covers ALL
    /// of `WorkspaceService.GetIcons` (`wcore.WorkspaceIcons`) so every selectable icon
    /// renders distinctly; unknown names fall back to `defaultIconSymbol`. Exposed as a
    /// pure mapping so the icon-coverage is unit-testable.
    static func symbolName(forWaveIcon icon: String?) -> String {
        let raw = (icon?.isEmpty == false) ? icon! : "circle"
        let name = raw.contains("@") ? String(raw.split(separator: "@").last!) : raw
        let map: [String: String] = [
            // GetIcons() set (the user-selectable workspace icons).
            "wave-logo-solid": "water.waves", "triangle": "triangle.fill",
            "star": "star.fill", "heart": "heart.fill", "bolt": "bolt.fill",
            "cloud": "cloud.fill", "moon": "moon.fill",
            "layer-group": "square.3.layers.3d.down.right", "rocket": "paperplane.fill",
            "flask": "flask", "paperclip": "paperclip",
            "chart-line": "chart.line.uptrend.xyaxis", "graduation-cap": "graduationcap.fill",
            "mug-hot": "mug.fill",
            // Extra aliases seen elsewhere in the app.
            "wave-logo": "water.waves", "circle": "circle.fill", "circle-small": "circle.fill",
            "shapes": "square.on.circle.fill", "terminal": "terminal.fill",
            "globe": "globe", "folder": "folder.fill", "gear": "gearshape.fill",
            "code": "chevron.left.forwardslash.chevron.right",
            // The default widget-bar icons (widgets.json): without these the launcher
            // strip would render every button as the generic circle fallback.
            "square-terminal": "terminal.fill", "list-tree": "list.bullet.indent",
            "browser": "globe",
        ]
        return map[name] ?? defaultIconSymbol
    }

    /// Render a Wave/FontAwesome icon name as a native SF Symbol image.
    static func iconImage(forWaveIcon icon: String?) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        return NSImage(systemSymbolName: symbolName(forWaveIcon: icon), accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    /// Replace the dropdown contents.
    func setItems(_ items: [WorkspaceMenuItem]) {
        self.items = items
        if let dropdown, dropdown.isShown {
            dropdown.controller.setItems(items, active: activeWorkspaceId)
        }
    }

    override func mouseDown(with event: NSEvent) {
        toggleDropdown()
    }

    /// Right-click on the switcher button opens the layout menu (Save / Reset) for the
    /// ACTIVE workspace — left-click opens the workspace viewer (dropdown). The button's
    /// subviews (label/icon/container) don't consume mouse events, so an unhandled
    /// right-click bubbles here.
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = layoutMenuForActiveWorkspace() else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// The active workspace's right-click layout menu, or nil when there is no active
    /// workspace. "Reset to Saved Layout" is enabled only when the active workspace has a
    /// snapshot (looked up from the current items). Exposed for unit tests.
    func layoutMenuForActiveWorkspace() -> NSMenu? {
        guard let workspaceId = activeWorkspaceId else { return nil }
        let hasSaved = items.first { $0.workspaceId == workspaceId }?.hasSavedLayout ?? false
        return Self.makeLayoutMenu(
            hasSavedLayout: hasSaved,
            onSave: { [weak self] in self?.onSaveWorkspaceLayout?(workspaceId) },
            onReset: { [weak self] in self?.onResetWorkspaceLayout?(workspaceId) })
    }

    /// Build the layout context menu: "Save Layout" (always enabled) and "Reset to Saved
    /// Layout" (enabled only when a snapshot exists). `autoenablesItems = false` so the
    /// explicit `isEnabled` sticks (AppKit would otherwise validate against target/action).
    static func makeLayoutMenu(hasSavedLayout: Bool,
                               onSave: @escaping () -> Void,
                               onReset: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(title: "Save Layout", handler: onSave))
        let reset = ClosureMenuItem(title: "Reset to Saved Layout", handler: onReset)
        reset.isEnabled = hasSavedLayout
        menu.addItem(reset)
        return menu
    }

    private func toggleDropdown() {
        if let dropdown, dropdown.isShown { dropdown.close(); return }
        let controller = WorkspaceMenuController()
        controller.palette = (paletteColors, paletteIcons)
        controller.activeIsSaved = activeIsSaved
        controller.setItems(items, active: activeWorkspaceId)
        controller.onSelect = { [weak self] id in
            self?.dropdown?.close()
            self?.onSelectWorkspace?(id)
        }
        controller.onCreate = { [weak self] name in
            self?.dropdown?.close()
            self?.onCreateWorkspace?(name)
        }
        controller.onSave = { [weak self] id in
            self?.dropdown?.close()
            self?.onSaveWorkspace?(id)
        }
        controller.onRename = { [weak self] id, name in self?.onRenameWorkspace?(id, name) }
        controller.onSetColor = { [weak self] id, hex in self?.onSetWorkspaceColor?(id, hex) }
        controller.onSetIcon = { [weak self] id, icon in self?.onSetWorkspaceIcon?(id, icon) }
        controller.onDelete = { [weak self] id in
            self?.dropdown?.close()
            self?.onDeleteWorkspace?(id)
        }
        // Custom popover with a LEFT-aligned arrow: NSPopover always centers its arrow on
        // the panel, which looks detached from a left-anchored button. The panel's left
        // edge aligns with the button's left, and the arrow points down near the button's
        // icon (Electron parity for the body position, plus the left arrow).
        let dropdown = LeftArrowPopover(controller: controller, anchor: self)
        self.dropdown = dropdown
        dropdown.show()
    }

    // MARK: Hover

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

    /// Parse `#rrggbb` or a CSS-ish color name into an NSColor (best-effort).
    static func color(from s: String) -> NSColor? {
        if s.hasPrefix("#") {
            var v: UInt64 = 0
            Scanner(string: String(s.dropFirst())).scanHexInt64(&v)
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                           green: CGFloat((v >> 8) & 0xff) / 255,
                           blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
        return nil
    }
}

/// The dropdown panel content (width 256, radius 8, dark).
final class WorkspaceMenuController: NSViewController, NSTextFieldDelegate {
    var onSelect: ((String) -> Void)?
    /// New-workspace composer "Save". Carries the chosen name; fired only with a
    /// non-empty name (a new workspace is never created/persisted before this).
    var onCreate: ((String) -> Void)?
    /// "Save workspace" (active workspace is ephemeral). Carries the active workspaceId.
    var onSave: ((String) -> Void)?
    /// Editor rename commit. Carries (workspaceId, newName).
    var onRename: ((String, String) -> Void)?
    /// Editor color pick. Carries (workspaceId, hex).
    var onSetColor: ((String, String) -> Void)?
    /// Editor icon pick. Carries (workspaceId, iconName).
    var onSetIcon: ((String, String) -> Void)?
    /// Editor delete (after confirmation). Carries the workspaceId.
    var onDelete: ((String) -> Void)?

    /// Selectable palettes (from `GetColors`/`GetIcons`), set before the view loads.
    var palette: (colors: [String], icons: [String]) = ([], [])
    /// Notifies the host when the content height changes (e.g. the inline editor expands
    /// or collapses) so a custom popover window can resize to fit. Carries the new
    /// `preferredContentSize`.
    var onContentSizeChange: ((NSSize) -> Void)?
    /// Whether the active workspace is saved — drives the trailing "New workspace"
    /// (saved) vs "Save workspace" (ephemeral) action.
    var activeIsSaved = true
    /// Cap on the visible content height (set by the hosting popover from the anchor
    /// window's geometry). When the rows exceed this, the panel stops growing and the
    /// list scrolls instead — the dropdown must never be taller than the window.
    var maxContentHeight: CGFloat = .greatestFiniteMagnitude

    private var items: [WorkspaceMenuItem] = []
    private var activeId: String?
    /// The workspace whose inline editor is currently expanded (nil = none).
    private var editingId: String?
    /// The editing row's inline name field (replaces the row label while editing); kept
    /// so we can focus + select-all it right after a rebuild.
    private weak var editingNameField: NSTextField?
    /// Whether the new-workspace composer (name field + Save) is expanded in the footer.
    private(set) var creatingNew = false
    /// The composer's name field — internal so unit tests can type into it.
    weak var createNameField: NSTextField?
    private let stack = NSStackView()
    /// Fixed footer BELOW the scrollable list: holds the "+ New workspace" /
    /// "Save workspace" action or the expanded new-workspace composer, so the
    /// action stays reachable no matter how long the (scrolling) list is.
    private let footerStack = NSStackView()
    private let scrollView = NSScrollView()

    /// Trailing per-row badge: a checkmark for the current workspace, otherwise a
    /// window glyph when the workspace is open elsewhere (Electron parity). Pure
    /// mapping, exposed for unit tests.
    static func badgeSymbol(isCurrent: Bool, isOpen: Bool) -> String? {
        if isCurrent { return "checkmark" }
        if isOpen { return "macwindow" }
        return nil
    }

    /// Fixed dropdown width (STYLE §4). The HEIGHT is content-driven via
    /// `preferredContentSize` so a short list doesn't leave a big empty area below.
    static let panelWidth: CGFloat = 256

    override func loadView() {
        // The height is intentionally NOT fixed: `preferredContentSize` (set in
        // `rebuild`) sizes the popover to its rows, capped at `maxContentHeight`.
        // The stack lives inside a scroll view so an over-tall list scrolls instead
        // of pushing the panel past the window.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 16))
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.modalBackground.cgColor
        root.layer?.cornerRadius = Theme.radiusLarge
        root.layer?.masksToBounds = true

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        let doc = FlippedDocView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = doc

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        footerStack.orientation = .vertical
        footerStack.alignment = .leading
        footerStack.spacing = 2
        footerStack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footerStack.setContentHuggingPriority(.required, for: .vertical)
        footerStack.setContentCompressionResistancePriority(.required, for: .vertical)
        root.addSubview(footerStack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerStack.topAnchor),
            footerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footerStack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            doc.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: Self.panelWidth),
        ])
        view = root
    }

    /// Size the popover to its content. The popover honors `preferredContentSize`;
    /// we derive the height from the stacked rows (each carries its own height
    /// constraint) plus the stack's inter-row spacing and edge insets, so the panel
    /// fits the rows exactly with no trailing empty space — capped at
    /// `maxContentHeight` (the list scrolls beyond that).
    private func updatePreferredSize() {
        guard isViewLoaded else { return }
        let full = Self.stackContentHeight(stack) + Self.stackContentHeight(footerStack)
        preferredContentSize = NSSize(width: Self.panelWidth, height: Swift.min(full, maxContentHeight))
        onContentSizeChange?(preferredContentSize)
    }

    private static func stackContentHeight(_ s: NSStackView) -> CGFloat {
        let rows = s.arrangedSubviews
        let insets = s.edgeInsets.top + s.edgeInsets.bottom
        guard !rows.isEmpty else { return insets }
        let spacing = s.spacing * CGFloat(rows.count - 1)
        return rows.reduce(CGFloat(0)) { $0 + $1.fittingSize.height } + spacing + insets
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // `setItems` is typically called BEFORE the view loads (the controller is
        // configured, then assigned to the popover which lazily loads the view), so its
        // `rebuild()` bails on `!isViewLoaded`. Re-run it here so the stored items
        // actually render — otherwise the popover opens empty.
        rebuild()
    }

    func setItems(_ items: [WorkspaceMenuItem], active: String?) {
        self.items = items
        self.activeId = active
        rebuild()
    }

    /// The clickable rows in dropdown order: one per workspace item (scrolling list),
    /// then the trailing footer "New workspace" / "Save workspace" row. Exposed so the
    /// selection wiring is unit-testable. (The expanded editor and the new-workspace
    /// composer are NOT ClickableRows, so they are excluded.)
    var clickableRows: [ClickableRow] {
        guard isViewLoaded else { return [] }
        return (stack.arrangedSubviews + footerStack.arrangedSubviews).compactMap { $0 as? ClickableRow }
    }

    private func addArranged(_ v: NSView, to target: NSStackView) {
        target.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: target.widthAnchor, constant: -16).isActive = true
    }

    private func rebuild() {
        guard isViewLoaded else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        footerStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            addArranged(makeWorkspaceRow(item), to: stack)
            if editingId == item.workspaceId {
                addArranged(makeEditor(for: item), to: stack)
            }
        }
        if creatingNew {
            addArranged(makeCreateComposer(), to: footerStack)
        } else if activeIsSaved {
            addArranged(makeActionRow(title: "+  New workspace") { [weak self] in self?.beginCreate() }, to: footerStack)
        } else if let activeId {
            addArranged(makeActionRow(title: "Save workspace") { [weak self] in self?.onSave?(activeId) }, to: footerStack)
        }
        updatePreferredSize()
    }

    /// Expand the footer composer. No workspace exists yet at this point — creation is
    /// deferred until the user saves a non-empty name.
    func beginCreate() {
        creatingNew = true
        rebuild()
        if let field = createNameField {
            view.window?.makeKey()
            view.window?.makeFirstResponder(field)
        }
    }

    /// Collapse the composer without creating anything (Escape).
    func cancelCreate() {
        guard creatingNew else { return }
        creatingNew = false
        rebuild()
    }

    /// Commit the composer: fires `onCreate` with the trimmed name. A blank name is a
    /// no-op (the field stays up) — we never create an unnamed workspace.
    func commitCreate() {
        guard creatingNew, let field = createNameField else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        creatingNew = false
        onCreate?(name)
    }

    @objc private func saveNewTapped() { commitCreate() }

    /// Footer composer for a NEW workspace: a name field (same style as the inline
    /// rename) plus a Save button. Lives below the scrollable list so it never
    /// scrolls out of reach.
    private func makeCreateComposer() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField(string: "")
        field.font = NSFont(name: "Inter", size: 12) ?? .systemFont(ofSize: 12)
        field.placeholderString = "Workspace name"
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)
        createNameField = field

        let save = NSButton(title: "Save", target: self, action: #selector(saveNewTapped))
        save.bezelStyle = .rounded
        save.controlSize = .small
        save.font = NSFont(name: "Inter", size: 12) ?? .systemFont(ofSize: 12)
        save.setContentHuggingPriority(.required, for: .horizontal)
        save.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(save)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 30),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            save.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            save.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            save.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func makeWorkspaceRow(_ item: WorkspaceMenuItem) -> NSView {
        let active = item.workspaceId == activeId
        let isEditing = editingId == item.workspaceId
        // While editing this row inline, a click must NOT switch workspaces — the row's
        // name field owns the interaction.
        let row = ClickableRow(action: { [weak self] in
            guard self?.editingId != item.workspaceId else { return }
            self?.onSelect?(item.workspaceId)
        })
        row.wantsLayer = true
        row.layer?.cornerRadius = Theme.radiusSmall
        row.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = WorkspaceSwitcherView.iconImage(forWaveIcon: item.icon)
        iconView.contentTintColor = (item.color.flatMap(WorkspaceSwitcherView.color(from:))) ?? Theme.accent
        iconView.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(iconView)

        // While editing, the name is shown ONCE as an inline editable field that replaces
        // the row label (the editor panel below no longer carries its own name field).
        let nameView: NSView
        if isEditing {
            let field = NSTextField(string: item.name)
            field.font = NSFont(name: "Inter", size: 12) ?? .systemFont(ofSize: 12)
            field.placeholderString = "Workspace name"
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addSubview(field)
            editingNameField = field
            nameView = field
        } else {
            let label = NSTextField(labelWithString: item.name.isEmpty ? "Workspace" : item.name)
            label.font = NSFont(name: "Inter", size: 12) ?? .systemFont(ofSize: 12)
            label.textColor = active ? Theme.textPrimary : Theme.textSecondary
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(label)
            nameView = label
        }

        // Trailing edit pencil (toggles the inline editor for this row).
        let pencil = ClosureButton { [weak self] in self?.toggleEditing(item.workspaceId) }
        pencil.symbol = "pencil"
        pencil.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(pencil)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 28),
            iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),
            nameView.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Theme.actionGap),
            nameView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            pencil.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -6),
            pencil.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            pencil.widthAnchor.constraint(equalToConstant: 18),
            pencil.heightAnchor.constraint(equalToConstant: 18),
        ])

        // Whatever sits just left of the pencil bounds the name view's trailing edge: the
        // open/current badge if present, else the pencil itself.
        var trailingTarget: NSView = pencil
        if let symbol = Self.badgeSymbol(isCurrent: item.isCurrent, isOpen: item.isOpen) {
            let badge = NSImageView()
            badge.imageScaling = .scaleProportionallyUpOrDown
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            badge.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            badge.contentTintColor = item.isCurrent ? Theme.accent : Theme.textSecondary
            badge.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: pencil.leadingAnchor, constant: -4),
                badge.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                badge.widthAnchor.constraint(equalToConstant: 14),
                badge.heightAnchor.constraint(equalToConstant: 14),
            ])
            trailingTarget = badge
        }
        // The editing field STRETCHES to fill the row (equalTo); a static label only caps
        // its width so it can truncate (lessThanOrEqualTo).
        if isEditing {
            nameView.trailingAnchor.constraint(equalTo: trailingTarget.leadingAnchor, constant: -4).isActive = true
        } else {
            nameView.trailingAnchor.constraint(lessThanOrEqualTo: trailingTarget.leadingAnchor, constant: -4).isActive = true
        }

        if active { row.layer?.backgroundColor = Theme.hoverBackground.cgColor }
        return row
    }

    private func makeActionRow(title: String, action: @escaping () -> Void) -> NSView {
        let row = ClickableRow(action: action)
        row.wantsLayer = true
        row.layer?.cornerRadius = Theme.radiusSmall
        row.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = NSFont(name: "Inter", size: 12) ?? .systemFont(ofSize: 12)
        label.textColor = Theme.textSecondary
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func toggleEditing(_ id: String) {
        editingId = (editingId == id) ? nil : id
        rebuild()
        // Focus + select-all the freshly built inline name field so the row is
        // immediately editable (parity with the Electron editor's autofocus).
        if editingId != nil, let field = editingNameField {
            // Entering edit via the pencil: the popover panel is non-key (it only becomes key
            // when needed), so make it key here to activate the field editor immediately.
            view.window?.makeKey()
            view.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
            view.layoutSubtreeIfNeeded()
            field.scrollToVisible(field.bounds)
        }
    }

    /// Inline editor for one workspace: a 7-swatch color row and a 7×2 icon grid (the
    /// name is edited inline in the row itself, not here). Each pick persists immediately
    /// via the corresponding callback.
    private func makeEditor(for item: WorkspaceMenuItem) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let colorRow = NSStackView()
        colorRow.orientation = .horizontal
        colorRow.spacing = 6
        colorRow.translatesAutoresizingMaskIntoConstraints = false
        for (i, hex) in palette.colors.enumerated() {
            let b = ClosureButton { [weak self] in self?.onSetColor?(item.workspaceId, hex) }
            b.fillColor = WorkspaceSwitcherView.color(from: hex)
            b.isSelected = (item.color?.caseInsensitiveCompare(hex) == .orderedSame)
            b.tag = i
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 18).isActive = true
            b.heightAnchor.constraint(equalToConstant: 18).isActive = true
            colorRow.addArrangedSubview(b)
        }
        container.addSubview(colorRow)

        let iconGrid = NSGridView()
        iconGrid.rowSpacing = 4
        iconGrid.columnSpacing = 4
        iconGrid.translatesAutoresizingMaskIntoConstraints = false
        let perRow = 7
        var rowViews: [[NSView]] = []
        var current: [NSView] = []
        for name in palette.icons {
            let b = ClosureButton { [weak self] in self?.onSetIcon?(item.workspaceId, name) }
            b.symbol = WorkspaceSwitcherView.symbolName(forWaveIcon: name)
            b.isSelected = (item.icon == name)
            b.widthAnchor.constraint(equalToConstant: 22).isActive = true
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
            current.append(b)
            if current.count == perRow { rowViews.append(current); current = [] }
        }
        if !current.isEmpty { rowViews.append(current) }
        for r in rowViews { iconGrid.addRow(with: r) }
        container.addSubview(iconGrid)

        // Destructive "Delete workspace" action (Electron's ghost-red editor button).
        let deleteButton = NSButton(title: "Delete workspace", target: self, action: #selector(deleteTapped))
        deleteButton.isBordered = false
        deleteButton.font = NSFont(name: "Inter", size: 12) ?? .systemFont(ofSize: 12)
        deleteButton.contentTintColor = NSColor.systemRed
        deleteButton.attributedTitle = NSAttributedString(
            string: "Delete workspace",
            attributes: [.foregroundColor: NSColor.systemRed,
                         .font: NSFont(name: "Inter", size: 12) ?? NSFont.systemFont(ofSize: 12)])
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(deleteButton)

        NSLayoutConstraint.activate([
            colorRow.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            colorRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            iconGrid.topAnchor.constraint(equalTo: colorRow.bottomAnchor, constant: 8),
            iconGrid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            deleteButton.topAnchor.constraint(equalTo: iconGrid.bottomAnchor, constant: 8),
            deleteButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            deleteButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    /// Confirm + delete the workspace whose editor is open. Runs a modal NSAlert (the
    /// transient popover closes when the alert takes focus, which is fine — the action
    /// proceeds on the captured editing id).
    @objc private func deleteTapped() {
        guard let id = editingId else { return }
        // Opening the alert makes the popover resign key and close, which releases the
        // dropdown's reference chain; keep this controller alive across the modal.
        let keepAlive = self
        defer { withExtendedLifetime(keepAlive) {} }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete this workspace?"
        alert.informativeText = "This permanently deletes the workspace and all of its tabs."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onDelete?(id)
    }

    // MARK: NSTextFieldDelegate (editor name commit)

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let isComposer = (control as? NSTextField) === createNameField
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if isComposer { commitCreate() } else { commitEditorName(control.stringValue) }
            return true
        }
        if isComposer, commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelCreate()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field !== createNameField else { return }
        commitEditorName(field.stringValue)
    }

    private func commitEditorName(_ raw: String) {
        guard let id = editingId else { return }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        onRename?(id, name)
    }
}

/// Scroll-view document container: flipped so the menu rows anchor at the TOP of the
/// scrollable area (an unflipped document pins content to the bottom).
final class FlippedDocView: NSView {
    override var isFlipped: Bool { true }
}

/// A borderless closure-driven button rendering either an SF Symbol or a filled color
/// swatch. Used for the dropdown's edit pencil, color swatches, and icon grid.
final class ClosureButton: NSButton {
    private let onTap: () -> Void
    var isSelected = false { didSet { needsDisplay = true } }
    var fillColor: NSColor? { didSet { needsDisplay = true } }
    var symbol: String? {
        didSet {
            guard let symbol else { image = nil; return }
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            imagePosition = .imageOnly
        }
    }

    init(action: @escaping () -> Void) {
        self.onTap = action
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        title = ""
        wantsLayer = true
        contentTintColor = Theme.textSecondary
        target = self
        self.action = #selector(fire)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { onTap() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if let fillColor {
            let inset = bounds.insetBy(dx: 2, dy: 2)
            fillColor.setFill()
            NSBezierPath(roundedRect: inset, xRadius: 3, yRadius: 3).fill()
        }
        super.draw(dirtyRect)
        if isSelected {
            NSColor.white.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
}

/// A closure-driven `NSMenuItem` (AppKit menu items are otherwise target/action only).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }

    /// Invoke the item's action programmatically (unit tests have no mouse).
    func performAction() { handler() }
}

/// A hover-highlighting clickable row used in the dropdown.
final class ClickableRow: HoverRowView {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) { action() }

    /// Accept the very first click even when the enclosing popover window is not yet
    /// key, so selecting a workspace registers on the first click (a transient popover
    /// can swallow that click otherwise — the dropdown then "does nothing").
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Invoke the row's action programmatically (unit tests have no mouse).
    func performClick() { action() }

    override func hoverStateChanged() {
        layer?.backgroundColor = isHovered ? Theme.hoverBackground.cgColor : NSColor.clear.cgColor
    }
}

/// A minimal popover with a LEFT-aligned arrow. `NSPopover` always centers its arrow on
/// the panel, which looks detached from a left-anchored button; this hosts the
/// `WorkspaceMenuController`'s view in a borderless child panel whose left edge aligns
/// with the anchor button's left and whose arrow points up near the button's icon.
/// Dismissal mirrors `NSPopover`'s `.transient` behavior (click-outside + resign-key).
final class LeftArrowPopover {
    static let arrowHeight: CGFloat = 8
    static let arrowWidth: CGFloat = 18
    /// Arrow-tip x from the panel's left edge — placed over the button's icon.
    static let arrowInset: CGFloat = 19
    /// Vertical gap between the button's bottom and the arrow tip.
    static let gap: CGFloat = 3
    /// Breathing room kept between the panel's bottom edge and the window's bottom.
    static let bottomMargin: CGFloat = 8
    /// Floor for the scrollable content area so a pathologically short window still
    /// shows a usable list (a few rows) rather than a sliver.
    static let minContentHeight: CGFloat = 100

    let controller: WorkspaceMenuController
    private weak var anchor: NSView?
    private var panel: KeyablePanel?
    private var clickMonitor: Any?
    private var appResignObserver: Any?

    var isShown: Bool { panel != nil }

    init(controller: WorkspaceMenuController, anchor: NSView) {
        self.controller = controller
        self.anchor = anchor
    }

    func show() {
        guard let anchor, let anchorWindow = anchor.window else { return }
        let anchorScreenRect = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        // The panel must never extend past the window (or screen) bottom: cap the
        // content height to the space below the button and let the list scroll.
        let bottomLimit = Swift.max(anchorWindow.frame.minY,
                                    anchorWindow.screen?.visibleFrame.minY ?? anchorWindow.frame.minY)
        let available = anchorScreenRect.minY - Self.gap - Self.arrowHeight - bottomLimit - Self.bottomMargin
        controller.maxContentHeight = Swift.max(available, Self.minContentHeight)

        let content = controller.view // force loadView + initial sizing
        let width = WorkspaceMenuController.panelWidth
        let contentHeight = controller.preferredContentSize.height
        let totalHeight = contentHeight + Self.arrowHeight

        let root = ArrowContentView(frame: NSRect(x: 0, y: 0, width: width, height: totalHeight))
        content.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        root.addSubview(content)

        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: totalHeight),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = root
        // Keep the popover's OWN window key: the panel becomes key only when a view that
        // needs it (the inline rename field) is used. Stealing key from the parent window
        // otherwise breaks one-click focus into another window — closing a key CHILD window
        // hands key back to its parent, overriding the window the user just clicked.
        panel.becomesKeyOnlyIfNeeded = true

        // Panel left aligns with the button's left; it drops just below the button.
        let origin = NSPoint(x: anchorScreenRect.minX, y: anchorScreenRect.minY - Self.gap - totalHeight)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: totalHeight)), display: false)

        anchorWindow.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        self.panel = panel

        // Resize (keeping the arrow/top pinned) when the inline editor expands/collapses.
        controller.onContentSizeChange = { [weak self] size in self?.resize(contentHeight: size.height) }
        installClickMonitor()
        // The panel is usually non-key, so its own resign-key won't fire on an app switch;
        // dismiss on app-level deactivation instead.
        appResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.close() }
    }

    private func resize(contentHeight: CGFloat) {
        guard let panel, let root = panel.contentView else { return }
        let newTotal = contentHeight + Self.arrowHeight
        var frame = panel.frame
        frame.origin.y = frame.maxY - newTotal // pin the top, grow downward
        frame.size.height = newTotal
        panel.setFrame(frame, display: true)
        root.subviews.first?.frame = NSRect(x: 0, y: 0, width: frame.width, height: contentHeight)
        root.needsDisplay = true
    }

    private func installClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.window == panel { return event } // inside the dropdown → keep it open
            self.close()
            if let anchor = self.anchor, event.window == anchor.window {
                // Same window as the popover: it's already key, so the pass-through click
                // focuses the exact pane clicked. Swallow only the anchor button (avoid a
                // re-toggle) and let everything else through.
                if anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) {
                    return nil
                }
                return event
            }
            // A DIFFERENT window: make it key BEFORE the click dispatches so the click is a
            // normal (non-activating) click that focuses the exact pane clicked. Otherwise the
            // first click on an inactive window only activates it, leaving the wrong pane focused.
            event.window?.makeKeyAndOrderFront(nil)
            return event
        }
    }

    func close() {
        guard let panel else { return }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        if let appResignObserver {
            NotificationCenter.default.removeObserver(appResignObserver)
            self.appResignObserver = nil
        }
        controller.onContentSizeChange = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }
}

/// Borderless child panel that can still become key so the inline rename field is editable
/// (it only does so when needed — see `becomesKeyOnlyIfNeeded`).
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Fills in the popover's LEFT-aligned arrow above the hosted content. The content view
/// paints its own rounded background, so this view only draws the little triangle (in the
/// modal background color) that connects the body to the arrow tip.
final class ArrowContentView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let halfW = LeftArrowPopover.arrowWidth / 2
        let tipX = LeftArrowPopover.arrowInset
        let baseY = bounds.height - LeftArrowPopover.arrowHeight
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: tipX - halfW, y: baseY))
        tri.line(to: NSPoint(x: tipX, y: bounds.height))
        tri.line(to: NSPoint(x: tipX + halfW, y: baseY))
        tri.close()
        Theme.modalBackground.setFill()
        tri.fill()
    }
}
