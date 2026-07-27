// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — binds the AppCoordinator (PROTOCOL.md §7) to the AppKit chrome
// (TabBarView, WorkspaceSwitcherView, LayoutTreeView). Owns the window lifecycle
// and routes user actions (select/close/new tab, switch workspace) into the
// coordinator, and coordinator updates back into the views.

import AppKit
import WaveCore
import WaveLayout

@MainActor
public final class WaveWindowController: NSWindowController, AppCoordinatorDelegate, NSWindowDelegate {
    private let coordinator: AppCoordinator
    private let provider: BlockViewProvider

    /// App-global menu bar (owned by the delegate). The controller pushes its
    /// workspace list here so the Workspace submenu stays live, mirroring Electron
    /// rebuilding the menu on `workspace:update`.
    weak var menuBar: MenuBarController?

    /// The multi-window owner. Workspace navigation (switcher / Cmd-Shift-O / menu)
    /// routes here so selecting a workspace focuses-or-opens ITS window instead of
    /// repointing this one. Nil only in legacy single-window/test setups.
    weak var windowManager: WindowManager?

    /// Fired once the coordinator binds its backend window/workspace, handing the
    /// WindowManager the full window list so it can open the remaining windows.
    var onDidBind: ((_ windowId: String, _ workspaceId: String, _ allWindowIds: [String]) -> Void)?

    /// Fired when this window actually closes, so the WindowManager deregisters the
    /// pair and disconnects its transport (the app stays alive unless it was the last).
    var onWindowClosed: (() -> Void)?

    private let tabBar = TabBarView()
    private var rootContent: RootContentView!
    private var layoutViews: [String: LayoutTreeView] = [:]

    // Cached chrome state for the Cmd-K / Cmd-Shift-O quick-open overlays. Kept in
    // sync from the coordinator delegate pushes so the overlays render instantly.
    private var workspaceItems: [WorkspaceMenuItem] = []
    private var activeWorkspaceId: String?
    private var tabItems: [TabBarItem] = []
    private var activeTabId: String?
    private var overlay: QuickOpenOverlayView?

