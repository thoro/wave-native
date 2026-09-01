// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — the multi-window owner (workspace-per-window). Replaces the single
// `windowController` the app delegate used to hold with N (coordinator, controller)
// pairs, each bound to its OWN backend `window:<id>` over its OWN transport/route.
//
// Topology (per the MultiWindow plan, option a): every NSWindow gets a fresh
// `WaveTransportClient` + `ObjectStore`. They SHARE one detached `wavesrv`: the
// first transport to grab the `WaveServerLock` spawns it and writes the descriptor;
// every later transport ATTACHES via the same descriptor (`attachToRunningServer`).
// So it is N websocket routes over one server — matching Electron, where each window
// has its own renderer route anchored on a backend `window:<id>`.
//
// Window↔workspace is 1:1 and stable: selecting/switching a workspace NAVIGATES to
// its window (focus the existing one, or open a new one bound to it) rather than
// repointing the current window. This mirrors Electron's
// `WaveBrowserWindow.switchWorkspace` "open/focus the workspace's own window".

import AppKit
import WaveCore
import WaveProtocol

@MainActor
public final class WindowManager {
    /// Builds a fresh transport + store for a new window. Each call MUST return an
    /// independent transport (distinct route) sharing the same `wavesrv` via the
    /// transport's spawn/attach path. Injected by the composition root (WaveApp).
    public typealias SessionFactory = () -> (WaveTransport, ObjectStoreProtocol)

    /// One open window: its coordinator/controller/transport and the backend
    /// window/workspace it is bound to (filled in once `coordinatorDidBind` fires).
    private final class Entry {
        let coordinator: AppCoordinator
        let controller: WaveWindowController
        let transport: WaveTransport
        var windowId: String?
        var workspaceId: String?

        init(coordinator: AppCoordinator, controller: WaveWindowController, transport: WaveTransport) {
            self.coordinator = coordinator
            self.controller = controller
            self.transport = transport
        }
    }

    private let makeSession: SessionFactory
    private let provider: BlockViewProvider
    private let config: AppLaunchConfig
    private weak var menuBar: MenuBarController?

    private var entries: [Entry] = []
    // Guards against double-opening while an async resolve/bind is in flight.
    private var openingWindowIds: Set<String> = []
    private var openingWorkspaceIds: Set<String> = []
    // windowId → last-known frame, loaded from the open-windows record on launch and
    // applied (best-effort) when each window binds. Updated live on move/resize.
    private var savedFrames: [String: WindowFrameRecord] = [:]
    // Coalesces frame writes during a drag/resize into one file write.
    private var framesWriteTimer: Timer?
    // Restore-on-launch fan-out runs once (from the primary bind), so a later bind
    // from focus-or-open can't resurrect a window the user has since closed.
    private var didRestoreWindows = false
    // During app termination we keep all backend windows so they restore next launch;
    // only a live, user-initiated single-window close removes its backend window.
    private var isTerminating = false

    init(
        makeSession: @escaping SessionFactory,
        provider: BlockViewProvider,
        config: AppLaunchConfig,
        menuBar: MenuBarController?
    ) {
        self.makeSession = makeSession
        self.provider = provider
        self.config = config
        self.menuBar = menuBar
    }

    // MARK: - Bootstrap

    /// Open the primary window (binds `client.windowids.first`). When it finishes
    /// binding it reports the full window list, and we open one NSWindow per remaining
    /// backend window (restore-on-launch).
    public func start() {
        if let dataHome = config.dataHome, let rec = OpenWindowsRecord.read(dataHome: dataHome) {
            savedFrames = rec.windowframes
            workspaceFocusStamps = rec.workspacefocus
        }
        openEntry(boundWindowId: nil)
    }

    /// Mark that the app is quitting, so per-window closes keep their backend windows
    /// (restore-on-launch) instead of deleting them.
    public func beginTermination() {
        isTerminating = true
    }

    /// Disconnect every window's transport (app teardown). The detached `wavesrv`
    /// survives — closing the websockets does not kill it.
    public func shutdown() {
        isTerminating = true
        framesWriteTimer?.invalidate()
        writeRecord()   // flush any pending frame change before teardown
        for entry in entries { entry.transport.disconnect() }
    }

    // MARK: - Navigation (workspace per window)

