// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — the per-workspace task list pane (`meta.view == "tasks"`).
//
//   • Scope toggle: This Workspace ↔ All Workspaces (persisted in block meta
//     `tasks:scope`; global rows carry a workspace badge).
//   • Quick-add row: wrapping text that grows with its content; Enter commits,
//     Shift+Enter inserts a line break. Typing `@` opens an autocomplete
//     of the workspace's tabs and panes; a picked mention becomes an `@Label`
//     token in the field and a `WaveTaskLink` on the created task. In All
//     Workspaces mode the autocomplete is two-stage: pick a workspace first
//     (`@Ws/`), then that workspace's tab/pane — and the task is created in the
//     mentioned workspace. Without a mention the task stays UNASSIGNED (empty
//     workspaceid, dimmed "no workspace" badge) instead of silently landing in
//     the current workspace.
//   • Edit: right-click → "Edit Task" (or double-click the text) loads a task
//     back into the field as `text @token…`; Enter saves via `taskupdate`
//     (replacing text AND links), Esc cancels. Mentions while editing stay
//     scoped to the task's own workspace; editing an unassigned task uses the
//     two-stage picker and the first mention assigns the workspace. Right-click
//     → "Move to Workspace" reassigns (or unassigns) a task directly.
//   • Rows render mentions as pills that navigate on click (cross-workspace via
//     `env.onNavigate`); pills whose target was deleted render dimmed/inert with
//     the label stored at mention time.
//   • Rows are single-line (truncated with …); a single click marks the task and
//     slides a detail panel in from the right: the full text (editable in
//     place — Enter saves, Esc reverts — and selectable for copying), pills,
//     and a workspace pill that pops a reassignment menu (works while the
//     task is being edited too).
//   • Checked tasks collapse into a "Done" history section with timestamps.
//
// Data flows over the task RPCs (`tasklist`/`taskcreate`/`taskupdate`/`taskdelete`)
// and stays live via the `task:update` WPS event (scoped to the workspace, or
// allscopes in global mode) — every mutation refetches the small list.

import AppKit
import WaveCore

private let taskUpdateEvent = "task:update"
private let tasksScopeMetaKey = "tasks:scope"
private let DetailPanelWidth: CGFloat = 280

final class TasksPaneView: NSView, NSTextFieldDelegate {
    static let viewType = "tasks"

    private let transport: WaveTransport
    private let store: ObjectStoreProtocol
    private let service: ServiceClient
    private let blockRef: ORef
    private let workspaceId: String
    private let onNavigate: (@Sendable (String, String, String?) -> Void)?

    private var globalMode = false
    private var doneCollapsed = true
    private var tasks: [WaveTask] = []
    private var selectedTaskId: String?

    private var eventToken: SubscriptionToken?
    /// Store subscriptions for every oref a visible pill references, so a tab/pane
    /// rename re-renders the pill labels live (no refetch needed).
    private var linkTokens: [SubscriptionToken] = []
    private var refreshScheduled = false

    private let scopeControl = NSSegmentedControl(
        labels: ["This Workspace", "All Workspaces"], trackingMode: .selectOne, target: nil, action: nil)
    private let inputBox = NSView()
    private let inputField = GrowingTaskField()
    private let scroll = NSScrollView()
    private let listStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No tasks yet — add one above.")

    // MARK: @-mention entry state

    /// label → link for every mention picked during the current quick-add entry.
    /// At commit, tokens still present in the text become the task's links.
    private var pendingMentions: [String: WaveTaskLink] = [:]

    /// Pasted deep-link URLs whose resolve is in flight (guards double-conversion).
    private var resolvingLinkURLs: Set<String> = []
    /// label → owning workspace for picked mentions; in global mode the first
    /// surviving mention decides which workspace the task is created in.
    private var pendingMentionWorkspaces: [String: String] = [:]
    /// Global mode: every workspace id, fetched lazily when the dropdown opens.
    private var allWorkspaceIds: [String] = []
    /// Set while the quick-add field is editing an existing task (menu "Edit
    /// Task" / double-click); commit then updates instead of creating.
    private var editingTaskId: String?
    private var editingTaskWorkspaceId: String?
    private let dropdown = TaskMentionDropdown()
    private let detailPanel = TaskDetailPanel()
    private var detailTrailing: NSLayoutConstraint!

    init(env: BlockEnv) {
        self.transport = env.transport
        self.store = env.store
        self.service = ServiceClient(transport: env.transport, store: env.store)
        self.blockRef = env.blockRef
        self.workspaceId = env.workspaceId
        self.onNavigate = env.onNavigate
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.blockBg.cgColor
        // The detail panel slides in from beyond the right edge — clip it.
        layer?.masksToBounds = true
        globalMode = env.store.get(env.blockRef)?.asBlock?.meta[tasksScopeMetaKey]?.stringValue == "global"
        setupViews()
        resubscribe()
        Task { await refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        eventToken?.cancel()
        linkTokens.forEach { $0.cancel() }
    }

    // MARK: - Setup

    private func setupViews() {
        scopeControl.selectedSegment = globalMode ? 1 : 0
        scopeControl.segmentStyle = .capsule
        scopeControl.font = Theme.tabLabelFont
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged)
        scopeControl.translatesAutoresizingMaskIntoConstraints = false

        inputBox.wantsLayer = true
        inputBox.layer?.backgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.06).cgColor
        inputBox.layer?.cornerRadius = Theme.radiusSmall
        inputBox.translatesAutoresizingMaskIntoConstraints = false

        updatePlaceholder()
        inputField.font = Theme.uiFont
        inputField.textColor = Theme.textPrimary
        inputField.drawsBackground = false
        inputField.isBordered = false
        inputField.focusRingType = .none
        inputField.delegate = self
        inputField.lineBreakMode = .byWordWrapping
        inputField.maximumNumberOfLines = 0
        inputField.cell?.wraps = true
        inputField.cell?.isScrollable = false
        inputField.translatesAutoresizingMaskIntoConstraints = false

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 2
        listStack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let docView = FlippedDocView()
        docView.translatesAutoresizingMaskIntoConstraints = false
        docView.addSubview(listStack)
        scroll.documentView = docView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = Theme.uiFont
        emptyLabel.textColor = Theme.textGrey
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        dropdown.translatesAutoresizingMaskIntoConstraints = false
        dropdown.isHidden = true
        dropdown.onPick = { [weak self] candidate in self?.applyMention(candidate) }

        detailPanel.translatesAutoresizingMaskIntoConstraints = false
        detailPanel.onClose = { [weak self] in self?.closeDetail() }
        detailPanel.onAssignWorkspace = { [weak self] taskId, wsId in
            self?.assignWorkspace(taskId: taskId, wsId: wsId)
        }
        detailPanel.onEditText = { [weak self] taskId, text in
            guard let self else { return }
            Task { [service = self.service] in
                try? await service.updateTask(taskId: taskId, text: text)
                await self.refresh()
            }
        }

