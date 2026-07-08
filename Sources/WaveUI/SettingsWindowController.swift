// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — the app-level Settings window. The native equivalent of Electron's
// settings block (a JSON editor over settings.json): a single shared NSWindow of
// typed controls that READ the live values from the coordinator's
// `currentSettings()` and WRITE each change through the typed `setconfig` RPC
// (`AppCoordinator.setConfigValue`). This is deliberately NOT a per-pane settings
// dialog — the block "…" menu already mirrors Electron's per-pane settings.
//
// One shared instance (static `shared`) so Cmd-, / the gear / the menu from ANY
// window all focus the SAME window. The presenting window hands us its coordinator
// (config read/write seam); a `config` event re-pull posts
// `AppCoordinator.configReloadedNotification`, which we observe to refresh controls
// (so a change from this window — or another window — reflects live).
//
// Every control here drives something live: window/terminal/web settings are read
// at view creation AND re-applied on the config-reload notification (terminal font +
// transparency rebuild in place, window transparency/opacity/blur re-apply to the
// NSWindow). `term:theme` is the GLOBAL default theme (a pane's "Theme" submenu
// overrides it per-block). The only setting intentionally NOT shown is
// `telemetry:enabled` (forced off at bootstrap), so the window never exposes a dead
// control.
//
// Layout: a System-Settings-style form built on a single NSGridView with two columns
// — [right-aligned label] | [left-aligned control] — so every row shares ONE control
// column width and a tight, consistent row rhythm. Section headers are full-width rows
// (merged across both columns). The grid lives inside a scroll view so the form can
// exceed the window height without resizing it.

import AppKit
import WaveCore

@MainActor
public final class SettingsWindowController: NSWindowController {
    public static let shared = SettingsWindowController()

    // Fixed form geometry. A single control-column width is what makes the rows read as
    // an aligned native form rather than the old ragged right-edge controls.
    private static let contentWidth: CGFloat = 520
    private static let controlWidth: CGFloat = 220
    private static let margin: CGFloat = 20
    /// One fixed control height so text fields / popups read as a uniform native form
    /// (NSTextField's intrinsic height varies with font; pinning it stops the ragged rows).
    private static let controlHeight: CGFloat = 22

    /// The coordinator whose config we read/write — the presenting window's. Updated
    /// on every `present` so Cmd-, from a different window retargets the live config.
    private weak var coordinator: AppCoordinator?

    /// The two-column form OF THE TAB CURRENTLY BEING BUILT. Row builders append
    /// to this; buildUI points it at each tab's grid in turn.
    private var grid: NSGridView!

    /// One System-Settings-style toolbar tab per section group.
    private struct SettingsTab {
        let id: NSToolbarItem.Identifier
        let title: String
        let symbol: String
        let build: (SettingsWindowController) -> Void
    }

    private static let tabs: [SettingsTab] = [
        SettingsTab(id: .init("general"), title: "General", symbol: "gearshape") { $0.buildGeneralTab() },
        SettingsTab(id: .init("terminal"), title: "Terminal", symbol: "terminal") { $0.buildTerminalTab() },
        SettingsTab(id: .init("web"), title: "Web", symbol: "globe") { $0.buildWebTab() },
        SettingsTab(id: .init("connections"), title: "Connections", symbol: "network") { $0.buildConnectionsTab() },
        SettingsTab(id: .init("buffers"), title: "Buffers", symbol: "archivebox") { $0.buildBuffersTab() },
    ]

    /// Pre-built scrollable content per tab id (all controls exist up front, so
    /// the config refresh handlers cover every tab regardless of selection).
    private var tabViews: [NSToolbarItem.Identifier: NSView] = [:]
    private var scroll: NSScrollView!

    /// Per-control closures that re-apply the live config value to their control.
    /// Invoked on `present` and on every config-reload notification.
    private var refreshHandlers: [() -> Void] = []

    /// Retained action/delegate adapters (controls hold unowned target/delegate).
    private var retainedAdapters: [AnyObject] = []

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.windowBackground
        window.isReleasedWhenClosed = false
        // Fixed width (one aligned form column), free height.
        window.contentMinSize = NSSize(width: Self.contentWidth, height: 280)
        window.contentMaxSize = NSSize(width: Self.contentWidth, height: 10_000)
        window.toolbarStyle = .preference
        window.center()
        super.init(window: window)
        buildUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(configReloaded),
            name: AppCoordinator.configReloadedNotification, object: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Presentation