    /// Focus the window showing `workspaceId`, or open one for it. If the workspace
    /// already has a backend window (open in another NSWindow, or recorded by
    /// `ListWorkspaces`) we bind that; otherwise `CreateWindow` makes a fresh one.
    public func focusOrOpen(workspaceId: String) {
        if let entry = entries.first(where: { $0.workspaceId == workspaceId }) {
            focus(entry.controller)
            return
        }
        guard !openingWorkspaceIds.contains(workspaceId) else { return }
        guard let primary = entries.first?.coordinator else { return }
        openingWorkspaceIds.insert(workspaceId)
        Task { [weak self] in
            let windowId = await primary.resolveWindowId(forWorkspace: workspaceId)
            guard let self else { return }
            self.openingWorkspaceIds.remove(workspaceId)
            guard let windowId else { return }
            // A window appeared for it meanwhile (or it was already open): focus, don't dup.
            if let entry = self.entries.first(where: { $0.windowId == windowId || $0.workspaceId == workspaceId }) {
                self.focus(entry.controller)
                return
            }
            self.openEntry(boundWindowId: windowId, expectedWorkspaceId: workspaceId)
        }
    }

    /// Create a new workspace and open it in its own window (chrome "+ New workspace"
    /// / Workspace menu "Create Workspace"). Replaces the old in-place switch.
    /// `name` is the user-chosen name from the dropdown composer (empty = backend default).
    /// `initialCwd` seeds the workspace's default terminal; nil means $HOME. Seeding
    /// always happens BEFORE the window opens: the durable-shell path has no home
    /// fallback of its own, so an unseeded block would start the shell in the daemon's
    /// cwd ("/" in a production launch).
    public func createAndOpenWorkspace(named name: String = "", initialCwd: String? = nil) {
        guard let primary = entries.first?.coordinator else { return }
        let cwd = initialCwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        Task { [weak self] in
            guard let newId = await primary.createWorkspaceReturningId(named: name), !newId.isEmpty else { return }
            await primary.applyNewWorkspaceCwd(workspaceId: newId, cwd: cwd)
            self?.focusOrOpen(workspaceId: newId)
        }
    }

    /// Open a brand-new window (Cmd-N / menu / same-version second app launch, mirroring
    /// Electron's `second-instance` → `createNewWaveWindow`). A new window means a new
    /// workspace, so this is `createAndOpenWorkspace` — inheriting the key window's
    /// focused-pane cwd, like new tab / split do (second-launch has no key window → $HOME).
    public func openNewWindow() {
        let keyEntry = entries.first(where: { $0.controller.window?.isKeyWindow == true })
        createAndOpenWorkspace(initialCwd: keyEntry?.coordinator.focusedBlockCwd())
    }

    /// Active tab of the "current" window, for external launchers (KEYTAB op).
    /// Key window when the app is active; otherwise the frontmost visible window
    /// (the one that would become key on activation) — external callers invoke
    /// this from Terminal, where no Wave window is key.
    public func currentActiveTabId() -> String? {
        let entry = entries.first(where: { $0.controller.window?.isKeyWindow == true })
            ?? entries.first(where: { $0.controller.window?.isMainWindow == true })
            ?? entries.filter { $0.controller.window?.isVisible == true }
                .min(by: { ($0.controller.window?.orderedIndex ?? .max) < ($1.controller.window?.orderedIndex ?? .max) })
        return entry?.coordinator.activeTabId
    }