        inputBox.addSubview(inputField)
        addSubview(scopeControl)
        addSubview(inputBox)
        addSubview(scroll)
        addSubview(emptyLabel)
        addSubview(detailPanel)
        addSubview(dropdown)

        NSLayoutConstraint.activate([
            scopeControl.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            scopeControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            inputBox.topAnchor.constraint(equalTo: scopeControl.bottomAnchor, constant: 10),
            inputBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            inputBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            inputField.topAnchor.constraint(equalTo: inputBox.topAnchor, constant: 5),
            inputField.leadingAnchor.constraint(equalTo: inputBox.leadingAnchor, constant: 8),
            inputField.trailingAnchor.constraint(equalTo: inputBox.trailingAnchor, constant: -8),
            inputField.bottomAnchor.constraint(equalTo: inputBox.bottomAnchor, constant: -5),

            scroll.topAnchor.constraint(equalTo: inputBox.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            emptyLabel.topAnchor.constraint(equalTo: inputBox.bottomAnchor, constant: 16),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),

            dropdown.topAnchor.constraint(equalTo: inputBox.bottomAnchor, constant: 2),
            dropdown.leadingAnchor.constraint(equalTo: inputBox.leadingAnchor),
            dropdown.trailingAnchor.constraint(equalTo: inputBox.trailingAnchor),
        ])