    /// Show (and bring to front) the single Settings window, targeting `coordinator`'s
    /// config. Reads current values before showing so the controls open populated.
    public func present(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        // Show FIRST: refresh handlers that load async data (the scrollback
        // buffers list) no-op while the window is not visible.
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshFromConfig()
    }

    @objc private func configReloaded(_ note: Notification) {
        // Refresh on the main actor; the post may originate off the presenting window.
        Task { @MainActor in self.refreshFromConfig() }
    }

    private func refreshFromConfig() {
        refreshHandlers.forEach { $0() }
    }

    private func settings() -> [String: JSONValue] {
        coordinator?.currentSettings() ?? [:]
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let window else { return }
        scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        window.contentView = content

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        // Build every tab's grid up front (refresh handlers then cover all
        // controls), each inside its own flipped scroll document.
        for tab in Self.tabs {
            grid = NSGridView(numberOfColumns: 2, rows: 0)
            grid.translatesAutoresizingMaskIntoConstraints = false
            grid.columnSpacing = 16
            grid.rowSpacing = 10
            grid.column(at: 0).xPlacement = .trailing
            grid.column(at: 1).xPlacement = .leading
            // Pin the control column to one fixed width — the single source of the
            // form's alignment. Controls that should fill it carry a matching width.
            grid.column(at: 1).width = Self.controlWidth

            let doc = FlippedContainer()
            doc.translatesAutoresizingMaskIntoConstraints = false
            doc.addSubview(grid)
            NSLayoutConstraint.activate([
                grid.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: Self.margin),
                grid.topAnchor.constraint(equalTo: doc.topAnchor, constant: Self.margin),
                grid.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -Self.margin),
                doc.bottomAnchor.constraint(equalTo: grid.bottomAnchor, constant: Self.margin),
            ])
            tab.build(self)
            tabViews[tab.id] = doc
        }

        let toolbar = NSToolbar(identifier: "settings-tabs")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        toolbar.selectedItemIdentifier = Self.tabs[0].id
        selectTab(Self.tabs[0].id)
    }

    /// Swap the visible tab: point the scroll view at its document and lock the
    /// document width to the viewport so the form never scrolls sideways.
    private func selectTab(_ id: NSToolbarItem.Identifier) {
        guard let doc = tabViews[id], let tab = Self.tabs.first(where: { $0.id == id }) else { return }
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        window?.title = tab.title
        if id.rawValue == "buffers" {
            reloadScrollbackList()
        }
    }

    @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
        selectTab(sender.itemIdentifier)
    }

    private func buildGeneralTab() {
        // Window transparency/opacity/blur is PER-WINDOW and lives in the gear popover
        // (each window is independent), so it is intentionally NOT here.
        addSection("Appearance")
        addPopupRow("Tab bar position", key: "app:tabbar",
                    options: [("Top", "top"), ("Left", "left")], defaultValue: "top")

        addSection("Notifications", subtitle: "Desktop alerts for terminal bells + OSC 9")
        addBoolRow("Enable notifications", key: "notification:enabled", defaultValue: true)
    }

    private func buildTerminalTab() {
        addSection("Terminal", subtitle: "Applies live to open terminals")
        addFontSizeRow("Font size", key: "term:fontsize")
        addFontFamilyRow("Font family", key: "term:fontfamily")
        addSliderRow("Transparency", key: "term:transparency", min: 0.0, max: 1.0, defaultValue: 0.0)
        // Global default term theme (a pane's "Theme" submenu overrides it per-block).
        addThemeRow("Default theme", key: "term:theme")

        addSection("Scrollback")
        // On-disk retention: unlimited keeps the term file unbounded (default 256MB
        // window). Applies when a shell (re)starts; overridable per block via meta.
        addBoolRow("Unlimited scrollback (disk)", key: "term:unlimitedscrollback")
        // In-memory live buffer (lines). Older history stays reachable by scrolling —
        // it pages in from disk on demand. Applies to newly created panes.
        addIntRow("Live buffer lines", key: "term:scrollback", placeholder: "15000")
        addCaption("Scrolling past the live buffer pages older history in from disk; " +
                   "unlimited keeps that history forever instead of the default 256MB window.")
    }

    private func buildWebTab() {
        addSection("Web")
        addTextRow("Default URL", key: "web:defaulturl", placeholder: "https://example.com",
                   monospace: true)
        addTextRow("Default search", key: "web:defaultsearch",
                   placeholder: "https://google.com/search?q={query}", monospace: true)
        addBoolRow("Open links internally", key: "web:openlinksinternally")
    }

    private func buildConnectionsTab() {
        addSection("Connections")
        addBoolRow("wsh enabled", key: "conn:wshenabled")
        addBoolRow("Ask before wsh install", key: "conn:askbeforewshinstall")
        addTextRow("Local host display name", key: "conn:localhostdisplayname",
                   placeholder: "local")
    }

    private func buildBuffersTab() {
        addSection("Scrollback buffers", subtitle: "Terminal history stored on disk (zstd-compressed)")
        addScrollbackListRow()
    }

    private func buildSections() {
        // Window transparency/opacity/blur is PER-WINDOW and lives in the gear popover
        // (each window is independent), so it is intentionally NOT here.
        addSection("Appearance")
        addPopupRow("Tab bar position", key: "app:tabbar",
                    options: [("Top", "top"), ("Left", "left")], defaultValue: "top")

        addSection("Terminal", subtitle: "Applies live to open terminals")
        addFontSizeRow("Font size", key: "term:fontsize")
        addFontFamilyRow("Font family", key: "term:fontfamily")
        addSliderRow("Transparency", key: "term:transparency", min: 0.0, max: 1.0, defaultValue: 0.0)
        // Global default term theme (a pane's "Theme" submenu overrides it per-block).
        addThemeRow("Default theme", key: "term:theme")
        // On-disk retention: unlimited keeps the term file unbounded (default 256MB
        // window). Applies when a shell (re)starts; overridable per block via meta.
        addBoolRow("Unlimited scrollback (disk)", key: "term:unlimitedscrollback")
        // In-memory live buffer (lines). Older history stays reachable by scrolling —
        // it pages in from disk on demand. Applies to newly created panes.
        addIntRow("Live buffer lines", key: "term:scrollback", placeholder: "15000")
        addCaption("Scrolling past the live buffer pages older history in from disk; " +
                   "unlimited keeps that history forever instead of the default 256MB window.")

        addSection("Web")
        addTextRow("Default URL", key: "web:defaulturl", placeholder: "https://example.com",
                   monospace: true)
        addTextRow("Default search", key: "web:defaultsearch",
                   placeholder: "https://google.com/search?q={query}", monospace: true)
        addBoolRow("Open links internally", key: "web:openlinksinternally")

        addSection("Notifications", subtitle: "Desktop alerts for terminal bells + OSC 9")
        addBoolRow("Enable notifications", key: "notification:enabled", defaultValue: true)

        addSection("Connections")
        addBoolRow("wsh enabled", key: "conn:wshenabled")
        addBoolRow("Ask before wsh install", key: "conn:askbeforewshinstall")
        addTextRow("Local host display name", key: "conn:localhostdisplayname",
                   placeholder: "local")

        addSection("Scrollback buffers", subtitle: "Terminal history stored on disk (zstd-compressed)")
        addScrollbackListRow()
    }

    // MARK: - Section / row builders

    private func addSection(_ title: String, subtitle: String? = nil) {
        let header = NSTextField(labelWithString: title)
        header.font = Theme.headerFont
        header.textColor = Theme.textPrimary
        // First header hugs the top margin; later ones get breathing room above.
        addSpanningRow(header, topPadding: grid.numberOfRows == 0 ? 0 : 18)
        guard let subtitle else { return }
        let sub = NSTextField(labelWithString: subtitle)
        sub.font = NSFont.systemFont(ofSize: 11)
        sub.textColor = Theme.textSecondary
        addSpanningRow(sub, topPadding: 2)
    }

    /// Small secondary explainer text under a group of rows.
    private func addCaption(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = Theme.textSecondary
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = Self.contentWidth - 2 * Self.margin
        addSpanningRow(label, topPadding: 2)
    }

    /// Add a full-width row (header / caption) spanning both columns at the left margin.
    private func addSpanningRow(_ view: NSView, topPadding: CGFloat) {
        let row = grid.addRow(with: [view])
        let r = grid.numberOfRows - 1
        grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2),
                        verticalRange: NSRange(location: r, length: 1))
        grid.cell(atColumnIndex: 0, rowIndex: r).xPlacement = .leading
        row.yPlacement = .center
        row.topPadding = topPadding
    }

    /// A [label | control] form row. Label trailing in column 0, control leading in
    /// column 1, both vertically centered.
    @discardableResult
    private func addRow(_ title: String, control: NSView) -> Int {
        let label = NSTextField(labelWithString: title)
        label.font = Theme.uiFont
        label.textColor = Theme.textSecondary
        label.lineBreakMode = .byTruncatingTail
        let row = grid.addRow(with: [label, control])
        row.yPlacement = .center
        return grid.numberOfRows - 1
    }

    private func addBoolRow(_ title: String, key: String, defaultValue: Bool = false) {
        let toggle = NSSwitch()
        let target = ControlAction { [weak self] sender in
            guard let toggle = sender as? NSSwitch else { return }
            self?.coordinator?.setConfigValue(key, .bool(toggle.state == .on))
        }
        toggle.target = target
        toggle.action = #selector(ControlAction.fire(_:))
        retainedAdapters.append(target)
        // Switches sit at the trailing edge of the control column (they have no natural
        // width to fill it), which keeps them visually aligned down the right side.
        let r = addRow(title, control: toggle)
        grid.cell(atColumnIndex: 1, rowIndex: r).xPlacement = .trailing
        refreshHandlers.append { [weak self, weak toggle] in
            guard let self, let toggle else { return }
            toggle.state = (self.settings()[key]?.boolValue ?? defaultValue) ? .on : .off
        }
    }

    private func addSliderRow(_ title: String, key: String, min: Double, max: Double, defaultValue: Double) {
        let slider = NSSlider(value: defaultValue, minValue: min, maxValue: max,
                              target: nil, action: nil)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        let target = ControlAction { [weak self] sender in
            guard let slider = sender as? NSSlider else { return }
            self?.coordinator?.setConfigValue(key, .double(slider.doubleValue))
        }
        slider.target = target
        slider.action = #selector(ControlAction.fire(_:))
        retainedAdapters.append(target)
        addRow(title, control: slider)
        refreshHandlers.append { [weak self, weak slider] in
            guard let self, let slider else { return }
            slider.doubleValue = self.settings()[key]?.doubleValue ?? defaultValue
        }
    }

    /// Font size as a small number field paired with a stepper, so the current value is
    /// always visible (the old bare text field read as an empty broken box).
    private func addFontSizeRow(_ title: String, key: String) {
        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        Self.styleTextField(field, monospace: false)
        field.alignment = .center
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        field.heightAnchor.constraint(equalToConstant: Self.controlHeight).isActive = true

        let stepper = NSStepper()
        stepper.translatesAutoresizingMaskIntoConstraints = false
        stepper.minValue = 6
        stepper.maxValue = 72
        stepper.increment = 1
        stepper.valueWraps = false

        let stepperTarget = ControlAction { [weak self, weak field] sender in
            guard let stepper = sender as? NSStepper else { return }
            field?.stringValue = Self.trimFloat(stepper.doubleValue)
            self?.coordinator?.setConfigValue(key, .double(stepper.doubleValue))
        }
        stepper.target = stepperTarget
        stepper.action = #selector(ControlAction.fire(_:))
        retainedAdapters.append(stepperTarget)

        let observer = TextCommitObserver { [weak self, weak stepper] f in
            guard let self else { return }
            let trimmed = f.stringValue.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                self.coordinator?.setConfigValue(key, nil)
                return
            }
            guard let d = Double(trimmed) else {
                self.refreshFromConfig() // restore the last valid value on bad input
                return
            }
            stepper?.doubleValue = d
            self.coordinator?.setConfigValue(key, .double(d))
        }
        field.delegate = observer
        retainedAdapters.append(observer)

        let combo = NSStackView(views: [field, stepper])
        combo.orientation = .horizontal
        combo.alignment = .centerY
        combo.spacing = 6
        addRow(title, control: combo)
        refreshHandlers.append { [weak self, weak field, weak stepper] in
            guard let self, let field, let stepper else { return }
            // Show the live size, or the terminal default when unset — never an empty box.
            let value = self.settings()[key]?.doubleValue ?? Double(Theme.terminalFontSize)
            field.stringValue = Self.trimFloat(value)
            stepper.doubleValue = value
        }
    }

    /// Font family as a popup of the system's monospaced families, with the current
    /// value selected (and inserted if it is a family we did not enumerate).
    private func addFontFamilyRow(_ title: String, key: String) {
        let popup = makePopup()
        let families = Self.monospacedFontFamilies()
        let target = ControlAction { [weak self] sender in
            guard let popup = sender as? NSPopUpButton, let value = popup.titleOfSelectedItem else { return }
            self?.coordinator?.setConfigValue(key, .string(value))
        }
        popup.target = target
        popup.action = #selector(ControlAction.fire(_:))
        retainedAdapters.append(target)
        addRow(title, control: popup)
        refreshHandlers.append { [weak self, weak popup] in
            guard let self, let popup else { return }
            let current = self.settings()[key]?.stringValue
            var items = families
            if let current, !items.contains(current) { items.insert(current, at: 0) }
            popup.removeAllItems()
            popup.addItems(withTitles: items)
            if let current { popup.selectItem(withTitle: current) }
        }
    }

    /// Default term theme as a popup of the coordinator's term themes (display name shown,
    /// `name` written), rebuilt on each refresh so config-defined themes stay live.
    private func addThemeRow(_ title: String, key: String) {
        let popup = makePopup()
        let target = ControlAction { [weak self] sender in
            guard let popup = sender as? NSPopUpButton,
                  let value = popup.selectedItem?.representedObject as? String else { return }
            self?.coordinator?.setConfigValue(key, .string(value))
        }
        popup.target = target
        popup.action = #selector(ControlAction.fire(_:))
        retainedAdapters.append(target)
        addRow(title, control: popup)
        refreshHandlers.append { [weak self, weak popup] in
            guard let self, let popup else { return }
            popup.removeAllItems()
            let items = self.coordinator?.termThemeMenuItems() ?? []
            for item in items {
                popup.addItem(withTitle: item.displayName)
                popup.lastItem?.representedObject = item.name
            }
            let current = self.settings()[key]?.stringValue
            if let current, let idx = items.firstIndex(where: { $0.name == current }) {
                popup.selectItem(at: idx)
            }
        }
    }

    /// Integer setting as a text field (the backend requires a JSON int for keys
    /// like `term:scrollback`); an empty commit deletes the key.
    private func addIntRow(_ title: String, key: String, placeholder: String? = nil) {
        let field = makeTextField(width: 80, monospace: false)
        field.placeholderString = placeholder
        field.alignment = .right
        let observer = TextCommitObserver { [weak self] f in
            let value = f.stringValue.trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                self?.coordinator?.setConfigValue(key, nil)
            } else if let n = Int64(value) {
                self?.coordinator?.setConfigValue(key, .int(n))
            }
        }
        field.delegate = observer
        retainedAdapters.append(observer)
        addRow(title, control: field)
        refreshHandlers.append { [weak self, weak field] in
            guard let self, let field else { return }
            if let n = self.settings()[key]?.intValue {
                field.stringValue = String(n)
            } else {
                field.stringValue = ""
            }
        }
    }

    // MARK: - Scrollback buffers overview

    /// Vertical stack rebuilt on each refresh with one row per stored buffer.
    private var scrollbackStack: NSStackView?

    /// The entries behind the currently rendered buffer rows (Clear All input).
    private var scrollbackEntries: [TermScrollbackEntry] = []

    private func addScrollbackListRow() {
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let refresh = NSButton(title: "Refresh", target: nil, action: nil)
        refresh.bezelStyle = .accessoryBarAction
        refresh.controlSize = .small
        let refreshTarget = ControlAction { [weak self] _ in self?.reloadScrollbackList() }
        refresh.target = refreshTarget
        refresh.action = #selector(ControlAction.fire(_:))
        retainedAdapters.append(refreshTarget)
        buttons.addArrangedSubview(refresh)

        let clearAll = NSButton(title: "Clear All", target: nil, action: nil)
        clearAll.bezelStyle = .accessoryBarAction
        clearAll.controlSize = .small
        let clearAllTarget = ControlAction { [weak self] _ in self?.confirmClearAllBuffers() }
        clearAll.target = clearAllTarget
        clearAll.action = #selector(ControlAction.fire(_:))
        retainedAdapters.append(clearAllTarget)
        buttons.addArrangedSubview(clearAll)

        addSpanningRow(buttons, topPadding: 4)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollbackStack = stack
        addSpanningRow(stack, topPadding: 6)
        refreshHandlers.append { [weak self] in self?.reloadScrollbackList() }
    }

    private func reloadScrollbackList() {
        guard let coordinator, window?.isVisible == true else { return }
        if scrollbackStack?.arrangedSubviews.isEmpty ?? false {
            let loading = NSTextField(labelWithString: "Loading…")
            loading.font = NSFont.systemFont(ofSize: 11)
            loading.textColor = Theme.textSecondary
            scrollbackStack?.addArrangedSubview(loading)
        }
        Task { @MainActor [weak self] in
            let entries = (try? await coordinator.termScrollbackList()) ?? []
            self?.scrollbackEntries = entries
            self?.rebuildScrollbackRows(entries)
        }
    }

    private func confirmClearAllBuffers() {
        guard let window, !scrollbackEntries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Clear ALL terminal buffers?"
        alert.informativeText = "This permanently deletes the stored scrollback of every terminal (\(scrollbackEntries.count) buffers)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let coordinator = self.coordinator else { return }
            let ids = self.scrollbackEntries.map(\.blockid)
            Task { @MainActor in
                for blockId in ids {
                    try? await coordinator.termClearBuffer(blockId: blockId)
                }
                self.reloadScrollbackList()
            }
        }
    }

    private func rebuildScrollbackRows(_ entries: [TermScrollbackEntry]) {
        guard let stack = scrollbackStack else { return }
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if entries.isEmpty {
            let empty = NSTextField(labelWithString: "No stored buffers")
            empty.font = NSFont.systemFont(ofSize: 11)
            empty.textColor = Theme.textSecondary
            stack.addArrangedSubview(empty)
            return
        }
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        for entry in entries.sorted(by: { ($0.disksize ?? 0) > ($1.disksize ?? 0) }) {
            stack.addArrangedSubview(makeScrollbackRow(entry, formatter: fmt))
        }
    }

    private func makeScrollbackRow(_ entry: TermScrollbackEntry, formatter: ByteCountFormatter) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        var name: String
        if entry.orphaned == true {
            name = "(orphaned) \(entry.blockid.prefix(8))"
        } else {
            let ws = entry.workspacename.flatMap { $0.isEmpty ? nil : $0 }
            let tab = entry.tabname.flatMap { $0.isEmpty ? nil : $0 } ?? String(entry.tabid?.prefix(8) ?? "")
            let conn = entry.connection.flatMap { $0.isEmpty ? nil : $0 } ?? "local"
            name = [ws, tab].compactMap { $0 }.joined(separator: " / ") + " — " + conn
        }
        let label = NSTextField(labelWithString: name)
        label.font = Theme.uiFont
        label.textColor = Theme.textPrimary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 230).isActive = true

        var sizeText = formatter.string(fromByteCount: entry.disksize ?? entry.size ?? 0)
        if entry.unlimited == true { sizeText += " · unlimited" }
        let size = NSTextField(labelWithString: sizeText)
        size.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        size.textColor = Theme.textSecondary
        size.alignment = .right
        size.translatesAutoresizingMaskIntoConstraints = false
        size.widthAnchor.constraint(equalToConstant: 100).isActive = true

        row.addArrangedSubview(label)
        row.addArrangedSubview(size)

        if entry.orphaned != true, let tabId = entry.tabid {
            let goButton = NSButton(title: "Go to", target: nil, action: nil)
            goButton.bezelStyle = .accessoryBarAction
            goButton.controlSize = .small
            let goTarget = ControlAction { [weak self] _ in
                self?.coordinator?.navigateToBlock(tabId: tabId, blockId: entry.blockid)
            }
            goButton.target = goTarget
            goButton.action = #selector(ControlAction.fire(_:))
            retainedAdapters.append(goTarget)
            row.addArrangedSubview(goButton)
        }

        let clearButton = NSButton(title: "Clear", target: nil, action: nil)
        clearButton.bezelStyle = .accessoryBarAction
        clearButton.controlSize = .small
        let clearTarget = ControlAction { [weak self] _ in
            self?.confirmClearBuffer(entry, name: name)
        }
        clearButton.target = clearTarget
        clearButton.action = #selector(ControlAction.fire(_:))
        retainedAdapters.append(clearTarget)
        row.addArrangedSubview(clearButton)
        return row
    }

    private func confirmClearBuffer(_ entry: TermScrollbackEntry, name: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Clear terminal buffer?"
        alert.informativeText = "This permanently deletes the stored scrollback for \(name)."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, let coordinator = self.coordinator else { return }
            Task { @MainActor in
                try? await coordinator.termClearBuffer(blockId: entry.blockid)
                self.reloadScrollbackList()
            }
        }
    }

    private func addTextRow(_ title: String, key: String, placeholder: String? = nil,
                            monospace: Bool = false) {
        let field = makeTextField(width: Self.controlWidth, monospace: monospace)
        field.placeholderString = placeholder
        let observer = TextCommitObserver { [weak self] f in
            let value = f.stringValue.trimmingCharacters(in: .whitespaces)
            self?.coordinator?.setConfigValue(key, value.isEmpty ? nil : .string(value))
        }
        field.delegate = observer
        retainedAdapters.append(observer)
        addRow(title, control: field)
        refreshHandlers.append { [weak self, weak field] in
            guard let self, let field else { return }
            field.stringValue = self.settings()[key]?.stringValue ?? ""
        }
    }

    private func addPopupRow(_ title: String, key: String,
                             options: [(label: String, value: String)], defaultValue: String) {
        let popup = makePopup()
        for opt in options {
            popup.addItem(withTitle: opt.label)
            popup.lastItem?.representedObject = opt.value
        }
        let target = ControlAction { [weak self] sender in
            guard let popup = sender as? NSPopUpButton,
                  let value = popup.selectedItem?.representedObject as? String else { return }
            self?.coordinator?.setConfigValue(key, .string(value))
        }
        popup.target = target
        popup.action = #selector(ControlAction.fire(_:))
        retainedAdapters.append(target)
        addRow(title, control: popup)
        refreshHandlers.append { [weak self, weak popup] in
            guard let self, let popup else { return }
            let current = self.settings()[key]?.stringValue ?? defaultValue
            let idx = options.firstIndex { $0.value == current } ?? 0
            popup.selectItem(at: idx)
        }
    }

    private func makePopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
        return popup
    }

    /// A single-line bezeled text field with the form's fixed width + height. `monospace`
    /// switches to the mono UI font for values where character alignment matters (paths /
    /// URLs); plain prose fields keep the proportional UI font.
    private func makeTextField(width: CGFloat, monospace: Bool = false) -> NSTextField {
        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        field.heightAnchor.constraint(equalToConstant: Self.controlHeight).isActive = true
        Self.styleTextField(field, monospace: monospace)
        return field
    }

    /// Shared bezel/font/cell styling so every text field in the form matches (one bezel
    /// style, single-line non-wrapping cell, no focus ring jitter).
    private static func styleTextField(_ field: NSTextField, monospace: Bool) {
        field.font = monospace ? Theme.uiFontMono : Theme.uiFont
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
    }

    /// The system's fixed-pitch font families, sorted — the menu source for Font family.
    private static func monospacedFontFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { NSFont(name: $0, size: 12)?.isFixedPitch ?? false }
            .sorted()
    }

    /// Render a float without a trailing ".0" so e.g. `12.0` shows as "12".
    private static func trimFloat(_ d: Double) -> String {
        if d == d.rounded() { return String(Int64(d)) }
        return String(d)
    }
}