    /// Reopen a window when the app is running with none (closing the last window no longer
    /// quits the app). Binds the first kept backend window so its workspace + durable shells
    /// restore; if none remain it bootstraps a fresh one. No-op while a window is open.
    public func reopenIfNeeded() {
        guard entries.isEmpty else { return }
        openEntry(boundWindowId: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Focus the window owning `windowId`, switch it to `tabId`, and move focus to
    /// `blockId` — the desktop-notification click path (wired to
    /// `NotificationManager.onActivate`).
    public func focusWindowTabBlock(windowId: String, tabId: String, blockId: String) {
        guard let entry = entries.first(where: { $0.windowId == windowId }) else { return }
        focus(entry.controller)
        entry.coordinator.revealBlock(tabId: tabId, blockId: blockId)
    }

    /// Cross-workspace task-pill navigation: reveal `tabId` (+ optionally `blockId`)
    /// in whatever window shows `workspaceId`, opening one when none is. The
    /// open path binds asynchronously, so the reveal is parked and applied on bind.
    public func revealWorkspaceTabBlock(workspaceId: String, tabId: String, blockId: String?) {
        if let entry = entries.first(where: { $0.workspaceId == workspaceId }) {
            focus(entry.controller)
            reveal(in: entry.coordinator, tabId: tabId, blockId: blockId)
            return
        }
        pendingReveal = (workspaceId, tabId, blockId)
        focusOrOpen(workspaceId: workspaceId)
    }

    /// Reveal parked by `revealWorkspaceTabBlock` while its workspace's window was
    /// still opening; consumed by the matching bind.
    private var pendingReveal: (workspaceId: String, tabId: String, blockId: String?)?

    /// Deep-link entry (`wave-native://<otype>/<oid>`, delivered via the app
    /// delegate's open-URLs): resolve the target's location through a bound
    /// window's coordinator, then reveal it.
    public func openDeepLink(_ url: URL) {
        guard let link = DeepLink.parse(url) else { return }
        openDeepLink(link)
    }

    /// A link arriving before any window has bound (launch-by-URL) is parked and
    /// replayed on the first bind — the resolve needs a connected transport.
    func openDeepLink(_ link: DeepLink) {
        guard let primary = entries.first(where: { $0.workspaceId != nil })?.coordinator else {
            pendingDeepLink = link
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        Task { [weak self] in
            guard let loc = await primary.resolveDeepLink(link), let self else { return }
            if let tabId = loc.tabId {
                self.revealWorkspaceTabBlock(
                    workspaceId: loc.workspaceId, tabId: tabId, blockId: loc.blockId)
            } else {
                self.focusOrOpen(workspaceId: loc.workspaceId)
            }
        }
    }

    /// Deep link parked by `openDeepLink` while no window had bound; consumed by
    /// the first bind (last one wins when several arrive during launch).
    private var pendingDeepLink: DeepLink?

    // MARK: - Workspace focus recency

    /// workspaceId → last-focus epoch seconds; persisted in the open-windows
    /// record so the switcher's most-recently-focused order survives a relaunch.
    private var workspaceFocusStamps: [String: Double] = [:]

    /// Snapshot for the switcher surfaces (dropdown + Cmd-Shift-O), read at open time.
    var workspaceRecency: [String: Double] { workspaceFocusStamps }

    /// A window came to the front — stamp its workspace as most recently focused.
    /// Driven by main-window changes (not key: a tab drag bounces KEY to the drag
    /// flotilla for a few ms, which would churn stamps; main stays put).
    func noteWorkspaceFocused(_ controller: WaveWindowController) {
        guard let entry = entries.first(where: { $0.controller === controller }),
              let wsId = entry.workspaceId else { return }
        workspaceFocusStamps[wsId] = Date().timeIntervalSince1970
        scheduleRecordWrite()
    }

    /// Coalesce record writes (shared with the frame-change path) so focus churn
    /// or a drag/resize is one file write.
    private func scheduleRecordWrite() {
        framesWriteTimer?.invalidate()
        framesWriteTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.writeRecord() }
        }
    }

    private func reveal(in coordinator: AppCoordinator, tabId: String, blockId: String?) {
        if let blockId {
            coordinator.revealBlock(tabId: tabId, blockId: blockId)
        } else {
            coordinator.selectTab(tabId)
        }
    }

    /// Workspaces currently shown in a live NSWindow. This is the authoritative "is
    /// open" signal for the switcher: a backend `window:<id>` row lingers after its
    /// NSWindow closes (kept for restore, e.g. closing the last window), so
    /// `WorkspaceListEntry.windowid` would keep marking a closed workspace as open.
    var openWorkspaceIds: Set<String> {
        Set(entries.compactMap { $0.workspaceId })
    }

    // MARK: - Entry lifecycle

    @discardableResult
    private func openEntry(boundWindowId: String?, expectedWorkspaceId: String? = nil) -> Entry {
        let (transport, store) = makeSession()
        let coordinator = AppCoordinator(transport: transport, store: store, config: config)
        coordinator.boundWindowId = boundWindowId
        // Route this window's bell/OSC desktop notifications to the shared OS-level
        // manager (it gates on `notification:enabled` + handles the click).
        coordinator.onDesktopNotification = { request in
            NotificationManager.shared.post(request)
        }
        let controller = WaveWindowController(coordinator: coordinator, provider: provider)
        controller.menuBar = menuBar
        controller.windowManager = self

        let entry = Entry(coordinator: coordinator, controller: controller, transport: transport)
        // Record the bound window id up front so concurrent opens see it as taken.
        entry.windowId = boundWindowId
        entry.workspaceId = expectedWorkspaceId
        if let boundWindowId { openingWindowIds.insert(boundWindowId) }
        entries.append(entry)

        controller.onDidBind = { [weak self, weak entry] windowId, workspaceId, allWindowIds in
            self?.handleBind(entry, windowId: windowId, workspaceId: workspaceId, allWindowIds: allWindowIds)
        }
        controller.onWindowClosed = { [weak self, weak entry] in
            self?.handleClosed(entry)
        }

        cascade(controller.window, index: entries.count - 1)
        controller.startApp()
        return entry
    }

    private func handleBind(_ entry: Entry?, windowId: String, workspaceId: String, allWindowIds: [String]) {
        guard let entry else { return }
        entry.windowId = windowId
        entry.workspaceId = workspaceId
        openingWindowIds.remove(windowId)
        applySavedFrame(to: entry)
        persistOpenWorkspaces()
        // The frontmost window went main BEFORE its workspace was known (bind is
        // async), so its recency stamp couldn't land then — stamp it now.
        if entry.controller.window?.isMainWindow == true {
            noteWorkspaceFocused(entry.controller)
        }

        if let reveal = pendingReveal, reveal.workspaceId == workspaceId {
            pendingReveal = nil
            let coordinator = entry.coordinator
            // Deferred one turn so the freshly bound window finishes publishing its
            // initial tab before the reveal switches/focuses.
            DispatchQueue.main.async { [weak self] in
                self?.reveal(in: coordinator, tabId: reveal.tabId, blockId: reveal.blockId)
            }
        }

        if let link = pendingDeepLink {
            pendingDeepLink = nil
            DispatchQueue.main.async { [weak self] in self?.openDeepLink(link) }
        }

        // Restore-on-launch: open one NSWindow per other backend window — ONCE, from
        // the primary bind. Doing it on every bind would re-open windows the user has
        // since closed (their backend ids linger until CloseWindow removes them).
        guard !didRestoreWindows else { return }
        didRestoreWindows = true
        for wid in allWindowIds where wid != windowId {
            guard !isWindowOpen(wid), !openingWindowIds.contains(wid) else { continue }
            openEntry(boundWindowId: wid)
        }
    }

    private func handleClosed(_ entry: Entry?) {
        guard let entry else { return }
        entries.removeAll { $0 === entry }
        persistOpenWorkspaces()
        // Delete the backend window only on a live, user-initiated close of a window
        // that is NOT the last one. During termination (isTerminating) or when this is
        // the final window, we keep it so the workspace restores on next launch.
        guard !isTerminating, !entries.isEmpty else {
            entry.transport.disconnect()
            return
        }
        let coordinator = entry.coordinator
        let transport = entry.transport
        Task {
            await coordinator.closeBackendWindow()
            transport.disconnect()
        }
    }

    // MARK: - Helpers

    private func isWindowOpen(_ windowId: String) -> Bool {
        entries.contains { $0.windowId == windowId }
    }

    /// Persist the set of workspaces currently shown in open windows. Best-effort
    /// mirror of the live state; the authoritative restore source on the next launch
    /// is the backend `client.windowids` (sqlite rows that survive a wavesrv restart),
    /// so this file is for diagnostics + a fallback hint, not the primary restore path.
    private func persistOpenWorkspaces() {
        writeRecord()
    }

    /// Write the open-windows record (workspace ids + saved frames) immediately.
    private func writeRecord() {
        guard let dataHome = config.dataHome else { return }
        let ids = entries.compactMap { $0.workspaceId }
        OpenWindowsRecord.write(
            OpenWindowsRecord(workspaceids: ids, windowframes: savedFrames,
                              workspacefocus: workspaceFocusStamps),
            dataHome: dataHome)
    }

    /// A window moved or resized — record its frame against its backend window id (best
    /// effort; ignored until the window has bound). Coalesced so a drag/resize is one write.
    func windowFrameDidChange(_ controller: WaveWindowController) {
        guard let entry = entries.first(where: { $0.controller === controller }) else { return }
        // Key by workspaceId, not windowId: the workspace is the stable, user-meaningful
        // identity of "the window showing X", and it is exactly what the restore fan-out
        // binds each window to. (windowIds survive a restart too, but keying on the
        // workspace keeps the frame attached to the content the user recognizes.)
        guard let key = entry.workspaceId, let frame = controller.window?.frame else { return }
        savedFrames[key] = WindowFrameRecord(
            x: Double(frame.minX), y: Double(frame.minY),
            w: Double(frame.width), h: Double(frame.height))
        scheduleRecordWrite()
    }

    /// Restore a bound window's saved frame, clamped onto a visible screen (best effort).
    private func applySavedFrame(to entry: Entry) {
        guard let key = entry.workspaceId, let window = entry.controller.window else { return }
        guard let saved = savedFrames[key] else { return }
        let rect = CGRect(x: saved.x, y: saved.y, width: saved.w, height: saved.h)
        window.setFrame(Self.clampToScreen(rect), display: true)
    }

    /// Keep a restored frame usable when displays changed: if it no longer intersects any
    /// screen, re-center it on the main screen (keeping its size).
    private static func clampToScreen(_ rect: CGRect) -> CGRect {
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) { return rect }
        guard let main = NSScreen.main?.visibleFrame else { return rect }
        return CGRect(
            x: main.midX - rect.width / 2, y: main.midY - rect.height / 2,
            width: rect.width, height: rect.height)
    }

    private func focus(_ controller: WaveWindowController) {
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Offset secondary windows so they don't stack exactly on the centered first one.
    private func cascade(_ window: NSWindow?, index: Int) {
        guard let window, index > 0 else { return }
        let delta = CGFloat(24 * index)
        var origin = window.frame.origin
        origin.x += delta
        origin.y -= delta
        window.setFrameOrigin(origin)
    }
}