        detailTrailing = detailPanel.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: DetailPanelWidth + 16)
        let detailWidth = detailPanel.widthAnchor.constraint(equalToConstant: DetailPanelWidth)
        detailWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            detailPanel.topAnchor.constraint(equalTo: inputBox.bottomAnchor, constant: 8),
            detailPanel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            detailWidth,
            detailPanel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
            detailTrailing,
        ])

        if let docView = scroll.documentView {
            NSLayoutConstraint.activate([
                listStack.topAnchor.constraint(equalTo: docView.topAnchor),
                listStack.leadingAnchor.constraint(equalTo: docView.leadingAnchor),
                listStack.trailingAnchor.constraint(equalTo: docView.trailingAnchor),
                listStack.bottomAnchor.constraint(equalTo: docView.bottomAnchor),
                docView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            ])
        }
    }

    /// The quick-add field wraps, so its intrinsic height depends on its width —
    /// feed the resolved width back in before AutoLayout sizes it.
    override func layout() {
        let width = bounds.width - 2 * 12 - 2 * 8
        if width > 0, inputField.preferredMaxLayoutWidth != width {
            inputField.preferredMaxLayoutWidth = width
            inputField.invalidateIntrinsicContentSize()
        }
        super.layout()
    }

    private func updatePlaceholder() {
        inputField.placeholderString = globalMode
            ? "Add a task…  (@ mentions a workspace, then its tab or pane)"
            : "Add a task…  (@ mentions a tab or pane)"
    }

    // MARK: - Scope + subscription

    @objc private func scopeChanged() {
        globalMode = scopeControl.selectedSegment == 1
        if editingTaskId != nil {
            cancelEdit()
        }
        closeDetail()
        updatePlaceholder()
        allWorkspaceIds = []
        let scope = globalMode ? "global" : "workspace"
        Task { [service, blockRef] in
            try? await service.setMeta(oref: blockRef, meta: [tasksScopeMetaKey: .string(scope)])
        }
        resubscribe()
        Task { await refresh() }
    }

    private func resubscribe() {
        eventToken?.cancel()
        let request = globalMode
            ? SubscriptionRequest(event: taskUpdateEvent, allscopes: true)
            : SubscriptionRequest(event: taskUpdateEvent, scopes: [ORef.workspace(workspaceId).string])
        eventToken = transport.subscribe(request) { [weak self] _ in
            DispatchQueue.main.async { self?.scheduleRefresh() }
        }
    }

    /// Coalesce bursts of task events into one refetch per runloop turn.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            Task { await self.refresh() }
        }
    }

    // MARK: - Data

    private func refresh() async {
        ensureWorkspacesLoaded()
        let wsId: String? = globalMode ? nil : workspaceId
        guard let fetched = try? await service.listTasks(workspaceId: wsId) else { return }
        tasks = fetched
        await ensureReferencedObjectsLoaded(fetched)
        rebuildRows()
        syncDetailPanel()
    }

    /// Keep the slide-over in step with a refetch: re-render the selected task's
    /// content, or close the panel when the task left this scope (moved/deleted).
    private func syncDetailPanel() {
        guard let selected = selectedTaskId else { return }
        guard let task = tasks.first(where: { $0.oid == selected }) else {
            closeDetail()
            return
        }
        detailPanel.configure(task: task, pills: makePillsRow(task), workspaces: workspaceChoices())
    }

    /// Load every workspace/tab/block a visible task references but the store has
    /// not cached (global rows + mentions of other tabs). Targets that no longer
    /// exist simply stay unresolved and render as dimmed pills.
    private func ensureReferencedObjectsLoaded(_ tasks: [WaveTask]) async {
        var need: [ORef] = []
        var seen = Set<String>()
        func want(_ oref: ORef) {
            guard store.get(oref) == nil, seen.insert(oref.string).inserted else { return }
            need.append(oref)
        }
        for task in tasks {
            if globalMode, !task.workspaceid.isEmpty { want(.workspace(task.workspaceid)) }
            for link in task.links ?? [] {
                if let t = link.tabid, !t.isEmpty { want(.tab(t)) }
                if let b = link.blockid, !b.isEmpty { want(.block(b)) }
            }
        }
        guard !need.isEmpty else { return }
        _ = try? await store.loadMany(need)
    }

    // MARK: - Rows

    private func rebuildRows() {
        listStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        linkTokens.forEach { $0.cancel() }
        linkTokens = []

        let open = tasks.filter { !$0.isDone }
        let done = tasks.filter { $0.isDone }.sorted { ($0.donets ?? 0) > ($1.donets ?? 0) }

        emptyLabel.isHidden = !(open.isEmpty && done.isEmpty)
        for task in open {
            listStack.addArrangedSubview(makeTaskRow(task))
        }
        if !done.isEmpty {
            listStack.addArrangedSubview(makeDoneHeader(count: done.count))
            if !doneCollapsed {
                for task in done {
                    listStack.addArrangedSubview(makeTaskRow(task))
                }
            }
        }
        for view in listStack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
        subscribeLinkTargets()
    }

    /// Re-render pill labels when a referenced tab/pane changes (rename, deletion).
    private func subscribeLinkTargets() {
        var seen = Set<String>()
        let visible = doneCollapsed ? tasks.filter { !$0.isDone } : tasks
        for task in visible {
            for link in task.links ?? [] {
                for oref in [link.tabid.flatMap { $0.isEmpty ? nil : ORef.tab($0) },
                             link.blockid.flatMap { $0.isEmpty ? nil : ORef.block($0) }] {
                    guard let oref, seen.insert(oref.string).inserted else { continue }
                    linkTokens.append(store.subscribe(oref) { [weak self] _ in
                        DispatchQueue.main.async { self?.rebuildRows() }
                    })
                }
            }
        }
    }

    private func makeTaskRow(_ task: WaveTask) -> NSView {
        let row = TaskRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.cornerRadius = Theme.radiusSmall
        if task.oid == selectedTaskId {
            row.layer?.backgroundColor = Theme.hoverBackground.cgColor
        }

        let taskId = task.oid
        let checkbox = TaskCheckbox(checked: task.isDone)
        checkbox.onToggle = { [weak self] done in
            guard let self else { return }
            Task { [service = self.service] in
                try? await service.updateTask(taskId: taskId, done: done)
                await self.refresh()
            }
        }

        // Single-line label, NOT selectable: a selectable label re-renders in
        // the field editor's font on click, visibly changing the text's weight.
        let text = NSTextField(labelWithString: "")
        text.attributedStringValue = Self.taskAttributedText(task.text, done: task.isDone, singleLine: true)
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.cell?.truncatesLastVisibleLine = true
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.onClick = { [weak self] in self?.rowClicked(taskId) }
        row.onDoubleClick = { [weak self] in
            guard let self, let task = self.tasks.first(where: { $0.oid == taskId }) else { return }
            self.beginEditTask(task)
        }

        row.addSubview(checkbox)
        row.addSubview(text)
        var constraints = [
            checkbox.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 2),
            checkbox.topAnchor.constraint(equalTo: row.topAnchor, constant: 5),
            text.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 6),
            text.topAnchor.constraint(equalTo: row.topAnchor, constant: 5),
            text.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -4),
        ]

        let pills = makePillsRow(task)
        var bottomAnchor = text.bottomAnchor
        if let pills {
            row.addSubview(pills)
            constraints += [
                pills.leadingAnchor.constraint(equalTo: text.leadingAnchor),
                pills.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 4),
                pills.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -4),
            ]
            bottomAnchor = pills.bottomAnchor
        }
        constraints.append(row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 6))
        NSLayoutConstraint.activate(constraints)

        // Built lazily so the move submenu reflects the workspace list at
        // click time (the first async workspace fetch may land after rebuild).
        row.menuProvider = { [weak self] in self?.makeRowMenu(task) }
        return row
    }

    /// The pills under a task's text: workspace badge (global mode), completion
    /// timestamp (done rows), then one pill per mention.
    private func makePillsRow(_ task: WaveTask) -> NSView? {
        var views: [NSView] = []
        if globalMode, let badge = makeWorkspaceBadge(task) {
            views.append(badge)
        }
        if task.isDone, let ts = task.donets, ts > 0 {
            let when = NSTextField(labelWithString: Self.relativeTime(ms: ts))
            when.font = Theme.tabLabelFont
            when.textColor = Theme.textGrey
            views.append(when)
        }
        for link in task.links ?? [] {
            views.append(makeLinkPill(task: task, link: link))
        }
        guard !views.isEmpty else { return nil }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// A workspace's display name from the store ("workspace" fallback).
    private func resolvedWorkspaceName(_ wsId: String) -> String {
        let ws = store.get(.workspace(wsId))?.asWorkspace
        return ws?.name?.isEmpty == false ? ws!.name! : "workspace"
    }

    /// Workspace ids in EXACTLY the workspace switcher's order (same comparator),
    /// so every workspace list in this pane matches the standard list.
    private func sortedWorkspaceIds() -> [String] {
        return allWorkspaceIds.sorted {
            WorkspaceMenuItem.nameOrder(resolvedWorkspaceName($0), resolvedWorkspaceName($1))
        }
    }

    /// (id, name) pairs for the detail panel's workspace picker, sorted like
    /// the switcher; duplicate names get numeric suffixes.
    private func workspaceChoices() -> [(id: String, name: String)] {
        let uniqued = Self.makeUniquer()
        return sortedWorkspaceIds().map { ($0, uniqued(resolvedWorkspaceName($0))) }
    }

    private func makeWorkspaceBadge(_ task: WaveTask) -> NSView? {
        if task.workspaceid.isEmpty {
            return TaskPillButton(
                title: "no workspace", symbol: "square.grid.2x2", tint: Theme.textGrey, dimmed: true)
        }
        let ws = store.get(.workspace(task.workspaceid))?.asWorkspace
        let name = resolvedWorkspaceName(task.workspaceid)
        let tint = ws?.color.flatMap(WorkspaceSwitcherView.color(from:)) ?? Theme.textSecondary
        let pill = TaskPillButton(title: name, symbol: "square.grid.2x2", tint: tint, dimmed: false)
        let activeTab = ws?.activetabid ?? ""
        if !activeTab.isEmpty {
            let wsId = task.workspaceid
            pill.onTap = { [weak self] in self?.onNavigate?(wsId, activeTab, nil) }
        }
        return pill
    }

    private func makeLinkPill(task: WaveTask, link: WaveTaskLink) -> NSView {
        let display = linkDisplay(link)
        let symbol = (link.blockid?.isEmpty == false) ? "rectangle.split.2x1" : "rectangle.on.rectangle"
        let pill = TaskPillButton(
            title: display.title, symbol: symbol,
            tint: display.alive ? Theme.accent : Theme.textGrey, dimmed: !display.alive)
        if display.alive, let tabId = link.tabid, !tabId.isEmpty {
            let wsId = task.workspaceid
            let blockId = (link.blockid?.isEmpty == false) ? link.blockid : nil
            pill.onTap = { [weak self] in self?.onNavigate?(wsId, tabId, blockId) }
        }
        pill.toolTip = display.alive ? "Go to \(display.title)" : "\(display.title) (deleted)"
        return pill
    }

    /// Resolve a link's CURRENT label from the store (renames show live); fall back
    /// to the label recorded at mention time once the target is gone.
    private func linkDisplay(_ link: WaveTaskLink) -> (title: String, alive: Bool) {
        if let blockId = link.blockid, !blockId.isEmpty {
            guard let block = store.get(.block(blockId))?.asBlock else {
                return (link.label ?? "deleted pane", false)
            }
            let tabName = link.tabid.flatMap { store.get(.tab($0))?.asTab?.name }
            return (Self.paneLabel(block: block, tabName: tabName), true)
        }
        if let tabId = link.tabid, !tabId.isEmpty {
            guard let tab = store.get(.tab(tabId))?.asTab else {
                return (link.label ?? "deleted tab", false)
            }
            return (tab.name, true)
        }
        return (link.label ?? "?", false)
    }

    /// A pane's mention label: its display name when set, else `view · tab`.
    static func paneLabel(block: Block, tabName: String?) -> String {
        if let name = block.meta["display:name"]?.stringValue, !name.isEmpty { return name }
        if let title = block.meta["frame:title"]?.stringValue, !title.isEmpty { return title }
        let view = block.view ?? "pane"
        if let tabName, !tabName.isEmpty { return "\(view) · \(tabName)" }
        return view
    }

    static func taskAttributedText(_ text: String, done: Bool, singleLine: Bool = false) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: Theme.uiFont,
            .foregroundColor: done ? Theme.textGrey : Theme.textPrimary,
        ]
        if done {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.strikethroughColor] = Theme.textGrey
        }
        var rendered = text
        if singleLine {
            // The attributed paragraph style overrides the field's lineBreakMode,
            // so truncation must be baked in here; embedded newlines still force
            // extra lines, so collapse them too.
            rendered = text.replacingOccurrences(of: "\n", with: " ")
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            attrs[.paragraphStyle] = para
        }
        return NSAttributedString(string: rendered, attributes: attrs)
    }

    static func relativeTime(ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func makeDoneHeader(count: Int) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let chevron = doneCollapsed ? "chevron.right" : "chevron.down"
        let toggle = NSButton(title: " Done (\(count))", target: self, action: #selector(toggleDoneSection))
        toggle.image = NSImage(systemSymbolName: chevron, accessibilityDescription: nil)
        toggle.imagePosition = .imageLeading
        toggle.isBordered = false
        toggle.font = Theme.headerFont
        toggle.contentTintColor = Theme.textSecondary
        toggle.translatesAutoresizingMaskIntoConstraints = false

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearDone))
        clear.isBordered = false
        clear.font = Theme.tabLabelFont
        clear.contentTintColor = Theme.textGrey
        clear.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(toggle)
        container.addSubview(clear)
        NSLayoutConstraint.activate([
            toggle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toggle.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            toggle.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            clear.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            clear.centerYAnchor.constraint(equalTo: toggle.centerYAnchor),
        ])
        return container
    }

    private func makeRowMenu(_ task: WaveTask) -> NSMenu {
        let menu = NSMenu()
        let edit = NSMenuItem(title: "Edit Task", action: #selector(editTask(_:)), keyEquivalent: "")
        edit.target = self
        edit.representedObject = task.oid
        menu.addItem(edit)
        let delete = NSMenuItem(title: "Delete Task", action: #selector(deleteTask(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = task.oid
        menu.addItem(delete)
        menu.addItem(.separator())
        let move = NSMenuItem(title: "Move to Workspace", action: nil, keyEquivalent: "")
        move.submenu = makeMoveMenu(task)
        menu.addItem(move)
        return menu
    }

    /// "Move to Workspace" submenu: one item per workspace (checkmark on the
    /// task's current one) plus "No Workspace" to unassign it.
    private func makeMoveMenu(_ task: WaveTask) -> NSMenu {
        ensureWorkspacesLoaded()
        let sub = NSMenu()
        for choice in workspaceChoices() {
            let (wsId, name) = choice
            let item = NSMenuItem(title: name, action: #selector(moveTask(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [task.oid, wsId]
            item.state = task.workspaceid == wsId ? .on : .off
            sub.addItem(item)
        }
        if !sub.items.isEmpty {
            sub.addItem(.separator())
        }
        let none = NSMenuItem(title: "No Workspace", action: #selector(moveTask(_:)), keyEquivalent: "")
        none.target = self
        none.representedObject = [task.oid, ""]
        none.state = task.workspaceid.isEmpty ? .on : .off
        sub.addItem(none)
        return sub
    }

    @objc private func moveTask(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        let (taskId, wsId) = (pair[0], pair[1])
        guard tasks.first(where: { $0.oid == taskId })?.workspaceid != wsId else { return }
        assignWorkspace(taskId: taskId, wsId: wsId)
    }

    // MARK: - Actions

    /// Single click: mark + focus the task and slide the detail panel in;
    /// clicking the selected task again slides it back out.
    private func rowClicked(_ taskId: String) {
        if selectedTaskId == taskId {
            closeDetail()
            return
        }
        guard let task = tasks.first(where: { $0.oid == taskId }) else { return }
        selectedTaskId = taskId
        rebuildRows()
        detailPanel.configure(task: task, pills: makePillsRow(task), workspaces: workspaceChoices())
        setDetailVisible(true)
    }

    private func closeDetail() {
        guard selectedTaskId != nil else { return }
        detailPanel.endTextEditing()
        selectedTaskId = nil
        rebuildRows()
        setDetailVisible(false)
    }

    private func setDetailVisible(_ visible: Bool) {
        // Callers rebuild the rows right before this; settle them at their real
        // frames first, otherwise the animated pass below animates every new row
        // from its initial zero frame (grow-from-bottom-left artifact).
        layoutSubtreeIfNeeded()
        detailTrailing.constant = visible ? -8 : DetailPanelWidth + 16
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
        }
    }

    /// Reassign a task's workspace ("" unassigns). Works mid-edit: the edit
    /// field keeps its content and its mention scoping follows the task.
    private func assignWorkspace(taskId: String, wsId: String) {
        if taskId == editingTaskId {
            editingTaskWorkspaceId = wsId
        }
        Task { [service] in
            try? await service.updateTask(taskId: taskId, workspaceId: wsId)
            await self.refresh()
        }
    }

    @objc private func toggleDoneSection() {
        doneCollapsed.toggle()
        rebuildRows()
    }

    @objc private func clearDone() {
        let doneIds = tasks.filter { $0.isDone }.map { $0.oid }
        guard !doneIds.isEmpty else { return }
        Task { [service] in
            for id in doneIds {
                try? await service.deleteTask(taskId: id)
            }
            await self.refresh()
        }
    }

    @objc private func deleteTask(_ sender: NSMenuItem) {
        guard let taskId = sender.representedObject as? String else { return }
        if taskId == editingTaskId {
            cancelEdit()
        }
        if taskId == selectedTaskId {
            closeDetail()
        }
        Task { [service] in
            try? await service.deleteTask(taskId: taskId)
            await self.refresh()
        }
    }

    // MARK: - Edit existing task

    @objc private func editTask(_ sender: NSMenuItem) {
        guard let taskId = sender.representedObject as? String,
              let task = tasks.first(where: { $0.oid == taskId }) else { return }
        beginEditTask(task)
    }

    /// Load a task into the quick-add field: its text plus one `@label` token per
    /// link, so the normal mention machinery edits/removes/adds links.
    private func beginEditTask(_ task: WaveTask) {
        editingTaskId = task.oid
        editingTaskWorkspaceId = task.workspaceid
        pendingMentionWorkspaces.removeAll()
        let entry = Self.editEntry(text: task.text, links: task.links ?? []) { self.linkDisplay($0).title }
        pendingMentions = entry.pending
        inputField.stringValue = entry.entry
        dropdown.isHidden = true
        updateEditingChrome()
        window?.makeFirstResponder(inputField)
        moveEntryCursorToEnd()
    }

    /// The field content for editing `text` with `links`: `text @label @label…`.
    /// Labels are the links' CURRENT display titles (uniqued), and the returned
    /// pending map is keyed to match, so splitMentions round-trips the links.
    static func editEntry(
        text: String, links: [WaveTaskLink], displayTitle: (WaveTaskLink) -> String
    ) -> (entry: String, pending: [String: WaveTaskLink]) {
        var entry = text
        var pending: [String: WaveTaskLink] = [:]
        let uniqued = makeUniquer()
        for link in links {
            let label = uniqued(displayTitle(link))
            pending[label] = WaveTaskLink(tabid: link.tabid, blockid: link.blockid, label: label)
            entry += " @" + label
        }
        return (entry, pending)
    }

    private func cancelEdit() {
        editingTaskId = nil
        editingTaskWorkspaceId = nil
        clearEntry()
        updateEditingChrome()
    }

    private func updateEditingChrome() {
        if editingTaskId != nil {
            inputBox.layer?.borderWidth = 1
            inputBox.layer?.borderColor = Theme.accent.cgColor
            inputField.placeholderString = "Edit task…  (Enter saves, Esc cancels)"
        } else {
            inputBox.layer?.borderWidth = 0
            updatePlaceholder()
        }
    }

    // MARK: - Quick add + mentions

    func controlTextDidChange(_ obj: Notification) {
        convertDeepLinksInInput()
        updateDropdown()
    }

    /// A pasted deep link (`wave-native://block|tab/<id>`, e.g. from a pane's
    /// "Copy Link") morphs into a regular @mention: resolve its target, register
    /// the pending mention (+ its workspace, so an unassigned/global task lands
    /// where the pane lives), and replace the URL text with the `@Label` token.
    /// Workspace links stay plain text — a task link targets a tab/pane. URLs
    /// being resolved are tracked so keystrokes during the async resolve don't
    /// double-convert.
    private func convertDeepLinksInInput() {
        guard let (range, link) = Self.firstDeepLink(in: inputField.stringValue) else { return }
        if case .workspace = link { return }
        let urlText = String(inputField.stringValue[range])
        guard resolvingLinkURLs.insert(urlText).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.resolvingLinkURLs.remove(urlText) }
            guard let candidate = await self.mentionForDeepLink(link) else { return }
            let text = self.inputField.stringValue
            guard let r = text.range(of: urlText) else { return }
            let label = self.uniqueMentionLabel(candidate.label)
            var mention = candidate.link
            mention.label = label
            self.pendingMentions[label] = mention
            if let ws = candidate.workspaceId {
                self.pendingMentionWorkspaces[label] = ws
            }
            self.inputField.stringValue = text.replacingCharacters(in: r, with: "@" + label + " ")
            self.inputField.invalidateIntrinsicContentSize()
            self.dropdown.isHidden = true
            self.moveEntryCursorToEnd()
            self.convertDeepLinksInInput()
        }
    }

    /// First `wave-native://…` URL in `text` (token runs to whitespace) that
    /// parses as a deep link, with its range. Pure.
    static func firstDeepLink(in text: String) -> (range: Range<String.Index>, link: DeepLink)? {
        var search = text.startIndex..<text.endIndex
        while let hit = text.range(of: DeepLink.scheme + "://", options: [.caseInsensitive], range: search) {
            let end = text[hit.lowerBound...].firstIndex(where: { $0.isWhitespace }) ?? text.endIndex
            let urlText = String(text[hit.lowerBound..<end])
            if let url = URL(string: urlText), let link = DeepLink.parse(url) {
                return (hit.lowerBound..<end, link)
            }
            search = end..<text.endIndex
        }
        return nil
    }

    /// Resolve a block/tab deep link to a mention candidate: the target's CURRENT
    /// display label, a tabid-carrying link (pills need the tab to navigate), and
    /// the owning workspace. Nil once the target no longer exists.
    private func mentionForDeepLink(_ link: DeepLink) async -> TaskMentionCandidate? {
        let resolver = DeepLinkResolver(store: store, service: service)
        guard let loc = await resolver.resolve(link), let tabId = loc.tabId else { return nil }
        let need = [ORef.tab(tabId), loc.blockId.map { ORef.block($0) }].compactMap { $0 }
            .filter { store.get($0) == nil }
        if !need.isEmpty { _ = try? await store.loadMany(need) }
        guard let tab = store.get(.tab(tabId))?.asTab else { return nil }
        guard let blockId = loc.blockId else {
            return TaskMentionCandidate(
                label: tab.name, isTab: true,
                link: WaveTaskLink(tabid: tabId, blockid: nil, label: tab.name),
                workspaceId: loc.workspaceId)
        }
        guard let block = store.get(.block(blockId))?.asBlock else { return nil }
        let label = Self.paneLabel(block: block, tabName: tab.name)
        return TaskMentionCandidate(
            label: label, isTab: false,
            link: WaveTaskLink(tabid: tabId, blockid: blockId, label: label),
            workspaceId: loc.workspaceId)
    }

    /// Suffix a pasted link's label until it doesn't collide with a pending
    /// mention (mirrors `makeUniquer`, but against the live pending map).
    private func uniqueMentionLabel(_ base: String) -> String {
        var label = base
        var n = 1
        while pendingMentions[label] != nil {
            n += 1
            label = "\(base) (\(n))"
        }
        return label
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)),
           NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        if !dropdown.isHidden {
            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)):
                dropdown.moveSelection(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                dropdown.moveSelection(-1)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                dropdown.pickSelected()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                dropdown.isHidden = true
                return true
            default:
                break
            }
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitQuickAdd()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)), editingTaskId != nil {
            cancelEdit()
            return true
        }
        // Cmd+Delete: wipe the whole entry (field editors map it to
        // deleteToBeginningOfLine:, which would only clear the current line).
        if commandSelector == #selector(NSResponder.deleteToBeginningOfLine(_:)) {
            clearEntry()
            return true
        }
        return false
    }

    private func clearEntry() {
        inputField.stringValue = ""
        inputField.invalidateIntrinsicContentSize()
        pendingMentions.removeAll()
        pendingMentionWorkspaces.removeAll()
        dropdown.isHidden = true
    }

    /// The `@fragment` being typed (text after the LAST `@`), or nil when the field
    /// has no open mention. Labels may contain spaces, so everything after the `@`
    /// counts as the fragment.
    static func mentionFragment(_ text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        return String(text[text.index(after: at)...])
    }

    private func updateDropdown() {
        guard let fragment = Self.mentionFragment(inputField.stringValue) else {
            dropdown.isHidden = true
            return
        }
        // Editing a task that HAS a workspace keeps mentions scoped to it (no
        // stage-1 workspace pick): links carry no workspace, so their pills must
        // stay in the task's workspace. Creating — or editing an UNASSIGNED
        // task — in global mode uses the two-stage picker, and the first mention
        // decides (or assigns) the workspace.
        if globalMode, (editingTaskWorkspaceId ?? "").isEmpty {
            ensureWorkspacesLoaded()
            if let (ws, rest) = workspaceStage(fragment), let wsId = ws.workspaceId {
                ensureCandidateObjectsLoaded(in: wsId)
                let prefix = ws.label + "/"
                presentDropdown(
                    mentionCandidates(in: wsId, labelPrefix: prefix),
                    query: rest, matchOffset: prefix.count)
            } else {
                presentDropdown(workspaceCandidates(), query: fragment, matchOffset: 0)
            }
            return
        }
        let scopeWs = editingTaskWorkspaceId ?? workspaceId
        ensureCandidateObjectsLoaded(in: scopeWs)
        presentDropdown(mentionCandidates(in: scopeWs, labelPrefix: ""), query: fragment, matchOffset: 0)
    }

    /// Filter on the label part past `matchOffset` (the `Ws/` prefix in stage 2 of
    /// a global-mode mention, so the workspace name doesn't match everything).
    private func presentDropdown(_ all: [TaskMentionCandidate], query: String, matchOffset: Int) {
        let q = query.lowercased()
        let filtered = q.isEmpty ? all : all.filter { $0.label.dropFirst(matchOffset).lowercased().contains(q) }
        guard !filtered.isEmpty else {
            dropdown.isHidden = true
            return
        }
        dropdown.setCandidates(filtered)
        dropdown.isHidden = false
    }

    /// Stage 2 of a global-mode mention: the fragment is `WsLabel/rest` once a
    /// workspace was picked. Greedy label-prefix match (not a split at the first
    /// `/`) so workspace names containing `/` still resolve.
    private func workspaceStage(_ fragment: String) -> (ws: TaskMentionCandidate, rest: String)? {
        guard let match = Self.splitWorkspacePrefix(
            fragment: fragment, workspaceLabels: workspaceCandidates().map { $0.label }) else { return nil }
        guard let ws = workspaceCandidates().first(where: { $0.label == match.label }) else { return nil }
        return (ws, match.rest)
    }

    static func splitWorkspacePrefix(
        fragment: String, workspaceLabels: [String]
    ) -> (label: String, rest: String)? {
        for label in workspaceLabels where fragment.hasPrefix(label + "/") {
            return (label, String(fragment.dropFirst(label.count + 1)))
        }
        return nil
    }

    /// Stage-1 candidates in global mode: one row per workspace. Picking one does
    /// not create a mention yet — it narrows the dropdown to that workspace.
    func workspaceCandidates() -> [TaskMentionCandidate] {
        var out: [TaskMentionCandidate] = []
        let uniqued = Self.makeUniquer()
        for wsId in sortedWorkspaceIds() {
            let label = uniqued(resolvedWorkspaceName(wsId))
            out.append(TaskMentionCandidate(
                label: label, isTab: false,
                link: WaveTaskLink(tabid: nil, blockid: nil, label: label),
                workspaceId: wsId, isWorkspace: true))
        }
        return out
    }

    /// Candidates: every tab of THIS workspace, then every pane of every tab.
    /// Duplicate labels get a numeric suffix so the pending-mention map (keyed by
    /// label) can't collapse two targets into one.
    func mentionCandidates() -> [TaskMentionCandidate] {
        mentionCandidates(in: workspaceId, labelPrefix: "")
    }

    func mentionCandidates(in wsId: String, labelPrefix: String) -> [TaskMentionCandidate] {
        guard let ws = store.get(.workspace(wsId))?.asWorkspace else { return [] }
        var out: [TaskMentionCandidate] = []
        let uniqued = Self.makeUniquer()
        for tabId in ws.tabids {
            guard let tab = store.get(.tab(tabId))?.asTab else { continue }
            let tabLabel = labelPrefix + uniqued(tab.name)
            out.append(TaskMentionCandidate(
                label: tabLabel, isTab: true,
                link: WaveTaskLink(tabid: tabId, blockid: nil, label: tabLabel),
                workspaceId: wsId))
            for blockId in tab.blockids {
                guard let block = store.get(.block(blockId))?.asBlock else { continue }
                if block.view == Self.viewType { continue }
                let label = labelPrefix + uniqued(Self.paneLabel(block: block, tabName: tab.name))
                out.append(TaskMentionCandidate(
                    label: label, isTab: false,
                    link: WaveTaskLink(tabid: tabId, blockid: blockId, label: label),
                    workspaceId: wsId))
            }
        }
        return out
    }

    private static func makeUniquer() -> (String) -> String {
        var used: [String: Int] = [:]
        return { label in
            let n = (used[label] ?? 0) + 1
            used[label] = n
            return n == 1 ? label : "\(label) (\(n))"
        }
    }

    /// Blocks of inactive tabs are usually not cached; load them so the
    /// autocomplete can offer every pane. Fire-and-forget: the dropdown refreshes
    /// on the next keystroke.
    private func ensureCandidateObjectsLoaded(in wsId: String) {
        guard let ws = store.get(.workspace(wsId))?.asWorkspace else {
            Task { [store] in _ = try? await store.loadMany([.workspace(wsId)]) }
            return
        }
        var need: [ORef] = []
        for tabId in ws.tabids {
            guard let tab = store.get(.tab(tabId))?.asTab else {
                need.append(.tab(tabId))
                continue
            }
            for blockId in tab.blockids where store.get(.block(blockId)) == nil {
                need.append(.block(blockId))
            }
        }
        guard !need.isEmpty else { return }
        Task { [store] in _ = try? await store.loadMany(need) }
    }

    /// Global mode: fetch the id of every workspace (and load their objects) so
    /// the stage-1 dropdown has names. Fire-and-forget like the candidate loads.
    private func ensureWorkspacesLoaded() {
        guard allWorkspaceIds.isEmpty else { return }
        Task { [service, store] in
            guard let entries = try? await service.listWorkspaces() else { return }
            let ids = entries.map { $0.workspaceid }
            let need = ids.filter { store.get(.workspace($0)) == nil }.map { ORef.workspace($0) }
            if !need.isEmpty { _ = try? await store.loadMany(need) }
            self.allWorkspaceIds = ids
        }
    }

    private func applyMention(_ candidate: TaskMentionCandidate) {
        let text = inputField.stringValue
        guard let at = text.lastIndex(of: "@") else { return }
        if candidate.isWorkspace {
            inputField.stringValue = String(text[..<at]) + "@" + candidate.label + "/"
            moveEntryCursorToEnd()
            updateDropdown()
            return
        }
        pendingMentions[candidate.label] = candidate.link
        if let wsId = candidate.workspaceId {
            pendingMentionWorkspaces[candidate.label] = wsId
        }
        inputField.stringValue = String(text[..<at]) + "@" + candidate.label + " "
        dropdown.isHidden = true
        moveEntryCursorToEnd()
    }

    /// Keep typing where the insertion left off.
    private func moveEntryCursorToEnd() {
        inputField.invalidateIntrinsicContentSize()
        inputField.currentEditor()?.selectedRange = NSRange(
            location: (inputField.stringValue as NSString).length, length: 0)
    }

    /// Split the committed field text into (stored text, links): every pending
    /// mention whose `@Label` token is still present becomes a link and its token
    /// is stripped from the text. A text that was ONLY mentions keeps the raw
    /// entry so the task text never ends up empty.
    static func splitMentions(
        raw: String, pending: [String: WaveTaskLink]
    ) -> (text: String, links: [WaveTaskLink]) {
        var text = raw
        var links: [WaveTaskLink] = []
        // Longest label first, so "@build (2)" is not consumed by "@build".
        for (label, link) in pending.sorted(by: { $0.key.count > $1.key.count }) {
            let token = "@" + label
            guard text.contains(token) else { continue }
            links.append(WaveTaskLink(tabid: link.tabid, blockid: link.blockid, label: label))
            text = text.replacingOccurrences(of: token, with: "")
        }
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (text, links)
    }

    private func commitQuickAdd() {
        let raw = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let (text, links) = Self.splitMentions(raw: raw, pending: pendingMentions)
        // A mention decides which workspace owns the task; in global mode a
        // task without one stays UNASSIGNED (empty workspaceid) instead of
        // silently landing in the current workspace.
        let mentionWs = links.compactMap { pendingMentionWorkspaces[$0.label ?? ""] }.first
        let targetWs = mentionWs ?? (globalMode ? "" : workspaceId)
        let editing = editingTaskId
        let editingWs = editingTaskWorkspaceId
        editingTaskId = nil
        editingTaskWorkspaceId = nil
        inputField.stringValue = ""
        inputField.invalidateIntrinsicContentSize()
        pendingMentions.removeAll()
        pendingMentionWorkspaces.removeAll()
        dropdown.isHidden = true
        updateEditingChrome()
        Task { [service] in
            if let editing {
                // A mention picked while editing an unassigned task assigns
                // the task to that workspace; assigned tasks never move here.
                let moveWs = (editingWs?.isEmpty ?? true) ? mentionWs : nil
                try? await service.updateTask(taskId: editing, text: text, links: links, workspaceId: moveWs)
            } else {
                try? await service.createTask(workspaceId: targetWs, text: text, links: links)
            }
            await self.refresh()
        }
    }
}