// MARK: - Toolbar tabs

extension SettingsWindowController: NSToolbarDelegate {
    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.tabs.map(\.id)
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.tabs.map(\.id)
    }

    public func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.tabs.map(\.id)
    }

    public func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let tab = Self.tabs.first(where: { $0.id == itemIdentifier }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(toolbarItemSelected(_:))
        return item
    }
}

// MARK: - Adapters

/// Closure-backed target so each control carries its own action without per-control
/// selectors. Retained by the controller (controls hold an unowned target).
private final class ControlAction: NSObject {
    private let handler: (NSControl) -> Void
    init(_ handler: @escaping (NSControl) -> Void) { self.handler = handler }
    @objc func fire(_ sender: NSControl) { handler(sender) }
}

/// Commits a text field's value on end-editing (Enter / Tab / blur) — the debounce
/// point for text/number settings (we never write on every keystroke).
private final class TextCommitObserver: NSObject, NSTextFieldDelegate {
    private let handler: (NSTextField) -> Void
    init(_ handler: @escaping (NSTextField) -> Void) { self.handler = handler }
    func controlTextDidEndEditing(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        handler(field)
    }
}

/// Top-down coordinate container so the settings stack lays out from the top of the
/// scroll view's document area (NSScrollView is bottom-left by default).
private final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}