    public init(coordinator: AppCoordinator, provider: BlockViewProvider) {
        self.coordinator = coordinator
        self.provider = provider

        let window = WaveWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720))
        super.init(window: window)

        rootContent = RootContentView(tabBar: tabBar)
        window.contentView = rootContent
        window.center()
        window.delegate = self
        // We restore window frames ourselves (WindowManager, keyed by workspace). Disable
        // AppKit's automatic window-state restoration and NSWindowController's show-time
        // cascade so neither fights our explicit setFrame on bind.
        window.isRestorable = false
        shouldCascadeWindows = false

        wireActions()
        installGlobalKeyHandler()
        coordinator.delegate = self

        applyToAllObserver = NotificationCenter.default.addObserver(
            forName: AppCoordinator.applyAppearanceToAllNotification, object: nil, queue: .main
        ) { [weak self] note in self?.applyBroadcastAppearance(note) }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let applyToAllObserver { NotificationCenter.default.removeObserver(applyToAllObserver) }
    }

    /// This window's PER-WINDOW appearance (gear popover). Seeded from the global config
    /// when the window binds, then driven by this window's popover. Each change persists to
    /// the global config (`persistWindowAppearance`) so a reset survives a restart; "Apply
    /// to All Windows" additionally pushes it live to every open window.
    private var windowAppearance = WindowAppearance(transparent: false, blur: false, opacity: 1.0)

    /// Token for the "Apply to All Windows" broadcast observer (removed in `deinit`).
    private var applyToAllObserver: NSObjectProtocol?

    /// The per-window appearance popover (anchored to the gear), built lazily on first open.
    private var appearancePopover: NSPopover?
    private var appearanceController: AppearancePopoverController?

    /// Push this window's appearance to its NSWindow, and tell the composition root to
    /// re-dim this window's terminals (its libghostty backgrounds live in WaveTerminal).
    private func applyWindowAppearance() {
        guard let waveWindow = window as? WaveWindow else { return }
        waveWindow.applyAppearance(windowAppearance)
        NotificationCenter.default.post(
            name: AppCoordinator.windowAppearanceChangedNotification, object: waveWindow)
    }

    /// Persist the current appearance to the GLOBAL config (`window:*`). The gear popover
    /// is otherwise live-only, so a "reset" (e.g. transparency off) was lost on the next
    /// launch — the window reloaded the stale persisted config and came up transparent
    /// again. Writing the keys here makes a change stick across restarts. There is no
    /// per-window persistence store, so the last change becomes the global default.
    private func persistWindowAppearance() {
        coordinator.setConfigValue("window:transparent", .bool(windowAppearance.transparent))
        coordinator.setConfigValue("window:blur", .bool(windowAppearance.blur))
        coordinator.setConfigValue("window:opacity", .double(windowAppearance.opacity))
    }

    /// Apply an appearance broadcast by another window's "Apply to All Windows" button.
    /// Live-only here; the originator already persisted to the global config.
    private func applyBroadcastAppearance(_ note: Notification) {
        guard let info = note.userInfo else { return }
        windowAppearance = WindowAppearance(
            transparent: info["transparent"] as? Bool ?? windowAppearance.transparent,
            blur: info["blur"] as? Bool ?? windowAppearance.blur,
            opacity: info["opacity"] as? Double ?? windowAppearance.opacity)
        applyWindowAppearance()
        appearanceController?.update(appearance: windowAppearance)
    }

    /// Show the window and run the §7 init sequence.
    public func startApp() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        coordinator.start()
    }

    private func wireActions() {
        tabBar.onSelectTab = { [weak self] id in self?.coordinator.selectTab(id) }
        tabBar.onCloseTab = { [weak self] id in self?.coordinator.closeTab(id) }
        tabBar.onNewTab = { [weak self] in self?.coordinator.newTab() }
        tabBar.onSelectWorkspace = { [weak self] id in self?.navigateToWorkspace(id) }
        tabBar.onCreateWorkspace = { [weak self] name in self?.createWorkspace(named: name) }
        tabBar.onRenameWorkspace = { [weak self] id, name in self?.coordinator.renameWorkspace(id, name: name) }
        tabBar.onSetWorkspaceColor = { [weak self] id, hex in self?.coordinator.setWorkspaceColor(id: id, color: hex) }
        tabBar.onSetWorkspaceIcon = { [weak self] id, icon in self?.coordinator.setWorkspaceIcon(id: id, icon: icon) }
        tabBar.onSaveWorkspace = { [weak self] id in self?.coordinator.saveWorkspace(id) }
        tabBar.onDeleteWorkspace = { [weak self] id in self?.coordinator.deleteWorkspace(id) }
        tabBar.onSaveWorkspaceLayout = { [weak self] id in self?.coordinator.saveWorkspaceLayout(id) }
        tabBar.onResetWorkspaceLayout = { [weak self] id in self?.coordinator.restoreWorkspaceLayout(id) }
        tabBar.onMoveTab = { [weak self] tabId, wsId in
            self?.coordinator.moveTabToWorkspace(tabId: tabId, workspaceId: wsId)
        }
        tabBar.onReorderTabs = { [weak self] tabIds in
            self?.coordinator.reorderTabs(tabIds: tabIds)
        }
        tabBar.onMoveTabFromDrag = { [weak self] tabId, sourceWs in
            self?.coordinator.receiveTabDrop(tabId: tabId, fromWorkspaceId: sourceWs)
        }
        tabBar.onMoveBlockToTab = { [weak self] blockId, tabId in
            self?.coordinator.receiveBlockDrop(blockId: blockId, targetTabId: tabId)
        }
        rootContent.activeTabIdProvider = { [weak self] in self?.activeTabId }
        rootContent.onBlockDrop = { [weak self] blockId, tabId in
            self?.coordinator.receiveBlockDrop(blockId: blockId, targetTabId: tabId)
        }
        tabBar.onRenameTab = { [weak self] tabId, name in
            self?.coordinator.renameTab(tabId: tabId, name: name)
        }
        tabBar.onSetTabFlagColor = { [weak self] tabId, color in
            self?.coordinator.setTabFlagColor(tabId: tabId, color: color)
        }
        tabBar.onSetTabBackground = { [weak self] tabId, patch in
            self?.coordinator.setTabBackground(tabId: tabId, meta: patch)
        }
        tabBar.onShowSettings = { [weak self] in self?.toggleAppearancePopover() }
        rootContent.widgetBar.onSelect = { [weak self] meta, magnified in
            self?.coordinator.createWidgetBlock(meta: meta, magnified: magnified)
        }
        // A tab inline-rename steals window firstResponder for its editor; when the
        // edit ends (commit/cancel/blur) hand focus back to the visible pane's terminal
        // so typing keeps reaching the shell.
        tabBar.onRenameSessionEnd = { [weak self] in self?.refocusActiveBlock() }
    }

    // MARK: - Menu bar routing
    //
    // Public seams the app-global `MenuBarController` calls on the key window's
    // controller. Each forwards to an existing coordinator op, so the menu shares the
    // exact paths the chrome and the global key handler already use.

    public func menuNewTab() { coordinator.newTab() }
    public func menuNewWindow() { openNewWindow() }
    public func menuCloseActiveTab() { coordinator.closeActiveTab() }
    public func menuSplit(direction: String) { coordinator.splitFocused(direction: direction) }
    public func menuMagnify() { coordinator.magnifyFocused() }
    public func menuCreateWorkspace() { createWorkspace(named: "") }
    public func menuSwitchWorkspace(_ workspaceId: String) { navigateToWorkspace(workspaceId) }

    // MARK: - Workspace navigation (workspace per window)

    /// Focus-or-open the workspace's own window via the WindowManager. Falls back to
    /// the legacy in-place switch only when there is no manager (single-window/tests).
    private func navigateToWorkspace(_ workspaceId: String) {
        guard let windowManager else {
            coordinator.switchWorkspace(workspaceId)
            return
        }
        windowManager.focusOrOpen(workspaceId: workspaceId)
    }

    /// Create a new workspace in its own window (or legacy in-place when unmanaged).
    /// `name` comes from the dropdown composer; empty means backend default naming
    /// (menu / quick-open paths, which have no name field).
    private func createWorkspace(named name: String) {
        guard let windowManager else {
            coordinator.createWorkspace(named: name)
            return
        }
        windowManager.createAndOpenWorkspace(named: name)
    }

    /// Open the single shared app-level Settings window, targeting THIS window's
    /// coordinator (its live config). Cmd-, / the app menu route here, so they focus one
    /// shared window regardless of which window is key. (The tab-bar gear now opens the
    /// per-window appearance popover, which has a "More settings…" link back to here.)
    public func menuShowSettings() {
        SettingsWindowController.shared.present(coordinator: coordinator)
    }

    /// Open the raw `settings.json` editor (Electron parity), targeting THIS window's
    /// coordinator. Reachable from the gear popover's "Edit config…" and the app menu.
    public func menuEditConfig() {
        ConfigEditorWindowController.shared.present(coordinator: coordinator)
    }

    // MARK: - Per-window appearance popover (gear)

    /// Toggle the gear popover. The controls apply live to THIS window only.
    private func toggleAppearancePopover() {
        if let popover = appearancePopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let controller = appearanceController ?? makeAppearanceController()
        controller.update(appearance: windowAppearance)
        let popover = appearancePopover ?? makeAppearancePopover(controller)
        let anchor = tabBar.settingsAnchorView
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func makeAppearanceController() -> AppearancePopoverController {
        let controller = AppearancePopoverController(appearance: windowAppearance)
        controller.onOpacityChange = { [weak self] v in
            self?.windowAppearance.opacity = v
            self?.applyWindowAppearance()
            self?.coordinator.setConfigValue("window:opacity", .double(v))
        }
        controller.onTransparentChange = { [weak self] on in
            self?.windowAppearance.transparent = on
            self?.applyWindowAppearance()
            self?.coordinator.setConfigValue("window:transparent", .bool(on))
        }
        controller.onBlurChange = { [weak self] on in
            self?.windowAppearance.blur = on
            self?.applyWindowAppearance()
            self?.coordinator.setConfigValue("window:blur", .bool(on))
        }
        controller.onApplyToAll = { [weak self] in
            guard let self else { return }
            self.persistWindowAppearance()
            NotificationCenter.default.post(
                name: AppCoordinator.applyAppearanceToAllNotification,
                object: nil,
                userInfo: [
                    "transparent": self.windowAppearance.transparent,
                    "blur": self.windowAppearance.blur,
                    "opacity": self.windowAppearance.opacity,
                ])
        }
        controller.onEditConfig = { [weak self] in
            self?.appearancePopover?.performClose(nil)
            self?.menuEditConfig()
        }
        controller.onMoreSettings = { [weak self] in
            self?.appearancePopover?.performClose(nil)
            self?.menuShowSettings()
        }
        appearanceController = controller
        return controller
    }

    private func makeAppearancePopover(_ controller: AppearancePopoverController) -> NSPopover {
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        appearancePopover = popover
        return popover
    }

    /// "Quit and Close All Shells" (⌥⌘Q): destructively terminate every durable local
    /// shell, then quit. Normal Quit leaves the wsh job-managers running for reconnect;
    /// this kills them first. The app is terminated only after the teardown resolves so
    /// the kill commands are actually sent (and a failure still quits — the user asked
    /// to quit). Routed from the app menu via MenuBarController.
    public func menuQuitAndCloseAllShells() {
        Task { [weak self] in
            defer { NSApp.terminate(nil) }
            _ = try? await self?.coordinator.terminateAllShells()
        }
    }

    // MARK: - App-global keyboard shortcuts

    /// Install the window-level shortcut handler. It runs only after the focused
    /// view declines the event (see `WaveWindow.performKeyEquivalent`), so the
    /// terminal's own Cmd-C/V/D/M and a rename field's edit keys stay intact.
    private func installGlobalKeyHandler() {
        (window as? WaveWindow)?.onKeyEquivalent = { [weak self] event in
            self?.handleGlobalKey(event) ?? false
        }
        (window as? WaveWindow)?.onPreemptKeyEquivalent = { [weak self] event in
            self?.handlePreemptKey(event) ?? false
        }
    }

    /// Shortcuts that must run BEFORE the responder chain (the window's preempt
    /// hook), because a focused WKWebView claims every ⌘ key equivalent (it forwards
    /// them to the page and returns true), so nothing ⌘-based would ever reach
    /// `handleGlobalKey` from a web pane:
    ///   * ⌘⌥ Arrow pane navigation — preempted for EVERY pane (terminals never
    ///     consume ⌘⌥-arrows, so this shadows nothing).
    ///   * The app-global bindings — preempted only while web PAGE content holds
    ///     focus, mirroring Electron (globals intercept before the page). Keys the
    ///     globals decline (⌘C/V/A/F…) still reach the page, and ⌘←/→ are excluded
    ///     so they keep their browser meaning (history back/forward) instead of tab
    ///     switching; ⌘[/⌘] stay tab switching, matching every non-web pane.
    private func handlePreemptKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first?.value
        if let dir = Self.paneNavDirection(flags: flags, scalar: scalar) {
            activeLayoutView?.navigatePane(dir)
            return true
        }
        if activeLayoutView?.firstResponderIsWebPageContent == true, !Self.isWebHistoryKey(scalar: scalar) {
            return handleGlobalKey(event)
        }
        return false
    }

    /// Whether a ⌘ key event must stay with focused web page content instead of
    /// being preempted for the app-global bindings: ⌘←/→ are browser history
    /// back/forward there, so tab switching yields to them (only) in that state.
    static func isWebHistoryKey(scalar: UInt32?) -> Bool {
        guard let scalar else { return false }
        return Int(scalar) == NSLeftArrowFunctionKey || Int(scalar) == NSRightArrowFunctionKey
    }

    /// Match Electron's app-global bindings (`keymodel.ts` `registerGlobalKeys`).
    /// Every shortcut here is Cmd-based with no Ctrl/Option, so terminal Ctrl-combos
    /// and Option-as-Meta input are never shadowed. Returns true when consumed.
    private func handleGlobalKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ⌘⌥ Arrow pane navigation lives in `handlePreemptKey` (the window's preempt
        // hook); plain ⌘ Arrow (no Option) still falls through to tab switching below.

        guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else { return false }
        let shift = flags.contains(.shift)
        let chars = event.charactersIgnoringModifiers ?? ""
        let lower = chars.lowercased()

        // ⌘⇧Return → toggle magnify (maximize) of the focused pane (iTerm2 parity; a second
        // binding alongside ⌘M). 36 = Return, 76 = keypad Enter.
        if shift, event.keyCode == 36 || event.keyCode == 76 {
            coordinator.magnifyFocused()
            return true
        }

        // Cmd-1..Cmd-9 → switch to tab by absolute (1-based) index.
        if !shift, let d = chars.first, let n = d.wholeNumberValue, n >= 1, n <= 9 {
            coordinator.switchTabByIndex(n)
            return true
        }

        // Bracket next/prev tab (Cmd-] / Cmd-[ , with or without Shift). Matched by
        // keyCode so the shifted "}"/"{" characters resolve to the same action.
        switch event.keyCode {
        case 30: coordinator.switchTabRelative(1); return true   // ]
        case 33: coordinator.switchTabRelative(-1); return true  // [
        default: break
        }

        // Cmd-Arrow tab switching (reached only after the focused block declines).
        if let scalar = chars.unicodeScalars.first {
            switch Int(scalar.value) {
            case NSRightArrowFunctionKey: coordinator.switchTabRelative(1); return true
            case NSLeftArrowFunctionKey: coordinator.switchTabRelative(-1); return true
            default: break
            }
        }

        guard let action = Self.letterAction(lower: lower, shift: shift) else { return false }
        perform(action)
        return true
    }

    /// The ⌘⌥ arrow → pane-navigation direction, as a pure mapping (like `letterAction`)
    /// so the modifier matching is unit-testable. `scalar` is the `charactersIgnoringModifiers`
    /// base-character value. Uses `.contains` rather than set-equality on `flags` because
    /// macOS sets `.function` AND `.numericPad` on arrow-key events — an `== [.command, .option]`
    /// check would never match a real ⌘⌥arrow.
    static func paneNavDirection(flags: NSEvent.ModifierFlags, scalar: UInt32?) -> PaneDirection? {
        guard flags.contains(.command), flags.contains(.option),
              !flags.contains(.control), !flags.contains(.shift),
              let scalar else { return nil }
        switch Int(scalar) {
        case NSLeftArrowFunctionKey: return .left
        case NSRightArrowFunctionKey: return .right
        case NSUpArrowFunctionKey: return .up
        case NSDownArrowFunctionKey: return .down
        default: return nil
        }
    }

    /// The app-global Cmd-letter shortcuts, as a pure mapping so the routing is unit
    /// -testable without synthesizing NSEvents or a live window. `lower` is the
    /// lowercased `charactersIgnoringModifiers`; `shift` is whether Shift is held.
    enum GlobalKeyAction: Equatable {
        case workspaceSwitcher, tabSwitcher, newTab, newWindow, closeBlock, closeTab
        case splitHorizontal, splitVertical, magnify, refocus, reload, jobPicker
    }

    static func letterAction(lower: String, shift: Bool) -> GlobalKeyAction? {
        switch lower {
        case "o" where shift: return .workspaceSwitcher
        case "k" where !shift: return .tabSwitcher
        case "j" where shift: return .jobPicker
        case "t" where !shift: return .newTab
        // Cmd-N opens a NEW WINDOW (Electron `handleNewWindow`), not a new block.
        case "n" where !shift: return .newWindow
        case "w" where !shift: return .closeBlock
        case "w" where shift: return .closeTab
        case "d" where !shift: return .splitHorizontal
        case "d" where shift: return .splitVertical
        case "m" where !shift: return .magnify
        case "i" where !shift: return .refocus
        // Cmd-R / Cmd-Shift-R reload the focused web block (Electron's webview reload).
        // A no-op when the focused pane is a terminal (its nav bridge has no reload).
        case "r": return .reload
        default: return nil
        }
    }

    private func perform(_ action: GlobalKeyAction) {
        switch action {
        case .workspaceSwitcher: showWorkspaceSwitcher()
        case .tabSwitcher: showTabSwitcher()
        case .newTab: coordinator.newTab()
        case .newWindow: openNewWindow()
        case .closeBlock: coordinator.closeFocusedBlock()
        case .closeTab: coordinator.closeActiveTab()
        case .splitHorizontal: coordinator.splitFocused(direction: "horizontal")
        case .splitVertical: coordinator.splitFocused(direction: "vertical")
        case .magnify: coordinator.magnifyFocused()
        case .refocus: refocusActiveBlock()
        case .reload: reloadFocusedBlock()
        case .jobPicker: showJobPicker()
        }
    }

    /// Cmd-R / Cmd-Shift-R: reload the focused block's web content. Routed through the
    /// visible layout view → focused block frame → `env.webNav.reload` (the WaveUI↔
    /// WaveWeb bridge), so WaveUI never imports WaveWeb; it is a no-op when the focused
    /// pane is a terminal (its bridge has no reload action wired).
    private func reloadFocusedBlock() {
        layoutViews.values.first(where: { !$0.isHidden })?.reloadFocusedBlock()
    }

    /// Open a brand-new window. In the workspace-per-window model a new window means a
    /// new workspace, so this defers to the WindowManager (no-op in unmanaged/test setups).
    private func openNewWindow() {
        windowManager?.openNewWindow()
    }

    /// Cmd-I (Electron `globalRefocus`): move firstResponder back onto the visible
    /// tab's focused pane. The visible layout view is the only un-hidden one.
    private func refocusActiveBlock() {
        guard overlay == nil else { return }
        layoutViews.values.first(where: { !$0.isHidden })?.focusActiveBlock()
    }

    // MARK: - Quick-open overlays (Cmd-Shift-O / Cmd-K)

    /// Reserved id for the synthetic "create workspace" row in the Cmd-Shift-O
    /// overlay; not a real workspace oid, so it can't collide with one.
    private static let createWorkspaceItemId = "__create-workspace__"

    /// Cmd-Shift-O: centered overlay of all workspaces, plus a trailing
    /// "+ Create workspace" action. Selecting a workspace reuses the existing chrome
    /// path `AppCoordinator.switchWorkspace(_:)`; the action calls `createWorkspace`.
    private func showWorkspaceSwitcher() {
        var items = workspaceItems.map {
            QuickOpenItem(id: $0.workspaceId, title: $0.name, icon: $0.icon, color: $0.color)
        }
        items.append(QuickOpenItem(id: Self.createWorkspaceItemId, title: "+  Create workspace"))
        presentOverlay(placeholder: "Switch workspace…", items: items, initialSelectionId: activeWorkspaceId) {
            [weak self] id in
            guard let self else { return }
            if id == Self.createWorkspaceItemId {
                self.createWorkspace(named: "")
                return
            }
            self.navigateToWorkspace(id)
        }
    }

    /// Cmd-K: centered overlay of the active workspace's tabs (strip order). Selecting
    /// one reuses the existing chrome path `AppCoordinator.selectTab(_:)`.
    private func showTabSwitcher() {
        let items = tabItems.map { QuickOpenItem(id: $0.tabId, title: $0.name) }
        guard !items.isEmpty else { return }
        presentOverlay(placeholder: "Go to tab…", items: items, initialSelectionId: activeTabId) {
            [weak self] id in self?.coordinator.selectTab(id)
        }
    }

    /// Sentinel row id for the empty job-picker state; selecting it is a no-op.
    private static let noJobsItemId = "__no-detached-jobs__"

    /// Cmd-Shift-J: centered overlay of running durable shell sessions that have no
    /// live pane (their block was closed/lost — e.g. deleted while the backend was
    /// down). Selecting one reattaches it into a NEW terminal pane in the active tab
    /// (`AppCoordinator.reattachJob`). Menu: File → Reattach Shell Session…
    func showJobPicker() {
        Task { [weak self] in
            guard let self else { return }
            let jobs = await self.coordinator.listDetachedShellJobs()
            var items = jobs.map { job in
                QuickOpenItem(id: job.oid, title: Self.jobPickerTitle(job))
            }
            if items.isEmpty {
                items = [QuickOpenItem(id: Self.noJobsItemId, title: "No detached shell sessions")]
            }
            self.presentOverlay(placeholder: "Reattach shell session…", items: items,
                                initialSelectionId: items.first?.id) { [weak self] id in
                guard let self, id != Self.noJobsItemId,
                      let job = jobs.first(where: { $0.oid == id }) else { return }
                self.coordinator.reattachJob(job)
            }
        }
    }

    /// "conn — cmd · jobid8" row title for the reattach picker. Pure, unit-testable.
    static func jobPickerTitle(_ job: JobInfo) -> String {
        let conn = (job.connection?.isEmpty == false) ? job.connection! : "local"
        let cmd = (job.cmd?.isEmpty == false) ? job.cmd! : "shell"
        return "\(conn) — \(cmd) · \(job.oid.prefix(8))"
    }

    private func presentOverlay(placeholder: String, items: [QuickOpenItem],
                                initialSelectionId: String?, allowFreeEntry: Bool = false,
                                onSelect: @escaping (String) -> Void) {
        dismissOverlay()
        let view = QuickOpenOverlayView(placeholder: placeholder, items: items,
                                        initialSelectionId: initialSelectionId, allowFreeEntry: allowFreeEntry)
        view.onSelect = { [weak self] id in
            self?.dismissOverlay()
            onSelect(id)
        }
        view.onDismiss = { [weak self] in self?.dismissOverlay() }
        view.translatesAutoresizingMaskIntoConstraints = false
        rootContent.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: rootContent.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: rootContent.trailingAnchor),
            view.topAnchor.constraint(equalTo: rootContent.topAnchor),
            view.bottomAnchor.constraint(equalTo: rootContent.bottomAnchor),
        ])
        overlay = view
        view.focusSearch()
    }

    private func dismissOverlay() {
        guard let overlay else { return }
        overlay.removeFromSuperview()
        self.overlay = nil
        // Hand firstResponder back to the visible tab's terminal.
        refocusActiveBlock()
    }

    // MARK: - AppCoordinatorDelegate

    public func coordinatorDidUpdateWorkspace(name: String?, icon: String?, color: String?, workspaceId: String?) {
        activeWorkspaceId = workspaceId
        tabBar.setWorkspace(name: name, icon: icon, color: color, workspaceId: workspaceId)
        menuBar?.updateWorkspaces(workspaceItems, activeId: workspaceId)
    }

    public func coordinatorDidUpdateWorkspaceList(_ items: [WorkspaceMenuItem]) {
        workspaceItems = items
        tabBar.setWorkspaceItems(items)
        menuBar?.updateWorkspaces(items, activeId: activeWorkspaceId)
    }

    public func coordinatorDidUpdateWorkspacePalette(colors: [String], icons: [String]) {
        tabBar.setWorkspacePalette(colors: colors, icons: icons)
    }

    public func coordinatorDidUpdateTabs(_ tabs: [TabBarItem], activeTabId: String?) {
        tabItems = tabs
        self.activeTabId = activeTabId
        tabBar.setTabs(tabs, activeTabId: activeTabId)
        // Drop cached layout views for tabs that LEFT this window (closed, or moved to
        // another workspace by drag). A moved tab's stale view otherwise stays mounted
        // (hidden) with live terminal stacks: performKeyEquivalent still walks hidden
        // views, so a Cmd-D in this (still-key) window could land on the moved tab's
        // zombie terminal and split against the wrong tab/window.
        //
        // The VISIBLE view is spared here even if its tab just left: the replacement
        // tab activates asynchronously, and removing the departed content immediately
        // flashed an empty window until the next layout rendered. It is swept by
        // `coordinatorDidUpdateLayout` the moment the replacement view is shown.
        let live = Set(tabs.map { $0.tabId })
        for (tabId, view) in layoutViews where !live.contains(tabId) && view.isHidden {
            view.removeFromSuperview()
            layoutViews.removeValue(forKey: tabId)
        }
    }

    public func coordinatorDidUpdateTabBarPosition(_ position: String) {
        rootContent.setTabBarPosition(position)
    }

    /// Last background pushed to the chrome; gates the appearance notification.
    private var lastTabBackground: TabBackgroundConfig?
    private var hasPublishedTabBackground = false

    public func coordinatorDidUpdateTabBackground(_ config: TabBackgroundConfig?) {
        rootContent.setTabBackground(config)
        // Terminals re-derive their background alpha from the window (the
        // composition root listens for this), so panes reveal the background.
        // Post ONLY when the background actually changed: this fires on every
        // publishTabs (tab switch), and the notification re-applies appearance
        // to every live terminal -- a storm with ~100 shells.
        guard !hasPublishedTabBackground || config != lastTabBackground else { return }
        hasPublishedTabBackground = true
        lastTabBackground = config
        if let waveWindow = window as? WaveWindow {
            NotificationCenter.default.post(
                name: AppCoordinator.windowAppearanceChangedNotification, object: waveWindow)
        }
    }

    public func coordinatorDidUpdateBackgroundPresets(_ presets: [TabBackgroundPreset]) {
        tabBar.setBackgroundPresets(presets)
    }

    public func coordinatorRequestFocusBlock(_ blockId: String) {
        // Raise the main window first: Navigate from the (separate) Settings
        // window must bring the pane forward; a no-op when already key.
        // An explicit navigate supersedes any open quick-open overlay.
        dismissOverlay()
        window?.makeKeyAndOrderFront(nil)
        let visible = layoutViews.values.first(where: { !$0.isHidden })
        dndLog("controller requestFocusBlock block=\(blockId.suffix(4)) visibleTab=\(visible?.tabId.suffix(4) ?? "nil") activeTab=\(activeTabId?.suffix(4) ?? "nil")")
        visible?.focusBlock(blockId)
    }

    public func coordinatorDidUpdateLayout(env: BlockEnvFactory, root: LayoutNode?, focusedNodeId: String?, magnifiedNodeId: String?) {
        // Keep ONE layout view per tab alive across tab switches (show the active
        // tab's, hide the rest). Recreating it on every switch would re-mount the
        // tab's terminals — re-running backfill plus a resize-driven prompt redraw,
        // which duplicates the last line. Mirrors Wave keeping blocks mounted.
        let view: LayoutTreeView
        if let existing = layoutViews[env.tabId] {
            view = existing
        } else {
            view = LayoutTreeView(env: env, provider: provider)
            view.onFocusBlock = { [weak self] _, _ in
                // Local focus only; persisting focusednodeid to the LayoutState is
                // WaveLayout's responsibility (PROTOCOL §6). Flagged in report.
                _ = self
            }
            view.onLayoutAction = { [weak self] action in
                self?.coordinator.dispatchLayout(action)
            }
            view.translatesAutoresizingMaskIntoConstraints = false
            rootContent.contentArea.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: rootContent.contentArea.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: rootContent.contentArea.trailingAnchor),
                view.topAnchor.constraint(equalTo: rootContent.contentArea.topAnchor),
                view.bottomAnchor.constraint(equalTo: rootContent.contentArea.bottomAnchor),
            ])
            layoutViews[env.tabId] = view
        }
        for (tabId, v) in layoutViews { v.isHidden = (tabId != env.tabId) }
        // Sweep departed-tab views spared by `coordinatorDidUpdateTabs` (kept on screen
        // so the window never flashed empty while the replacement tab loaded) — the
        // replacement is visible as of this publish.
        let liveTabs = Set(tabItems.map { $0.tabId })
        for (tabId, v) in layoutViews where tabId != env.tabId && !liveTabs.contains(tabId) {
            v.removeFromSuperview()
            layoutViews.removeValue(forKey: tabId)
        }
        // The visible layout view just changed; re-sync its opacity to the active tab's
        // background so a switched-to tab reveals (or hides) the background correctly.
        rootContent.applyTabBackgroundToPanes()
        view.setLayout(root: root, focusedNodeId: focusedNodeId, magnifiedNodeId: magnifiedNodeId)
        // Defer to the next runloop turn so the show/hide + tiling settle before
        // we move firstResponder (firstResponder timing is a known gotcha).
        // Skip while a quick-open overlay is up: layout publishes arrive async and
        // would silently yank firstResponder from the overlay's search field back
        // to the pane behind the scrim.
        DispatchQueue.main.async { [weak self] in
            guard self?.overlay == nil else { return }
            view.focusActiveBlock()
        }
    }


    public func coordinatorDidBind(windowId: String, workspaceId: String, allWindowIds: [String]) {
        onDidBind?(windowId, workspaceId, allWindowIds)
    }

    public func coordinatorDidBecomeReady() {
        // fullConfig is loaded by now, so the widget bar can be populated. Toggling the
        // bar's hidden state changes the content inset, so force a root re-layout.
        rootContent.widgetBar.setItems(coordinator.widgetItems())
        rootContent.needsLayout = true
        // Seed this window's appearance from the global config DEFAULTS once (a
        // hand-edited window:opacity becomes the starting point), then it is driven
        // per-window by the gear popover.
        windowAppearance = WindowAppearance.from(coordinator.currentSettings())
        applyWindowAppearance()
    }

    public func coordinatorRequestCloseWindow() {
        window?.performClose(nil)
    }

    public func coordinatorOpenWorkspaceIds() -> Set<String> {
        windowManager?.openWorkspaceIds ?? []
    }

    public func coordinatorWillDeleteBlock(_ block: Block) {
        provider.releaseResources(forBlock: block)
    }

    public func coordinatorCwdForBlock(_ blockId: String) -> String? {
        provider.cwdForBlock(blockId)
    }

    public func coordinatorIsWindowKey() -> Bool {
        window?.isKeyWindow ?? false
    }

    /// Reserved id for the synthetic "Local" row in the connection typeahead. Maps to
    /// the empty/local connection (clears a block's `connection` meta).
    private static let localConnItemId = "__local__"

    public func coordinatorPresentConnectionPicker(
        blockId: String, current: String?, connections: [String], onSelect: @escaping (String) -> Void
    ) {
        var items = [QuickOpenItem(id: Self.localConnItemId, title: "Local")]
        items.append(contentsOf: connections.map { QuickOpenItem(id: $0, title: $0) })
        let initial = (current == nil || current!.isEmpty) ? Self.localConnItemId : current
        presentOverlay(placeholder: "Connect to…", items: items,
                       initialSelectionId: initial, allowFreeEntry: true) { id in
            if id == Self.localConnItemId {
                onSelect("local")
                return
            }
            if id.hasPrefix(QuickOpenOverlayView.freeEntryPrefix) {
                onSelect(String(id.dropFirst(QuickOpenOverlayView.freeEntryPrefix.count)))
                return
            }
            onSelect(id)
        }
    }

    // MARK: - NSWindowDelegate

    /// Async close veto (red button / performClose): confirm when an application is
    /// still running in any of the workspace's shells. AppKit needs a synchronous
    /// answer, so always refuse here and re-close programmatically once the check
    /// (and, if needed, the user) says yes — `close()` bypasses this delegate.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor [weak self] in
            guard let self, let window = self.window else { return }
            if await self.coordinator.shouldCloseWindow() {
                window.close()
            }
        }
        return false
    }

    public func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }

    public func windowDidMove(_ notification: Notification) {
        windowManager?.windowFrameDidChange(self)
    }

    public func windowDidResize(_ notification: Notification) {
        windowManager?.windowFrameDidChange(self)
    }

    /// The visible tab's layout view (the only un-hidden one), or nil before any tab
    /// has rendered. Shared by the key-state and refocus paths.
    private var activeLayoutView: LayoutTreeView? {
        layoutViews.values.first(where: { !$0.isHidden })
    }

    /// Only the MAIN window shows the green focus border. A background window keeps its
    /// `focusedNodeId` but drops the border so it can't masquerade as focused. Main (not
    /// key) drives this: a tab drag bounces KEY to the drag flotilla window for a few ms
    /// at drag start/drop, which flickered a key-gated border; main stays put.
    public func windowDidBecomeMain(_ notification: Notification) {
        activeLayoutView?.setWindowActive(true)
    }

    public func windowDidResignMain(_ notification: Notification) {
        activeLayoutView?.setWindowActive(false)
    }

    public func coordinatorDidFail(_ error: Error) {
        NSLog("WaveUI: coordinator error: \(error)")
        let alert = NSAlert()
        alert.messageText = "Wave failed to start"
        alert.informativeText = "\(error)"
        alert.alertStyle = .critical
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    /// Backend `userinput` prompt (SSH password / key passphrase / keyboard-interactive
    /// / unknown host key / wsh install consent) as a window sheet. `confirm` prompts
    /// map to OK/Cancel (+ optional checkbox); `text` prompts get a text field —
    /// SECURE unless `publictext` (passwords must never echo). Auto-dismisses as
    /// cancelled at `timeoutms` so an unanswered prompt doesn't strand a sheet after
    /// the backend has already timed out. AppKit queues concurrent sheets FIFO, which
    /// also serializes overlapping prompts (e.g. password + host key).
    public func coordinatorPresentUserInput(_ request: UserInputRequest) async -> UserInputResponse {
        guard let window else { return .cancelled(for: request) }
        let alert = NSAlert()
        alert.messageText = request.title.isEmpty ? "Wave" : request.title
        alert.informativeText = Self.userInputPlainText(request.querytext, markdown: request.markdown)
        alert.alertStyle = .informational
        alert.addButton(withTitle: (request.oklabel?.isEmpty == false) ? request.oklabel! : "OK")
        alert.addButton(withTitle: (request.cancellabel?.isEmpty == false) ? request.cancellabel! : "Cancel")

        var textField: NSTextField?
        var checkbox: NSButton?
        var accessories: [NSView] = []
        if request.responsetype == "text" {
            let field: NSTextField = request.publictext
                ? NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                : NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            textField = field
            accessories.append(field)
        }
        if !request.checkboxmsg.isEmpty {
            let box = NSButton(checkboxWithTitle: request.checkboxmsg, target: nil, action: nil)
            checkbox = box
            accessories.append(box)
        }
        if !accessories.isEmpty {
            let stack = NSStackView(views: accessories)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.frame = NSRect(x: 0, y: 0, width: 260,
                                 height: CGFloat(accessories.count) * 28)
            alert.accessoryView = stack
            if let textField { alert.window.initialFirstResponder = textField }
        }

        return await withCheckedContinuation { cont in
            var finished = false
            alert.beginSheetModal(for: window) { resp in
                guard !finished else { return }
                finished = true
                let accepted = (resp == .alertFirstButtonReturn)
                if !accepted {
                    var cancelled = UserInputResponse.cancelled(for: request)
                    cancelled.checkboxstat = checkbox?.state == .on
                    cont.resume(returning: cancelled)
                    return
                }
                cont.resume(returning: UserInputResponse(
                    type: request.responsetype,
                    requestid: request.requestid,
                    text: textField?.stringValue,
                    confirm: request.responsetype == "confirm" ? true : nil,
                    checkboxstat: checkbox?.state == .on))
            }
            if request.timeoutms > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(request.timeoutms)) {
                    [weak window] in
                    guard !finished else { return }
                    window?.endSheet(alert.window, returnCode: .cancel)
                }
            }
        }
    }

    /// Best-effort plain text for a (possibly markdown) prompt body: NSAlert's
    /// informative text renders no markup, so parse inline markdown to characters,
    /// preserving line breaks; fall back to the raw text on parse failure.
    static func userInputPlainText(_ text: String, markdown: Bool) -> String {
        guard markdown else { return text }
        guard let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return text }
        return String(attributed.characters)
    }

    /// Close confirmation while applications are still running in the scope's shells
    /// (pane / tab / window close). "Cancel" gets Escape automatically by title;
    /// "Close" is the default (Return), matching Terminal.app.
    public func coordinatorConfirmClose(target: String, commands: [String]) async -> Bool {
        guard let window else { return true }
        let alert = NSAlert()
        alert.messageText = "Close \(target)?"
        let shown = commands.prefix(4).joined(separator: ", ")
        let suffix = commands.count > 4 ? ", …" : ""
        alert.informativeText = commands.count == 1
            ? "\(shown) is still running."
            : "Still running: \(shown)\(suffix)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { cont in
            alert.beginSheetModal(for: window) { resp in
                cont.resume(returning: resp == .alertFirstButtonReturn)
            }
        }
    }
}