/// A mention candidate offered by the `@` autocomplete. `isWorkspace` rows are
/// the stage-1 workspace picks of global mode (no link target yet).
struct TaskMentionCandidate {
    let label: String
    let isTab: Bool
    let link: WaveTaskLink
    var workspaceId: String? = nil
    var isWorkspace: Bool = false
}

/// Quick-add field that wraps and grows vertically with its content. The pane's
/// layout() feeds preferredMaxLayoutWidth; height is measured from the live
/// field-editor text so the box grows while typing, not only on commit.
final class GrowingTaskField: NSTextField {
    override var intrinsicContentSize: NSSize {
        let width = preferredMaxLayoutWidth > 0 ? preferredMaxLayoutWidth : bounds.width
        guard width > 0 else { return super.intrinsicContentSize }
        var text = currentEditor()?.string ?? stringValue
        if text.isEmpty { text = " " }
        // boundingRect drops a trailing empty line; pad it so Shift+Enter at the
        // end grows the field immediately.
        if text.hasSuffix("\n") { text += " " }
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(rect.height) + 2)
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        invalidateIntrinsicContentSize()
    }
}

/// Row container that shows its context menu on right-click anywhere in the row.
/// The menu comes from `menuProvider` so it is rebuilt fresh on every open.
/// Left clicks land here too (labels pass unhandled mouseDowns up the responder
/// chain; pills/checkbox handle their own): 1 click selects, 2 clicks edit.
private final class TaskRowView: NSView {
    var menuProvider: (() -> NSMenu?)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        return menuProvider?() ?? super.menu(for: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() ?? menu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            onClick?()
        }
    }
}

/// Custom checkbox: the system one is nearly invisible on the dark theme, so
/// this draws its own — accent-green border, accent fill + white check when on.
final class TaskCheckbox: NSView {
    var onToggle: ((Bool) -> Void)?
    private(set) var isChecked: Bool
    private let check = NSImageView()

    init(checked: Bool) {
        isChecked = checked
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.radiusSmall
        layer?.borderWidth = 1.5
        translatesAutoresizingMaskIntoConstraints = false
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "done")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .bold))
        check.contentTintColor = .white
        check.translatesAutoresizingMaskIntoConstraints = false
        addSubview(check)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 16),
            heightAnchor.constraint(equalToConstant: 16),
            check.centerXAnchor.constraint(equalTo: centerXAnchor),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func render() {
        layer?.borderColor = Theme.accent.cgColor
        layer?.backgroundColor = isChecked
            ? Theme.accent.cgColor
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08).cgColor
        check.isHidden = !isChecked
    }

    override func mouseDown(with event: NSEvent) {
        isChecked.toggle()
        render()
        onToggle?(isChecked)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// A rounded mention pill: tinted icon + label, hover highlight, optional click.
/// Dimmed (deleted target) pills render greyed and inert.
final class TaskPillButton: NSView {
    var onTap: (() -> Void)?
    private let dimmed: Bool
    private var trackingArea: NSTrackingArea?

    init(title: String, symbol: String, tint: NSColor, dimmed: Bool) {
        self.dimmed = dimmed
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: dimmed ? 0.05 : 0.10).cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        icon.contentTintColor = dimmed ? Theme.textGrey : tint
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = Theme.tabLabelFont
        label.textColor = dimmed ? Theme.textGrey : Theme.textSecondary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 18),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        guard onTap != nil else { return super.mouseDown(with: event) }
        onTap?()
    }

    override func resetCursorRects() {
        if onTap != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        guard !dimmed else { return }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard onTap != nil else { return }
        layer?.backgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.18).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: dimmed ? 0.05 : 0.10).cgColor
    }
}

/// The `@` autocomplete dropdown: a bordered panel of candidate rows under the
/// quick-add field. Keyboard driven by the field's delegate (arrows/Enter/Esc).
final class TaskMentionDropdown: NSView {
    var onPick: ((TaskMentionCandidate) -> Void)?
    private var candidates: [TaskMentionCandidate] = []
    private var selectedIndex = 0
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.modalBackground.cgColor
        layer?.cornerRadius = Theme.radiusMedium
        layer?.borderWidth = 1
        layer?.borderColor = Theme.border.cgColor
        stack.orientation = .vertical
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setCandidates(_ new: [TaskMentionCandidate]) {
        candidates = Array(new.prefix(8))
        selectedIndex = 0
        renderRows()
    }

    func moveSelection(_ delta: Int) {
        guard !candidates.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + candidates.count) % candidates.count
        renderRows()
    }

    func pickSelected() {
        guard candidates.indices.contains(selectedIndex) else { return }
        onPick?(candidates[selectedIndex])
    }

    private func renderRows() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (idx, candidate) in candidates.enumerated() {
            let row = makeRow(candidate, selected: idx == selectedIndex, index: idx)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
        }
    }

    private func makeRow(_ candidate: TaskMentionCandidate, selected: Bool, index: Int) -> NSView {
        let row = NSView()
        row.wantsLayer = true
        row.layer?.cornerRadius = Theme.radiusSmall
        if selected { row.layer?.backgroundColor = Theme.hoverBackground.cgColor }
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        let symbolName = candidate.isWorkspace ? "square.grid.2x2"
            : candidate.isTab ? "rectangle.on.rectangle" : "rectangle.split.2x1"
        icon.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .regular))
        icon.contentTintColor = Theme.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: candidate.label)
        label.font = Theme.uiFont
        label.textColor = Theme.textPrimary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(icon)
        row.addSubview(label)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 24),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
        row.addGestureRecognizer(click)
        row.identifier = NSUserInterfaceItemIdentifier("\(index)")
        return row
    }

    @objc private func rowClicked(_ sender: NSClickGestureRecognizer) {
        guard let idString = sender.view?.identifier?.rawValue, let idx = Int(idString),
              candidates.indices.contains(idx) else { return }
        onPick?(candidates[idx])
    }
}

/// Slide-over detail for the selected task: the full task text — editable in
/// place (Enter saves, Shift+Enter breaks the line, Esc reverts) and selectable
/// for copying — its pills, and a workspace pill that pops a reassignment menu
/// ("No Workspace" unassigns), matching the list rows' "Move to Workspace" menu.
final class TaskDetailPanel: NSView, NSTextFieldDelegate {
    var onClose: (() -> Void)?
    /// (taskId, workspaceId) — workspaceId "" unassigns.
    var onAssignWorkspace: ((String, String) -> Void)?
    /// (taskId, newText) — an inline text edit was committed (Enter / focus loss).
    var onEditText: ((String, String) -> Void)?

    private var taskId = ""
    private var currentWsId = ""
    private var taskDone = false
    private var originalText = ""
    private var workspaces: [(id: String, name: String)] = []

    // GrowingTaskField, not a wrapping label: an EDITABLE field's intrinsic
    // height is single-line under autolayout, which truncates the task text.
    private let textField = GrowingTaskField()
    private let pillsContainer = NSStackView()
    private let wsPickerContainer = NSStackView()

    private var isEditingText: Bool { textField.currentEditor() != nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.modalBackground.cgColor
        layer?.cornerRadius = Theme.radiusMedium
        layer?.borderWidth = 1
        layer?.borderColor = Theme.border.cgColor

        let title = NSTextField(labelWithString: "Task")
        title.font = Theme.headerFont
        title.textColor = Theme.textSecondary
        title.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "close")!,
            target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.contentTintColor = Theme.textSecondary
        close.translatesAutoresizingMaskIntoConstraints = false

        textField.isEditable = true
        textField.isSelectable = true
        textField.font = Theme.uiFont
        textField.drawsBackground = false
        textField.isBordered = false
        textField.focusRingType = .none
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 0
        textField.cell?.wraps = true
        textField.cell?.isScrollable = false
        textField.delegate = self
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pillsContainer.orientation = .vertical
        pillsContainer.alignment = .leading
        pillsContainer.spacing = 6
        pillsContainer.translatesAutoresizingMaskIntoConstraints = false

        let wsHeader = NSTextField(labelWithString: "Workspace")
        wsHeader.font = Theme.headerFont
        wsHeader.textColor = Theme.textSecondary
        wsHeader.translatesAutoresizingMaskIntoConstraints = false

        wsPickerContainer.orientation = .horizontal
        wsPickerContainer.alignment = .centerY
        wsPickerContainer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(title)
        addSubview(close)
        addSubview(textField)
        addSubview(pillsContainer)
        addSubview(wsHeader)
        addSubview(wsPickerContainer)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            textField.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            pillsContainer.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 8),
            pillsContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            pillsContainer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            wsHeader.topAnchor.constraint(equalTo: pillsContainer.bottomAnchor, constant: 14),
            wsHeader.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),

            wsPickerContainer.topAnchor.constraint(equalTo: wsHeader.bottomAnchor, constant: 6),
            wsPickerContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            wsPickerContainer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            wsPickerContainer.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(task: WaveTask, pills: NSView?, workspaces: [(id: String, name: String)]) {
        if isEditingText, task.oid != taskId {
            endTextEditing()
        }
        taskId = task.oid
        currentWsId = task.workspaceid
        taskDone = task.isDone
        self.workspaces = workspaces
        // A background refetch while the user is typing in the field must not
        // stomp their in-progress edit.
        if !isEditingText {
            originalText = task.text
            textField.attributedStringValue = TasksPaneView.taskAttributedText(task.text, done: task.isDone)
        }
        pillsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let pills {
            pillsContainer.addArrangedSubview(pills)
        }
        renderWorkspacePicker()
    }

    /// End (and thereby commit) an in-progress inline edit, e.g. before the
    /// panel slides out or switches to another task.
    func endTextEditing() {
        guard isEditingText else { return }
        window?.makeFirstResponder(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            textField.attributedStringValue = TasksPaneView.taskAttributedText(originalText, done: taskDone)
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextIfChanged()
    }

    private func commitTextIfChanged() {
        let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty text is rejected by the backend — treat it like Esc (revert).
        let changed = !text.isEmpty && text != originalText
        if changed { originalText = text }
        textField.attributedStringValue = TasksPaneView.taskAttributedText(originalText, done: taskDone)
        if changed { onEditText?(taskId, text) }
    }

    override func layout() {
        let width = bounds.width - 24
        if width > 0, textField.preferredMaxLayoutWidth != width {
            textField.preferredMaxLayoutWidth = width
            textField.invalidateIntrinsicContentSize()
        }
        super.layout()
    }

    // AppKit re-routes a mouseDown that bubbles up unhandled to the views
    // visually BEHIND this panel — a click on the flyout's background would
    // "select" the task row underneath it. Swallow the whole gesture instead;
    // a background click also ends (commits) an in-progress inline edit.
    override func mouseDown(with event: NSEvent) {
        endTextEditing()
    }

    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}

    private func renderWorkspacePicker() {
        wsPickerContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let name = workspaces.first(where: { $0.id == currentWsId })?.name
        let pill = TaskPillButton(
            title: name ?? "No Workspace", symbol: "square.grid.2x2",
            tint: name == nil ? Theme.textGrey : Theme.textSecondary, dimmed: name == nil)
        pill.onTap = { [weak self, weak pill] in
            guard let self, let pill else { return }
            self.showWorkspaceMenu(from: pill)
        }
        wsPickerContainer.addArrangedSubview(pill)
    }

    private func showWorkspaceMenu(from anchor: NSView) {
        let menu = NSMenu()
        for choice in workspaces {
            let item = NSMenuItem(title: choice.name, action: #selector(workspacePicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.id
            item.state = choice.id == currentWsId ? .on : .off
            menu.addItem(item)
        }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let none = NSMenuItem(title: "No Workspace", action: #selector(workspacePicked(_:)), keyEquivalent: "")
        none.target = self
        none.representedObject = ""
        none.state = currentWsId.isEmpty ? .on : .off
        menu.addItem(none)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func workspacePicked(_ sender: NSMenuItem) {
        guard let wsId = sender.representedObject as? String, wsId != currentWsId else { return }
        currentWsId = wsId
        renderWorkspacePicker()
        onAssignWorkspace?(taskId, wsId)
    }

    @objc private func closeClicked() {
        onClose?()
    }
}
