// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — the app shell view-model. Drives the PROTOCOL.md §7 init sequence and
// the window/tab/workspace operations, holding the current
// client -> window -> workspace -> tab -> layout chain.
//
// GUARDS enforced here:
//   §P  fresh random WAVETERM_AUTH_KEY per launch; robust ESTART (delegated to
//       transport.spawn).
//   §A  connect announces the route + the transport re-subscribes on reconnect;
//       this coordinator (re)issues the §7 event subscriptions.
//   §B  the `waveobj:update` event is decoded and fed into store.applyUpdates;
//       every service mutation applies its inline updates (via ServiceClient).
//   §C  SetActiveTab is called on EVERY tab activation (the backend trigger that
//       starts the tab's block controllers); CloseTab's return is honored.
//
// The coordinator is @MainActor (it owns UI-facing state); transport/store calls
// are async and hop back to the main actor.

import AppKit
import WaveCore
import WaveLayout

/// UI-facing callbacks. All delivered on the main actor.
@MainActor
public protocol AppCoordinatorDelegate: AnyObject {
    func coordinatorDidUpdateWorkspace(name: String?, icon: String?, color: String?, workspaceId: String?)
    func coordinatorDidUpdateWorkspaceList(_ items: [WorkspaceMenuItem])
    /// The selectable workspace color/icon palettes (`GetColors`/`GetIcons`), fetched
    /// once at bootstrap. Drives the switcher's inline editor grids.
    func coordinatorDidUpdateWorkspacePalette(colors: [String], icons: [String])
    func coordinatorDidUpdateTabs(_ tabs: [TabBarItem], activeTabId: String?)
    /// The tab-bar position (`app:tabbar`: "top"|"left") from the live config. Pushed on
    /// bind (after fullConfig loads) and on every config reload, so changing it in
    /// Settings re-orients the chrome without a restart.
    func coordinatorDidUpdateTabBarPosition(_ position: String)
    /// The active tab's background (`bg*` meta, or a named `tab:background` preset),
    /// resolved to a CSS background string + opacity/blendmode. nil clears it (default
    /// window background). Pushed on tab activate and on the active tab's meta change, so
    /// switching tabs swaps the background like Electron's per-tab app background.
    func coordinatorDidUpdateTabBackground(_ config: TabBackgroundConfig?)
    /// The config-defined background presets (`backgrounds` map), ordered by `display:order`.
    /// Drives the tab pill's "Background" submenu. Pushed on bind and on each config reload.
    func coordinatorDidUpdateBackgroundPresets(_ presets: [TabBackgroundPreset])
    func coordinatorDidUpdateLayout(env: BlockEnvFactory, root: LayoutNode?, focusedNodeId: String?, magnifiedNodeId: String?)
    /// Move keyboard focus to a specific block once it mounts (focus-follows-split:
    /// the new pane is identified by block id, since the backend's `focusednodeid`
    /// after a split does not reliably point at the new node).
    func coordinatorRequestFocusBlock(_ blockId: String)
    /// The coordinator finished binding its backend `window:<id>` and resolved the
    /// workspace it shows. `allWindowIds` is the client's full window list at bootstrap,
    /// so the WindowManager can fan out one NSWindow per remaining backend window
    /// (restore-on-launch, mirrors Electron `relaunchBrowserWindows`).
    func coordinatorDidBind(windowId: String, workspaceId: String, allWindowIds: [String])
    func coordinatorDidBecomeReady()
    func coordinatorRequestCloseWindow()
    func coordinatorDidFail(_ error: Error)
    /// Present the connection typeahead for `blockId`. `connections` is the live
    /// `connlist`; `current` is the block's current connection (nil/local). The
    /// presenter calls `onSelect` with the picked connection name (or "local").
    func coordinatorPresentConnectionPicker(
        blockId: String, current: String?, connections: [String], onSelect: @escaping (String) -> Void)
    /// A block is about to be deleted: a chance to release external resources it held
    /// (e.g. a web block's persistent WKWebsiteDataStore). The delegate routes this to
    /// the content provider, which owns the WaveWeb-side cleanup.
    func coordinatorWillDeleteBlock(_ block: Block)
    /// Whether this coordinator's NSWindow is currently the key window. Drives the
    /// bell/notification suppression rule (a bell on the visible+key+frontmost pane is
    /// not surfaced as a desktop notification).
    func coordinatorIsWindowKey() -> Bool
    /// The last working directory `blockId`'s terminal reported (OSC 7), or nil. The
    /// delegate routes this to the content provider (which owns the per-block cwd cache),
    /// so a split can start the new pane in the source pane's directory without WaveUI
    /// importing WaveTerminal.
    func coordinatorCwdForBlock(_ blockId: String) -> String?
    /// Ask the user to confirm a destructive close while applications are still
    /// running in the scope's shells. `target` is the thing being closed ("Pane",
    /// "Tab", "Window"); `commands` are the running process names. Returns true to
    /// proceed with the close.
    func coordinatorConfirmClose(target: String, commands: [String]) async -> Bool
    /// The set of workspace ids currently shown in a live NSWindow (the WindowManager's
    /// open windows). Used to badge the switcher's rows: a backend `window:<id>` row
    /// lingers after its NSWindow closes (kept for restore), so `WorkspaceListEntry.windowid`
    /// alone would mark a closed workspace as still open.
    func coordinatorOpenWorkspaceIds() -> Set<String>
    /// Present a backend `userinput` prompt (SSH password / key passphrase /
    /// keyboard-interactive / unknown host key / wsh install consent) and return the
    /// user's answer. The coordinator sends the response back over the service API.
    func coordinatorPresentUserInput(_ request: UserInputRequest) async -> UserInputResponse
}

/// Default empty bind hook so existing single-window delegates (and tests) need not
/// implement it; only the WindowManager-backed controller overrides it.
public extension AppCoordinatorDelegate {
    /// Default no-op so delegates without the inline editor (and tests) compile.
    func coordinatorDidUpdateWorkspacePalette(colors: [String], icons: [String]) {}
    /// Default no-op so delegates without a positioned tab bar (and tests) compile.
    func coordinatorDidUpdateTabBarPosition(_ position: String) {}
    /// Default no-op so delegates without a tab-background view (and tests) compile.
    func coordinatorDidUpdateTabBackground(_ config: TabBackgroundConfig?) {}
    /// Default no-op so delegates without a tab "Background" submenu (and tests) compile.
    func coordinatorDidUpdateBackgroundPresets(_ presets: [TabBackgroundPreset]) {}
    func coordinatorDidBind(windowId: String, workspaceId: String, allWindowIds: [String]) {}
    /// Default no-op so delegates without connection-picker UI (and tests) compile.
    func coordinatorPresentConnectionPicker(
        blockId: String, current: String?, connections: [String], onSelect: @escaping (String) -> Void) {}
    /// Default no-op so delegates without a content provider (and tests) compile.
    func coordinatorWillDeleteBlock(_ block: Block) {}
    /// Default false so delegates without a live NSWindow (and tests) treat the window
    /// as not-key — i.e. a bell always surfaces a notification in headless contexts.
    func coordinatorIsWindowKey() -> Bool { false }
    /// Default nil so delegates without a content provider (and tests) report no cwd —
    /// a split then opens at the backend default directory (today's behaviour).
    func coordinatorCwdForBlock(_ blockId: String) -> String? { nil }
    /// Default true so delegates without confirmation UI (and tests) close without
    /// asking — matching the pre-confirmation behaviour.
    func coordinatorConfirmClose(target: String, commands: [String]) async -> Bool { true }
    /// Default empty so delegates without a WindowManager (and tests) report nothing
    /// open — every listed workspace then renders as closed.
    func coordinatorOpenWorkspaceIds() -> Set<String> { [] }
    /// Default decline so delegates without dialog UI (and tests) unblock the backend
    /// immediately instead of letting the prompt sit until its timeout.
    func coordinatorPresentUserInput(_ request: UserInputRequest) async -> UserInputResponse {
        .cancelled(for: request)
    }
}

/// Spawn/launch configuration (GUARDS §P).
public struct AppLaunchConfig: Sendable {
    /// Path to the `wavesrv` binary (passed through to the transport via env or
    /// the transport's own resolution). Optional — the transport may resolve it.
    public var dataHome: String?
    public var configHome: String?
    /// Native-app version recorded in the running-server descriptor (single-instance
    /// upgrade gate). Defaults to the build constant; the composition root injects the
    /// `WAVE_NATIVE_VERSION` override.
    public var nativeVersion: String
    /// Extra environment to merge into the spawn env.
    public var extraEnv: [String: String]

    public init(
        dataHome: String? = nil, configHome: String? = nil,
        nativeVersion: String = WaveProtocolConst.defaultNativeVersion,
        extraEnv: [String: String] = [:]
    ) {
        self.dataHome = dataHome
        self.configHome = configHome
        self.nativeVersion = nativeVersion
        self.extraEnv = extraEnv
    }
}

/// One launcher button in the right-edge widget bar, parsed from a `widgets`
/// config entry (`pkg/wconfig/settingsconfig.go` `WidgetConfigType`). `blockDefMeta`
/// is the block `meta` the button creates (the canonical widget BlockDef).
public struct WidgetItem: Sendable, Equatable {
    public let icon: String?
    public let label: String?
    public let color: String?
    public let blockDefMeta: MetaMapType
    public let order: Double
    public let hidden: Bool
    public let magnified: Bool
    public init(icon: String?, label: String?, color: String?, blockDefMeta: MetaMapType,
                order: Double, hidden: Bool, magnified: Bool) {
        self.icon = icon
        self.label = label
        self.color = color
        self.blockDefMeta = blockDefMeta
        self.order = order
        self.hidden = hidden
        self.magnified = magnified
    }
}

@MainActor
public final class AppCoordinator {
    private let transport: WaveTransport
    private let store: ObjectStoreProtocol
    private let service: ServiceClient
    private let config: AppLaunchConfig

    public weak var delegate: AppCoordinatorDelegate?

    /// The backend `window:<id>` this coordinator must bind. `nil` = the primary
    /// bootstrap case (pick `client.windowids.first`). The WindowManager sets this to
    /// a specific window when opening additional NSWindows (one workspace per window).
    public var boundWindowId: String?

    // Current object chain.
    private(set) var clientId: String?
    private(set) var windowId: String?
    private(set) var workspaceId: String?
    private(set) var activeTabId: String?

    private var fullConfig: JSONValue?

    /// Cached workspace color/icon palettes (`GetColors`/`GetIcons`). Static backend
    /// data — fetched once at bootstrap.
    private var workspaceColors: [String] = []
    private var workspaceIcons: [String] = []

    /// Live connection-status cache (seeded by `connstatus`, kept current by the
    /// `connchange` event). Threaded into every block's `BlockEnv` so headers can
    /// colour their connection icon and show the connect overlay.
    let connectionStore = ConnectionStore()

    // Live subscriptions.
    private var eventTokens: [SubscriptionToken] = []
    private var workspaceToken: SubscriptionToken?
    // Per-tab store subscriptions (keyed by tab id). A tab's name / `tab:flagcolor`
    // change does NOT mutate the workspace object, so without these the strip never
    // re-renders after a rename or flag toggle (the change only lands in the store).
    private var tabTokens: [String: SubscriptionToken] = [:]
    private var layoutModel: LayoutModel?
    private var subscribedLayoutRef: ORef?

    /// Tabs with an unseen bell/notification (badge on the pill). Set when a background
    /// tab rings; cleared when that tab is activated. Drives `TabBarItem.hasUnread`.
    private var unreadTabs: Set<String> = []
    /// Remote connections already `connensure`d this session, so tab switches don't
    /// re-ensure (and thereby re-dial) a connection on every activation.
    private var ensuredConns: Set<String> = []

    /// Sink for desktop notifications, wired by the composition root (WindowManager) to
    /// `NotificationManager`. Left nil in tests, so the badge path can be exercised
    /// without touching UNUserNotificationCenter.
    public var onDesktopNotification: ((DesktopNotificationRequest) -> Void)?

    public init(transport: WaveTransport, store: ObjectStoreProtocol, config: AppLaunchConfig = AppLaunchConfig()) {
        self.transport = transport
        self.store = store
        self.service = ServiceClient(transport: transport, store: store)
        self.config = config
    }

    deinit {
        // Tokens auto-cancel on deinit, but be explicit.
        eventTokens.forEach { $0.cancel() }
        workspaceToken?.cancel()
        tabTokens.values.forEach { $0.cancel() }
        layoutModel?.stop()
    }

    // MARK: - PROTOCOL §7 init sequence

    public func start() {
        Task { await self.runStart() }
    }

    private func runStart() async {
        do {
            // §7.1 — spawn wavesrv with a fresh random auth key (GUARDS §P).
            var env = config.extraEnv
            env[WaveProtocolConst.authKeyEnv] = Self.generateAuthKey()
            if let dh = config.dataHome { env[WaveProtocolConst.dataHomeEnv] = dh }
            if let ch = config.configHome { env[WaveProtocolConst.configHomeEnv] = ch }
            // Stamp the native-app version so the spawned wavesrv's descriptor records
            // which app version owns it (the next launch's upgrade gate reads it back).
            env[WaveProtocolConst.nativeVersionEnv] = config.nativeVersion
            // No-TCP mode: wavesrv serves web+ws on unix domain sockets in the
            // data dir, so it occupies no port and is unreachable over the network.
            env[WaveProtocolConst.webUnixSocketEnv] = "1"
            _ = try await transport.spawn(env: env)

            // §7.2 — GetClientData (HTTP) -> clientId, windowids.
            let client = try await service.getClientData()
            store.merge(.client(client))
            clientId = client.oid
            // The WindowManager pins a specific backend window per NSWindow (workspace
            // per window); only the primary bootstrap falls back to the first window.
            var allWindowIds = client.windowids
            let windowId: String
            if let existing = boundWindowId ?? allWindowIds.first {
                windowId = existing
            } else {
                // First-run / all-windows-closed: the client has no windows. Bootstrap the
                // initial one — an empty workspaceId makes the backend also create a fresh
                // workspace + tab (wcore.CreateWindow).
                guard let bootstrapped = try await service.createWindow(workspaceId: "") else {
                    throw WaveError.rpc("first-run window bootstrap failed (CreateWindow returned nil)")
                }
                store.merge(.window(bootstrapped))
                windowId = bootstrapped.oid
                allWindowIds = [bootstrapped.oid]
                // wcore.CreateWindow("") creates the workspace EPHEMERAL (empty name) and we
                // leave it that way: an unnamed workspace is scratch (hidden from the switcher,
                // GC'd when its window closes) until the user explicitly saves it. Auto-naming
                // it here would make every default/new-window workspace permanent.
            }
            self.windowId = windowId

            // §7.3/§7.4 — open WS (?stableid=window:<id>), ping/pong + routeannounce
            // are performed by the transport per its contract (GUARDS §A).
            try await transport.connect(routeId: WaveRoute.window(windowId))

            // §7.5 — subscribe the standard event set.
            subscribeStandardEvents()

            // §7.6 — load client -> window -> workspace -> tab -> layout.
            let window = try await loadWindow(windowId)
            let wsId = window.workspaceid
            workspaceId = wsId
            let workspace = try await loadWorkspace(wsId)

            // §7.8 — scope waveobj:update to the workspace oref (GUARDS §B: scope
            // is the oref STRING).
            subscribeWorkspaceEvents(workspaceId: wsId)
            subscribeWorkspaceObject(workspaceId: wsId)

            // sibling tabs (so the strip can render names immediately).
            _ = try? await store.loadMany(workspace.tabids.map { ORef.tab($0) })
            subscribeTabs(workspace.tabids)

            let activeTab = workspace.activetabid
            activeTabId = activeTab.isEmpty ? workspace.tabids.first : activeTab

            // §7.7 — full config (theme/settings).
            await loadFullConfig()
            await seedConnections()

            // §7.9 — ready. Push initial UI and activate the current tab (the
            // backend controller-start trigger, GUARDS §C).
            publishWorkspace()
            publishTabs()
            publishTabBarPosition()
            publishBackgroundPresets()
            // Force telemetry off (no UI toggle) and seed every config-driven view
            // (window appearance, terminal font/transparency, web search/homepage) before
            // the tab's blocks mount, by posting the same reload notification a `config`
            // event would. enforceTelemetryDisabled is idempotent — it only writes when
            // the value is not already false, so it cannot loop through that event.
            enforceTelemetryDisabled()
            notifyConfigReloaded()
            await loadWorkspacePalette()
            await refreshWorkspaceList()
            // Tell the WindowManager which backend window/workspace this NSWindow now
            // owns, and hand it the full window list so it can open the rest.
            delegate?.coordinatorDidBind(windowId: windowId, workspaceId: wsId, allWindowIds: allWindowIds)
            if let activeTabId {
                await activate(tabId: activeTabId, isInitial: true)
            }
            delegate?.coordinatorDidBecomeReady()
        } catch {
            delegate?.coordinatorDidFail(error)
        }
    }

    // MARK: - Event subscriptions (§7.5 / §7.8)

    private func subscribeStandardEvents() {
        let names = [
            WaveEventName.waveObjUpdate,
            // workspace:update has no payload; it fires whenever the set of workspaces
            // changes (e.g. another window's CreateWorkspace). Every window's coordinator
            // subscribes (allscopes) so ALL open switchers refresh, not just the creator's
            // (mirrors Electron rebuilding the menu on workspace:update).
            WaveEventName.workspaceUpdate,
            WaveEventName.config,
            WaveEventName.connChange,
            WaveEventName.blockFile,
            WaveEventName.userInput,
        ]
        for name in names {
            let token = transport.subscribe(SubscriptionRequest(event: name, allscopes: true)) { [weak self] event in
                guard let self else { return }
                Task { @MainActor in self.handleEvent(event) }
            }
            eventTokens.append(token)
        }
    }

    private func subscribeWorkspaceEvents(workspaceId: String) {
        // GUARDS §B: scope is the oref string.
        let token = transport.subscribe(
            SubscriptionRequest(event: WaveEventName.waveObjUpdate, scopes: [ORef.workspace(workspaceId).string])
        ) { [weak self] event in
            guard let self else { return }
            Task { @MainActor in self.handleEvent(event) }
        }
        eventTokens.append(token)
    }

    private func handleEvent(_ event: WaveEvent) {
        // workspace:update carries no payload — re-pull the authoritative workspace
        // list so this window's switcher / Cmd-Shift-O overlay reflects workspaces
        // created or removed in OTHER windows.
        if event.event == WaveEventName.workspaceUpdate {
            Task { [weak self] in await self?.refreshWorkspaceList() }
            return
        }
        // config carries no usable payload here — the authoritative full config must be
        // re-pulled. Reloading keeps every config consumer (widget bar, local-host name,
        // an open Settings window) in sync after a `setconfig` from this or another
        // window. The notification lets the shared Settings window refresh its controls.
        if event.event == WaveEventName.config {
            Task { [weak self] in
                guard let self else { return }
                await self.loadFullConfig()
                self.notifyConfigReloaded()
                self.publishTabBarPosition()
                self.publishBackgroundPresets()
            }
            return
        }
        // connchange carries a single ConnStatus (`pkg/wps/wpstypes.go:19`): upsert it
        // so block headers re-tint and the connect overlay reflects the new state.
        if event.event == WaveEventName.connChange {
            if let status = try? event.data?.decode(ConnStatus.self) {
                connectionStore.upsert(status)
            }
            return
        }
        // userinput: an SSH-connect prompt (password / passphrase / keyboard-interactive
        // / unknown host key / wsh install consent). Scoped to the OWNING window's bare
        // oid (or all windows on fallback); every coordinator subscribes allscopes, so
        // filter here or every window would pop the same dialog.
        if event.event == WaveEventName.userInput {
            handleUserInputEvent(event)
            return
        }
        guard event.event == WaveEventName.waveObjUpdate, let data = event.data else { return }
        // The payload is either a single WaveObjUpdate or an array of them.
        if let single = try? data.decode(WaveObjUpdate.self) {
            store.applyUpdates([single])
        } else if let many = try? data.decode([WaveObjUpdate].self) {
            store.applyUpdates(many)
        }
        // blockfile: consumed by each terminal content view via its own block-scoped
        // subscription (PROTOCOL §4); config is handled above (re-pull + notify).
    }

    /// Route a backend user-input prompt to the delegate's dialog and send the answer
    /// back through the `userinput` service. The backend matches purely by requestid
    /// (channel cap 1), so a late answer after its timeout is dropped harmlessly.
    private func handleUserInputEvent(_ event: WaveEvent) {
        guard let windowId, event.hasScope(windowId),
              let request = try? event.data?.decode(UserInputRequest.self) else { return }
        Task { [weak self] in
            guard let self else { return }
            let response = await self.delegate?.coordinatorPresentUserInput(request)
                ?? .cancelled(for: request)
            do {
                try await self.service.sendUserInputResponse(response)
            } catch {
                NSLog("AppCoordinator: sendUserInputResponse failed: \(error)")
            }
        }
    }

    // MARK: - Store object subscriptions

    private func subscribeWorkspaceObject(workspaceId: String) {
        workspaceToken?.cancel()
        workspaceToken = store.subscribe(ORef.workspace(workspaceId)) { [weak self] obj in
            guard let self else { return }
            Task { @MainActor in self.workspaceChanged(obj?.asWorkspace) }
        }
    }

    /// Subscribe to each of the workspace's tab objects so a tab's own meta changes
    /// (name via `updatetabname`, `tab:flagcolor` via `setmeta`) re-publish the strip
    /// immediately. Tokens for tabs that left the workspace are dropped.
    private func subscribeTabs(_ tabIds: [String]) {
        for (id, token) in tabTokens where !tabIds.contains(id) {
            token.cancel()
            tabTokens.removeValue(forKey: id)
        }
        for id in tabIds where tabTokens[id] == nil {
            tabTokens[id] = store.subscribe(ORef.tab(id)) { [weak self] _ in
                Task { @MainActor in self?.publishTabs() }
            }
        }
    }

    private func workspaceChanged(_ workspace: Workspace?) {
        guard let workspace else { return }
        // Keep active tab in sync with the authoritative server value.
        if !workspace.activetabid.isEmpty {
            activeTabId = workspace.activetabid
        }
        publishWorkspace()
        publishTabs()
        subscribeTabs(workspace.tabids)
        // Ensure newly added sibling tabs get loaded so names render.
        let missing = workspace.tabids.filter { store.get(ORef.tab($0)) == nil }
        if !missing.isEmpty {
            let store = self.store
            let refs = missing.map { ORef.tab($0) }
            Task { [weak self] in
                _ = try? await store.loadMany(refs)
                await MainActor.run { self?.publishTabs() }
            }
        }
        // Re-subscribe the active tab's layout if it changed. A tab that just MOVED INTO
        // this workspace (cross-window drag) is usually NOT in the store cache yet — load
        // it first, or the content area keeps showing the previous tab while activeTabId
        // already points at the moved one (Cmd-D then queues a split whose target block
        // lives in another tab's layout, which is silently dropped).
        guard let activeTabId else { return }
        if let tab = store.get(ORef.tab(activeTabId))?.asTab, let layoutRef = tab.layoutStateORef {
            subscribeLayout(layoutRef)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let tab = await self.loadTabSafe(activeTabId)
            await MainActor.run {
                guard self.activeTabId == activeTabId,
                      let layoutRef = tab?.layoutStateORef else { return }
                self.subscribeLayout(layoutRef)
            }
        }
    }

    private func subscribeLayout(_ layoutRef: ORef) {
        if subscribedLayoutRef == layoutRef { return }
        subscribedLayoutRef = layoutRef
        layoutModel?.stop()
        guard let windowId, let activeTabId else { return }

        // GUARDS §L: a tab's tiling tree lives in a SEPARATE LayoutState object and
        // is built by applying its `pendingbackendactions` (e.g. the starter
        // layout's `clear`+`insertatindex`, or a `wsh`-created block) and persisting
        // the result with the queue cleared. `LayoutModel` owns that protocol.
        let model = LayoutModel(
            layoutORef: layoutRef, transport: transport, store: store,
            windowId: windowId, tabId: activeTabId)
        model.onTreeChanged = { [weak self] in
            Task { @MainActor in self?.publishLayoutFromModel() }
        }
        // Supplies the owning tab's blockids so the model can self-heal a wiped layout
        // (block still owned by the tab but absent from the tree → empty pane).
        let providerTabId = activeTabId
        model.tabBlockIdsProvider = { [weak self] in
            self?.store.get(ORef.tab(providerTabId))?.asTab?.blockids ?? []
        }
        layoutModel = model
        Task { [weak self] in
            try? await model.start()
            await MainActor.run { self?.publishLayoutFromModel() }
        }
    }

    // MARK: - Tab operations

    /// Switch to a tab (user action). GUARDS §C: SetActiveTab is the trigger that
    /// starts the tab's block controllers — always call it.
    public func selectTab(_ tabId: String) {
        guard tabId != activeTabId else { return }
        Task { await self.activate(tabId: tabId, isInitial: false) }
    }

    private func activate(tabId: String, isInitial: Bool) async {
        guard let workspaceId else { return }
        activeTabId = tabId
        // Becoming active clears any bell/notification badge on this tab (the user is
        // now looking at it).
        unreadTabs.remove(tabId)
        // Optimistically reflect the selection.
        publishTabs()

        // Load the tab + its layout, then mount tiles.
        let tab = await loadTabSafe(tabId)
        if let layoutRef = tab?.layoutStateORef {
            subscribeLayout(layoutRef)
        }
        ensureTabConnections(tab)

        // A first-run starter tab has NO blocks (the backend seeds the starter layout
        // only after Electron's onboarding modal). Electron gives a fresh/initial tab a
        // default terminal; do the same so the tab is immediately live with ONE terminal
        // — instead of an empty pane (and without opening a redundant second tab). Gate
        // strictly on an empty block list so a restored tab is never double-seeded. On the
        // INITIAL activation also cover the case where the tab never loaded at all (a
        // restore that exhausted loadTabSafe's retries): seed a terminal so the window is
        // usable rather than dead — a non-initial switch keeps the no-op (no false seed).
        if tab?.blockids.isEmpty == true || (isInitial && tab == nil) {
            createTermBlock(inheritFromBlockId: nil, targetBlockId: nil, targetAction: nil)
        }

        // GUARDS §C — the controller-start trigger.
        do {
            try await service.setActiveTab(workspaceId: workspaceId, tabId: tabId)
        } catch {
            // A single dead/orphaned block must not brick the whole bootstrap. During
            // the INITIAL activation a SetActiveTab failure is treated as non-fatal —
            // log and keep going so the window still comes up (the backend GC sweeps the
            // orphan, and a stale layout leaf is pruned below). A user-driven switch
            // keeps the hard-fail so an interactive error is still surfaced.
            if isInitial {
                NSLog("AppCoordinator: initial setActiveTab failed (continuing, treating as recoverable): \(error)")
            } else {
                delegate?.coordinatorDidFail(error)
            }
        }
    }

    /// Auto-(re)connect the remote connections referenced by a tab's blocks. Nothing
    /// else connects them after an app restart (`seedConnections` only reads status),
    /// so without this a restored remote pane's controller can never start and its
    /// durable job is never reattached — the pane sits black on the connect overlay
    /// until the user clicks Retry. Best-effort: a failed ensure leaves the overlay's
    /// error state to surface it.
    private func ensureTabConnections(_ tab: Tab?) {
        guard let tab, !tab.blockids.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let refs = tab.blockids.map { ORef.block($0) }
            _ = try? await self.store.loadMany(refs)
            var conns: Set<String> = []
            for ref in refs {
                guard let conn = self.store.get(ref)?.asBlock?.meta[ConnectionLabel.metaKey]?.stringValue,
                      !ConnectionLabel.isLocal(conn) else { continue }
                conns.insert(conn)
            }
            for conn in conns where !self.ensuredConns.contains(conn) {
                self.ensuredConns.insert(conn)
                do {
                    try await self.service.connEnsure(ConnExtData(connname: conn, logblockid: nil))
                } catch {
                    NSLog("AppCoordinator: connEnsure \(conn) failed: \(error)")
                }
            }
        }
    }

    /// Create a new tab and activate it. Its default terminal opens in the currently
    /// focused pane's working directory, falling back to $HOME (see `applyNewTabCwd`).
    public func newTab() {
        guard let workspaceId else { return }
        // Resolve the cwd NOW: the focused pane belongs to the CURRENT active tab, before we
        // switch away. Always end up with a concrete dir — the durable-shell path has no
        // home fallback of its own, so an unset cwd would drop the shell into the daemon's
        // cwd ("/") instead of the user's home.
        let cwd = focusedBlockCwd() ?? FileManager.default.homeDirectoryForCurrentUser.path
        Task {
            do {
                // Create the tab INACTIVE. `activate: true` makes the backend broadcast
                // `workspace:update`, which `workspaceChanged` reacts to by subscribing the
                // new tab's layout → mounting its block → ControllerResync → the shell starts
                // with an empty `cmd:cwd`, racing (and beating) any meta we set afterwards.
                // Creating it inactive keeps it unmounted until we set `cmd:cwd` and then call
                // `activate`, which starts the shell reading the directory we set.
                let tabId = try await self.service.createTab(workspaceId: workspaceId, name: "", activate: false)
                if !tabId.isEmpty {
                    await self.applyNewTabCwd(tabId: tabId, cwd: cwd)
                    await self.activate(tabId: tabId, isInitial: false)
                }
            } catch {
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    /// The focused pane's working directory, if known. Prefer the live OSC 7 value from
    /// the content provider, then fall back to the persisted `cmd:cwd` block meta. The
    /// fallback matters after an app update/restart: the block is restored before its
    /// terminal has necessarily emitted another OSC 7 report. Internal so the
    /// WindowManager can inherit it for a new window.
    func focusedBlockCwd() -> String? {
        guard let blockId = currentFocusedBlockId() else { return nil }
        return knownCwd(forBlockId: blockId)
    }

    /// Set `cmd:cwd` on the freshly created tab's block(s) so its default terminal opens in
    /// `cwd`. The backend's default new-tab terminal starts no shell until the client
    /// resyncs its controller (on activation), so setting the meta first makes the shell
    /// open there — the same `cmd:cwd` seam a split uses.
    ///
    /// Load the tab FRESH (a GetObject round-trip) rather than the cache fast-path: the
    /// backend seeds the tab's default block a beat after `CreateTab` returns, so a cached
    /// read can still show empty `blockids` — we'd then set `cmd:cwd` on nothing and the
    /// shell would open at the daemon default. Best-effort: a failure leaves the daemon default.
    private func applyNewTabCwd(tabId: String, cwd: String) async {
        guard let tab = (try? await store.load(ORef.tab(tabId)))?.asTab, !tab.blockids.isEmpty else { return }
        for blockId in tab.blockids {
            do {
                try await service.setMeta(oref: .block(blockId), meta: ["cmd:cwd": .string(cwd)])
            } catch {
                NSLog("newTab: failed to set cwd on block \(blockId): \(error)")
            }
        }
    }

    /// The new-window counterpart to `applyNewTabCwd`: seed `cmd:cwd` on a freshly
    /// created workspace's initial tab block(s). Safe to run without the inactive-create
    /// dance `newTab` needs — the workspace's window is opened only AFTER this returns,
    /// so no coordinator has mounted the tab and no shell has started yet.
    func applyNewWorkspaceCwd(workspaceId: String, cwd: String) async {
        guard let ws = (try? await store.load(ORef.workspace(workspaceId)))?.asWorkspace,
              !ws.activetabid.isEmpty else { return }
        await applyNewTabCwd(tabId: ws.activetabid, cwd: cwd)
    }

    /// Ask the backend which applications are still running under the scope's local
    /// shells; if any, route through the delegate's confirmation UI. Returns true to
    /// proceed. A failed check never blocks the close (returns true) — the prompt is
    /// a guard rail, not a gate on backend availability.
    private func confirmCloseIfBusy(_ scope: CommandTermGetRunningCommandsData, target: String) async -> Bool {
        let running = (try? await service.termRunningCommands(scope)) ?? []
        guard !running.isEmpty else { return true }
        var names: [String] = []
        for cmd in running where !names.contains(cmd.command) {
            names.append(cmd.command)
        }
        return await delegate?.coordinatorConfirmClose(target: target, commands: names) ?? true
    }

    /// Window-close gate (red button / Cmd-Shift-W on the last tab): confirm when any
    /// shell in the whole workspace still runs an application.
    public func shouldCloseWindow() async -> Bool {
        guard let workspaceId else { return true }
        return await confirmCloseIfBusy(
            CommandTermGetRunningCommandsData(workspaceid: workspaceId), target: "Window")
    }

    /// Close a tab. GUARDS §C: honor `{ closewindow, newactivetabid }`.
    public func closeTab(_ tabId: String) {
        guard let workspaceId else { return }
        Task {
            guard await self.confirmCloseIfBusy(
                CommandTermGetRunningCommandsData(tabid: tabId), target: "Tab") else { return }
            do {
                let result = try await self.service.closeTab(workspaceId: workspaceId, tabId: tabId)
                if result.closewindow == true {
                    self.delegate?.coordinatorRequestCloseWindow()
                    return
                }
                if let next = result.newactivetabid, !next.isEmpty {
                    await self.activate(tabId: next, isInitial: false)
                }
                self.publishTabs()
            } catch {
                // NOT coordinatorDidFail (fatal modal): the close may have been APPLIED
                // server-side with only the response lost, so converge on the server's
                // state instead of leaving the UI on a half-deleted tab.
                NSLog("WaveUI: closeTab failed, resyncing workspace: \(error)")
                await self.resyncWorkspace(afterFailedCloseOf: tabId)
            }
        }
    }

    /// Reload the workspace after a tab mutation whose outcome is unknown (transport
    /// error) and land wherever the server says we are.
    private func resyncWorkspace(afterFailedCloseOf tabId: String) async {
        guard let workspaceId else { return }
        guard let workspace = try? await loadWorkspace(workspaceId) else { return }
        if workspace.tabids.isEmpty {
            delegate?.coordinatorRequestCloseWindow()
            return
        }
        subscribeTabs(workspace.tabids)
        if !workspace.tabids.contains(tabId) || activeTabId == nil {
            let next = workspace.activetabid.isEmpty ? workspace.tabids[0] : workspace.activetabid
            await activate(tabId: next, isInitial: false)
        }
        publishTabs()
    }

    /// Split the active tab by adding a new terminal pane next to `blockId`
    /// (Cmd-D = side-by-side, Cmd-Shift-D = stacked). Uses the wsh
    /// CreateBlockCommand path, which QUEUES a layout split action into the tab's
    /// LayoutState `pendingbackendactions`; the existing LayoutModel apply-and-clear
    /// machinery (GUARDS §L) then tiles the new pane. We deliberately do NOT use the
    /// HTTP ObjectService.CreateBlock path here — it only appends to tab.BlockIds
    /// without queueing a layout action, which would orphan the block (never tiled).
    /// We also do NOT dispatch a local split: that would double-insert the pane.
    public func splitFocusedBlock(blockId: String, direction: String) {
        let targetAction = (direction == "vertical") ? "splitdown" : "splitright"
        createTermBlock(inheritFromBlockId: blockId, targetBlockId: blockId, targetAction: targetAction)
    }

    /// Create a terminal block in the active tab, inheriting the source block's
    /// connection so a split / new pane opens on the SAME connection. A `targetBlockId`
    /// + `targetAction` queues a split; their absence queues a plain insert (GUARDS §L).
    ///
    /// A terminal block needs BOTH the view and the shell controller (the canonical term
    /// widget BlockDef, `widgets.json`): without controller=shell the backend starts no
    /// pty. For a REMOTE inherited connection we ensure-connect FIRST — the backend
    /// refuses to start a remote shell until the connection is Status_Connected.
    private func createTermBlock(inheritFromBlockId: String?, targetBlockId: String?, targetAction: String?) {
        guard let activeTabId else { return }
        let conn = inheritedConnection(fromBlockId: inheritFromBlockId)
        var meta: MetaMapType = ["view": .string("term"), "controller": .string("shell")]
        if let conn { meta[ConnectionLabel.metaKey] = .string(conn) }
        // Inherit the source pane's working directory on a split. The backend honors the
        // `cmd:cwd` block meta when starting the shell (pkg/waveobj/metaconsts.go
        // `MetaKey_CmdCwd` → durableshellcontroller.go → shellexec `ecmd.Dir`), with an
        // invalid path falling back to $HOME, so an unknown/stale cwd is harmless. Prefer
        // the content provider's live OSC 7 value; after a native-app restart that cache
        // starts empty, so `knownCwd` falls back to the source block's persisted meta.
        if let inheritFromBlockId,
           let cwd = knownCwd(forBlockId: inheritFromBlockId) {
            meta["cmd:cwd"] = .string(cwd)
        }
        let termDef = BlockDef(meta: meta)
        let data = CommandCreateBlockData(
            tabid: activeTabId, blockdef: termDef, focused: true,
            targetblockid: targetBlockId, targetaction: targetAction)
        Task {
            do {
                if let conn {
                    try await self.service.connEnsure(ConnExtData(connname: conn, logblockid: nil))
                }
                let newRef = try await self.service.createBlockWsh(data)
                self.delegate?.coordinatorRequestFocusBlock(newRef.oid)
            } catch {
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    /// Running durable SHELL jobs with no live pane: unattached, or attached to a
    /// block that no longer exists (deleted while wavesrv was down, closed window,
    /// another instance's leftovers). These are the sessions the reattach picker
    /// (Cmd-Shift-J) offers.
    public func listDetachedShellJobs() async -> [JobInfo] {
        guard let jobs = try? await service.listJobs() else { return [] }
        var result: [JobInfo] = []
        for job in jobs {
            guard job.jobmanagerstatus == "running", (job.jobkind ?? "shell") == "shell" else { continue }
            if let attached = job.attachedblockid, !attached.isEmpty {
                if (try? await store.load(ORef.block(attached))) != nil { continue }
            }
            result.append(job)
        }
        return result
    }

    /// Reattach a running durable job into a NEW terminal pane in the active tab.
    /// Order matters:
    ///   1. The block is created WITHOUT a controller, so its mount resync cannot race
    ///      us by starting a fresh shell before the job is bound.
    ///   2. A job still pointing at its (dead) old block must be detached first —
    ///      `attachjob` refuses to steal an attached job.
    ///   3. `disconnectjob` forces the next reconnect to restart streaming at the NEW
    ///      block's file offset (0), which replays the manager's recent buffer; a
    ///      still-connected stream would only deliver future bytes into an empty pane.
    ///   4. controller=shell + resync makes DurableShellController take the
    ///      reuse-jobId path (reconnect, not a fresh shell).
    public func reattachJob(_ job: JobInfo) {
        guard let activeTabId else { return }
        var meta: MetaMapType = ["view": .string("term")]
        let conn = job.connection
        if let conn, !ConnectionLabel.isLocal(conn) {
            meta[ConnectionLabel.metaKey] = .string(conn)
        }
        let data = CommandCreateBlockData(
            tabid: activeTabId, blockdef: BlockDef(meta: meta), focused: true,
            targetblockid: nil, targetaction: nil)
        Task {
            do {
                if let conn = meta[ConnectionLabel.metaKey]?.stringValue {
                    try await self.service.connEnsure(ConnExtData(connname: conn, logblockid: nil))
                }
                let newRef = try await self.service.createBlockWsh(data)
                if let attached = job.attachedblockid, !attached.isEmpty {
                    try await self.service.detachJob(jobId: job.oid)
                }
                try await self.service.attachJob(jobId: job.oid, blockId: newRef.oid)
                try await self.service.disconnectJob(jobId: job.oid)
                try await self.service.setMeta(oref: .block(newRef.oid), meta: ["controller": .string("shell")])
                try await self.service.controllerResync(tabId: activeTabId, blockId: newRef.oid, forceRestart: false)
                self.delegate?.coordinatorRequestFocusBlock(newRef.oid)
            } catch {
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    /// Open a URL as a NEW web pane split to the right of `blockId` (terminal OSC-8
    /// link open). Mirrors `splitFocusedBlock`'s create path but with a `view:"web"`
    /// BlockDef (no controller — a web block has no pty). Uses the wsh CreateBlock path
    /// so the new pane is tiled via the queued layout split (GUARDS §L).
    public func openWebBlock(fromBlockId blockId: String, url: String) {
        guard let activeTabId else { return }
        // `web:openlinksinternally` (default false, Electron `openLink`) decides whether a
        // terminal hyperlink opens as a web pane or hands off to the system browser.
        if !Self.shouldOpenLinksInternally(currentSettings()) {
            if let parsed = URL(string: url) { NSWorkspace.shared.open(parsed) }
            return
        }
        let data = Self.makeWebLinkCreateBlockData(tabId: activeTabId, targetBlockId: blockId, url: url)
        Task {
            do {
                let newRef = try await self.service.createBlockWsh(data)
                self.delegate?.coordinatorRequestFocusBlock(newRef.oid)
            } catch {
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    /// Pure builder for the "open OSC-8 link as a web pane" create-block request, so
    /// the meta/target mapping is unit-testable without a transport. A web block is
    /// just `meta.view == "web"` + the URL to load; it splits to the right of the
    /// source pane and takes focus.
    static func makeWebLinkCreateBlockData(
        tabId: String, targetBlockId: String, url: String
    ) -> CommandCreateBlockData {
        let meta: MetaMapType = [
            "view": .string("web"),
            "url": .string(url),
        ]
        return CommandCreateBlockData(
            tabid: tabId, blockdef: BlockDef(meta: meta), focused: true,
            targetblockid: targetBlockId, targetaction: "splitright")
    }

    /// Toggle magnify on the pane owning `blockId`. Magnify is a CLIENT-SIDE layout
    /// action (unlike split, which queues a backend block create): resolve the
    /// reporting blockId to its node id and dispatch through the local LayoutModel
    /// reducer (apply + re-render + debounced persist).
    public func magnifyFocusedBlock(blockId: String) {
        guard let model = layoutModel else { return }
        let root = model.currentState().rootNode
        guard let nodeId = LayoutTree.findNodeByBlockId(root, blockId: blockId)?.id else { return }
        model.dispatch(.magnifyNodeToggle(nodeId: nodeId))
    }

    /// Terminate every durable local shell so none survives for reconnect (the
    /// backend half of "Quit and Close All Shells"). Normal quit detaches the shells
    /// and leaves their job-managers running; this kills them. The caller quits the
    /// app once this resolves. Returns the number of shells terminated.
    @discardableResult
    public func terminateAllShells() async throws -> Int {
        try await service.terminateAllShells()
    }

    /// Dispatch a mouse-driven layout mutation (e.g. a splitter resize) through the
    /// local reducer (apply + re-render + debounced persist). The dispatch seam for
    /// `LayoutTreeView`'s gesture handling.
    public func dispatchLayout(_ action: LayoutTreeAction) {
        layoutModel?.dispatch(action)
    }

    // MARK: - Keyboard-driven tab/block operations

    /// Switch to the tab at `index1Based` (1 = first) in the active workspace's
    /// ordered tab list. Mirrors Electron `switchTabAbs` (Cmd-1..Cmd-9). Goes
    /// through `activate()` so the GUARDS §C SetActiveTab trigger always fires.
    public func switchTabByIndex(_ index1Based: Int) {
        guard let tabs = currentWorkspace()?.tabids,
              index1Based >= 1, index1Based <= tabs.count else { return }
        let target = tabs[index1Based - 1]
        guard target != activeTabId else { return }
        Task { await self.activate(tabId: target, isInitial: false) }
    }

    /// Switch tab by a relative offset over the ordered tab list, wrapping around
    /// (Electron `switchTab(+1)` / `switchTab(-1)` → Cmd-] / Cmd-[ and Cmd-arrows).
    public func switchTabRelative(_ offset: Int) {
        guard let tabs = currentWorkspace()?.tabids, !tabs.isEmpty,
              let activeTabId, let idx = tabs.firstIndex(of: activeTabId) else { return }
        let n = tabs.count
        let target = tabs[((idx + offset) % n + n) % n]
        guard target != activeTabId else { return }
        Task { await self.activate(tabId: target, isInitial: false) }
    }

    /// The block id of the active tab's focused pane, resolved from the LayoutModel's
    /// `focusednodeid` (falling back to the first leaf, matching
    /// `LayoutReducer.validateFocusedNode`). Window-level Cmd-D/M/W act on this when
    /// a non-terminal block is focused and the terminal view can't report its own id.
    public func currentFocusedBlockId() -> String? {
        guard let model = layoutModel else { return nil }
        let state = model.currentState()
        if let nodeId = state.focusedNodeId,
           let node = LayoutTree.findNode(state.rootNode, id: nodeId),
           let blockId = node.data?.blockId {
            return blockId
        }
        return state.leafOrder?.first?.blockid
    }

    /// Split the focused pane (Cmd-D = "horizontal", Cmd-Shift-D = "vertical").
    /// The window-level fallback for when the focused block isn't a terminal (a
    /// terminal handles the combo itself and reports its own blockId).
    public func splitFocused(direction: String) {
        guard let blockId = currentFocusedBlockId() else { return }
        splitFocusedBlock(blockId: blockId, direction: direction)
    }

    /// Toggle magnify on the focused pane (Cmd-M window-level fallback).
    public func magnifyFocused() {
        guard let blockId = currentFocusedBlockId() else { return }
        magnifyFocusedBlock(blockId: blockId)
    }

    /// Add a new default-terminal block to the active tab without splitting
    /// (Electron `handleCmdN`, Cmd-N). Uses the wsh insert path (no target), which
    /// queues an `insert` layout action like split does (GUARDS §L).
    public func newBlockInTab() {
        createTermBlock(
            inheritFromBlockId: currentFocusedBlockId(), targetBlockId: nil, targetAction: nil)
    }

    /// Close the focused pane; if it is the tab's only pane, close the whole tab
    /// instead (Electron `genericClose`, Cmd-W). Block deletion goes through the wsh
    /// `deleteblock` command, which removes the block AND queues a layout `delete`
    /// action delivered via the layout subscription (GUARDS §L).
    public func closeFocusedBlock() {
        guard let model = layoutModel else {
            closeActiveTab()
            return
        }
        let leafCount = model.currentState().leafOrder?.count ?? 0
        if leafCount <= 1 {
            closeActiveTab()
            return
        }
        guard let blockId = currentFocusedBlockId() else { return }
        deleteBlockConfirmed(blockId)
    }

    /// Shared tail of the pane-close paths: confirm while an application still runs
    /// in the pane's shell, then notify + delete.
    private func deleteBlockConfirmed(_ blockId: String) {
        Task {
            guard await self.confirmCloseIfBusy(
                CommandTermGetRunningCommandsData(blockid: blockId), target: "Pane") else { return }
            self.notifyWillDeleteBlock(blockId)
            do {
                try await self.service.deleteBlockWsh(blockId: blockId)
            } catch {
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    /// Notify the delegate (→ content provider) that a block is about to be deleted so
    /// it can free external resources (a web block's persistent WKWebsiteDataStore).
    /// Reads the still-cached block snapshot before the backend delete removes it.
    private func notifyWillDeleteBlock(_ blockId: String) {
        guard let block = store.get(.block(blockId))?.asBlock else { return }
        delegate?.coordinatorWillDeleteBlock(block)
    }

    /// Force-close the whole active tab (Electron `simpleCloseStaticTab`, Cmd-Shift-W).
    public func closeActiveTab() {
        guard let activeTabId else { return }
        closeTab(activeTabId)
    }

    /// Close a specific pane by block id (block right-click → "Close Block"). Mirrors
    /// `closeFocusedBlock` but targets an explicit block: if it is the tab's only pane,
    /// close the whole tab instead (deleting the last block would orphan an empty tab).
    public func closeBlock(blockId: String) {
        guard let model = layoutModel else {
            closeActiveTab()
            return
        }
        let leafCount = model.currentState().leafOrder?.count ?? 0
        if leafCount <= 1 {
            closeActiveTab()
            return
        }
        deleteBlockConfirmed(blockId)
    }

    // MARK: - Connection operations

    /// Open the connection typeahead for a block (header connection label click). Pulls
    /// the live `connlist` (plus a synthetic "Local" entry, added by the presenter) and
    /// hands the chrome a select callback that routes the pick back through
    /// `setBlockConnection`.
    public func pickConnection(blockId: String) {
        Task {
            let connections = (try? await self.service.connList()) ?? []
            let current = self.store.get(.block(blockId))?.asBlock?
                .meta[ConnectionLabel.metaKey]?.stringValue
            self.delegate?.coordinatorPresentConnectionPicker(
                blockId: blockId, current: current, connections: connections,
                onSelect: { [weak self] picked in
                    self?.setBlockConnection(blockId: blockId, connName: picked)
                })
        }
    }

    /// Switch a block to `connName` (the connection picker pick). Sets the block's
    /// `connection` meta, then — for a REMOTE connection — ensure-connects it
    /// (`connensure`), the precondition the backend requires before a remote shell can
    /// start. "Local" (or blank) clears the meta back to the local machine.
    public func setBlockConnection(blockId: String, connName: String) {
        let normalized = ConnectionLabel.isLocal(connName) ? "" : connName
        Task {
            do {
                let value: JSONValue = normalized.isEmpty ? .null : .string(normalized)
                try await self.service.setMeta(oref: .block(blockId), meta: [ConnectionLabel.metaKey: value])
                if !normalized.isEmpty {
                    try await self.service.connEnsure(
                        ConnExtData(connname: normalized, logblockid: blockId))
                }
            } catch {
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    /// The `connection` meta of an existing block, normalized: nil for the local
    /// machine, else the remote "user@host". New panes inherit this so a split opens on
    /// the same connection as its source.
    private func inheritedConnection(fromBlockId blockId: String?) -> String? {
        guard let blockId,
              let conn = store.get(.block(blockId))?.asBlock?.meta[ConnectionLabel.metaKey]?.stringValue,
              !ConnectionLabel.isLocal(conn) else { return nil }
        return conn
    }

    /// Resolve a pane cwd across the native-app lifecycle. A mounted terminal's live
    /// value is freshest; `cmd:cwd` survives a UI process replacement during updates and
    /// bridges the interval before the restored terminal reports OSC 7 again.
    private func knownCwd(forBlockId blockId: String) -> String? {
        if let liveCwd = delegate?.coordinatorCwdForBlock(blockId), !liveCwd.isEmpty {
            return liveCwd
        }
        guard let persistedCwd = store.get(.block(blockId))?.asBlock?.meta["cmd:cwd"]?.stringValue,
              !persistedCwd.isEmpty else { return nil }
        return persistedCwd
    }

    // MARK: - Workspace operations

    /// Move a tab to another workspace (tab right-click → "Move to Workspace"). The
    /// source is the current workspace; the backend's MoveTab broadcasts the resulting
    /// workspace updates via `waveobj:update`, so the strip refreshes through the normal
    /// subscription — no local mutation here.
    public func moveTabToWorkspace(tabId: String, workspaceId destWorkspaceId: String) {
        guard let sourceWorkspaceId = workspaceId, destWorkspaceId != sourceWorkspaceId else { return }
        Task {
            do {
                try await self.service.moveTab(
                    sourceWorkspaceId: sourceWorkspaceId, destWorkspaceId: destWorkspaceId, tabId: tabId)
            } catch {
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    /// Reorder the current workspace's tabs (drag-drop within the strip). Persists the
    /// new order via `updateworkspacetabids`; the backend broadcasts the workspace update
    /// over `waveobj:update`, so the strip refreshes through the normal subscription — no
    /// local mutation here.
    public func reorderTabs(tabIds: [String]) {
        guard let workspaceId else {
            dndLog("coordinator reorderTabs: no workspaceId")
            return
        }
        dndLog("coordinator reorderTabs ws=\(workspaceId.suffix(4)) order=\(tabIds.map { $0.suffix(4) })")
        Task {
            do {
                try await self.service.updateWorkspaceTabIds(workspaceId: workspaceId, tabIds: tabIds)
                dndLog("coordinator reorderTabs OK")
            } catch {
                dndLog("coordinator reorderTabs FAILED: \(error)")
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    /// Receive a tab dragged from ANOTHER workspace's strip (another window) and move it
    /// into THIS coordinator's workspace. The drop lands on the destination strip, so the
    /// origin arrives explicitly from the drag pasteboard (we are the destination, not the
    /// source). Reuses the same backend `movetab` path as the right-click "Move to
    /// Workspace" gesture.
    public func receiveTabDrop(tabId: String, fromWorkspaceId sourceWorkspaceId: String) {
        guard let destWorkspaceId = workspaceId,
              !sourceWorkspaceId.isEmpty, sourceWorkspaceId != destWorkspaceId else {
            dndLog("coordinator receiveTabDrop guard-failed dest=\(workspaceId?.suffix(4) ?? "nil") src=\(sourceWorkspaceId.suffix(4))")
            return
        }
        dndLog("coordinator receiveTabDrop tab=\(tabId.suffix(4)) src=\(sourceWorkspaceId.suffix(4)) dest=\(destWorkspaceId.suffix(4))")
        Task {
            do {
                try await self.service.moveTab(
                    sourceWorkspaceId: sourceWorkspaceId, destWorkspaceId: destWorkspaceId, tabId: tabId)
                dndLog("coordinator receiveTabDrop OK")
            } catch {
                dndLog("coordinator receiveTabDrop FAILED: \(error)")
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    /// Receive a pane (block) dragged from a layout view and dropped on a tab pill —
    /// move the block into that tab. Works cross-window the same way as tab drops: the
    /// drop lands on the destination strip, the backend re-parents the block and queues
    /// the layout actions, and both tabs refresh via their LayoutState subscriptions.
    public func receiveBlockDrop(blockId: String, targetTabId: String) {
        dndLog("coordinator receiveBlockDrop block=\(blockId.suffix(4)) tab=\(targetTabId.suffix(4))")
        Task {
            do {
                try await self.service.moveBlockToTab(blockId: blockId, targetTabId: targetTabId)
                dndLog("coordinator receiveBlockDrop OK")
            } catch {
                dndLog("coordinator receiveBlockDrop FAILED: \(error)")
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    /// Rename a tab (inline editor commit / "Rename Tab" menu item). The backend
    /// broadcasts the tab update via `waveobj:update`, so the strip refreshes through
    /// the normal subscription.
    public func renameTab(tabId: String, name: String) {
        Task {
            do {
                try await self.service.updateTabName(tabId: tabId, name: name)
            } catch {
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    /// Set (or clear, when `color` is nil) a tab's flag color via SetMeta
    /// (`tab:flagcolor`), mirroring Electron's "Flag Tab" submenu. The colored flag
    /// renders in the pill once the `waveobj:update` subscription delivers the change.
    public func setTabFlagColor(tabId: String, color: String?) {
        Task {
            do {
                let value: JSONValue = color.map { .string($0) } ?? .null
                try await self.service.setMeta(oref: .tab(tabId), meta: ["tab:flagcolor": value])
            } catch {
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    /// Apply a tab's "Background" submenu choice via SetMeta. `meta` is the `tab:background`
    /// / `bg*` patch built by `TabBackgroundMenu` (a `.null` value deletes a key). The
    /// resolved background re-renders once the `waveobj:update` subscription delivers the
    /// change (same path as the flag color) — see `publishTabBackground`.
    public func setTabBackground(tabId: String, meta: MetaMapType) {
        Task {
            do {
                try await self.service.setMeta(oref: .tab(tabId), meta: meta)
            } catch {
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    /// Parse the `backgrounds` config map into ordered preset menu items (mirrors
    /// `parseTermThemes`). `display:name` is required by the schema; entries without one
    /// fall back to the key. Sorted by `display:order` then name. Pure → unit-testable.
    static func parseBackgroundPresets(_ config: JSONValue?) -> [TabBackgroundPreset] {
        guard let backgrounds = config?["backgrounds"]?.objectValue else { return [] }
        return backgrounds.compactMap { key, value -> TabBackgroundPreset? in
            guard case .object = value else { return nil }
            let name = value["display:name"]?.stringValue
            return TabBackgroundPreset(
                key: key,
                displayName: (name?.isEmpty == false) ? name! : key,
                order: value["display:order"]?.doubleValue ?? 0)
        }
        .sorted { ($0.order, $0.displayName) < ($1.order, $1.displayName) }
    }

    /// Push the current background presets to the delegate (pill "Background" submenu).
    private func publishBackgroundPresets() {
        delegate?.coordinatorDidUpdateBackgroundPresets(Self.parseBackgroundPresets(fullConfig))
    }

    /// Fetch the selectable color/icon palettes once and hand them to the delegate.
    /// Best-effort: a failure just leaves the editor grids empty.
    private func loadWorkspacePalette() async {
        guard workspaceColors.isEmpty || workspaceIcons.isEmpty else {
            delegate?.coordinatorDidUpdateWorkspacePalette(colors: workspaceColors, icons: workspaceIcons)
            return
        }
        async let colors = try? service.getColors()
        async let icons = try? service.getIcons()
        workspaceColors = (await colors) ?? []
        workspaceIcons = (await icons) ?? []
        delegate?.coordinatorDidUpdateWorkspacePalette(colors: workspaceColors, icons: workspaceIcons)
    }

    /// Rename a workspace (inline editor commit). `UpdateWorkspace` is the single
    /// persist path; the backend broadcasts `workspace:update`, so every window's
    /// switcher refreshes through the existing subscription.
    public func renameWorkspace(_ id: String, name: String) {
        updateWorkspace(id, name: name, icon: "", color: "", applyDefaults: false)
    }

    /// Set a workspace's color (editor swatch pick). Only the color field is sent;
    /// empty name/icon leave those untouched.
    public func setWorkspaceColor(id: String, color: String) {
        updateWorkspace(id, name: "", icon: "", color: color, applyDefaults: false)
    }

    /// Set a workspace's icon (editor grid pick).
    public func setWorkspaceIcon(id: String, icon: String) {
        updateWorkspace(id, name: "", icon: icon, color: "", applyDefaults: false)
    }

    /// "Save workspace": promote an ephemeral workspace to saved by applying defaults
    /// for any blank name/icon/color (mirrors Electron's `saveWorkspace`).
    public func saveWorkspace(_ id: String) {
        updateWorkspace(id, name: "", icon: "", color: "", applyDefaults: true)
    }

    /// Delete a workspace (editor trash button). The backend broadcasts updates; refresh
    /// the list so the switcher drops it immediately.
    public func deleteWorkspace(_ id: String) {
        Task {
            do {
                try await self.service.deleteWorkspace(workspaceId: id)
                await self.refreshWorkspaceList()
            } catch {
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    /// "Save Layout" (switcher row context menu): snapshot the workspace's current tabs +
    /// panes into its own meta. Refresh the list so the row's "Reset to Saved Layout"
    /// action becomes enabled immediately.
    public func saveWorkspaceLayout(_ id: String) {
        Task {
            do {
                try await self.service.saveWorkspaceLayout(workspaceId: id)
                await self.refreshWorkspaceList()
            } catch {
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    /// "Reset to Saved Layout" (switcher row context menu): rebuild the workspace to its
    /// saved snapshot, force-closing drifted tabs/panes. The backend broadcasts the object
    /// updates; refresh so the switcher reflects the rebuilt tab set.
    public func restoreWorkspaceLayout(_ id: String) {
        Task {
            do {
                try await self.service.restoreWorkspaceLayout(workspaceId: id)
                await self.refreshWorkspaceList()
            } catch {
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    private func updateWorkspace(_ id: String, name: String, icon: String, color: String, applyDefaults: Bool) {
        Task {
            do {
                try await self.service.updateWorkspace(
                    workspaceId: id, name: name, icon: icon, color: color, applyDefaults: applyDefaults)
            } catch {
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    public func switchWorkspace(_ newWorkspaceId: String) {
        guard let windowId, newWorkspaceId != workspaceId else { return }
        Task {
            do {
                guard let workspace = try await self.service.switchWorkspace(windowId: windowId, workspaceId: newWorkspaceId) else { return }
                self.workspaceId = workspace.oid
                self.subscribeWorkspaceEvents(workspaceId: workspace.oid)
                self.subscribeWorkspaceObject(workspaceId: workspace.oid)
                _ = try? await self.store.loadMany(workspace.tabids.map { ORef.tab($0) })
                self.subscribeTabs(workspace.tabids)
                let active = workspace.activetabid.isEmpty ? workspace.tabids.first : workspace.activetabid
                self.activeTabId = active
                self.publishWorkspace()
                self.publishTabs()
                // The set of workspaces (and the active one) just changed: re-pull the
                // authoritative list so both the chrome dropdown and the Cmd-Shift-O
                // overlay stay live instead of showing the startup snapshot.
                await self.refreshWorkspaceList()
                if let active { await self.activate(tabId: active, isInitial: true) }
            } catch {
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    /// Resolve the backend `window:<id>` that owns `workspaceId`, creating one if the
    /// workspace is not open in any window yet. Used by the WindowManager's
    /// focus-or-open: an already-open workspace returns its existing window (we focus
    /// it); a closed one gets a fresh window bound to it via `CreateWindow`. Returns
    /// nil on error (already surfaced to the delegate).
    public func resolveWindowId(forWorkspace workspaceId: String) async -> String? {
        do {
            let entries = try await service.listWorkspaces()
            if let existing = entries.first(where: { $0.workspaceid == workspaceId }),
               !existing.windowid.isEmpty {
                return existing.windowid
            }
            return try await service.createWindow(workspaceId: workspaceId)?.oid
        } catch {
            delegate?.coordinatorDidFail(error)
            return nil
        }
    }

    /// Tell the backend to close this window (`window.CloseWindow`): removes the
    /// `window:<id>` from `client.windowids` and deletes its workspace iff that
    /// workspace is empty AND unnamed. Called by the WindowManager when the user
    /// closes a non-last NSWindow, so a closed window does not resurrect on the next
    /// bind/launch. Best-effort — the window is going away regardless.
    public func closeBackendWindow() async {
        guard let windowId else { return }
        _ = try? await service.call(WebCallType(
            service: WaveService.window, method: "CloseWindow",
            args: [.string(windowId), .bool(true)]
        ))
    }

    /// Create a new workspace and return its id WITHOUT switching the current window
    /// to it (the WindowManager opens a separate NSWindow instead — workspace per
    /// window). A named workspace (user typed a name) is saved with default icon/color;
    /// an unnamed one (e.g. Cmd-N / new window) stays EPHEMERAL until explicitly saved,
    /// so `applyDefaults` follows whether a name was given. Returns nil on error.
    public func createWorkspaceReturningId(named name: String = "") async -> String? {
        do {
            let result = try await service.call(WebCallType(
                service: WaveService.workspace, method: "CreateWorkspace",
                args: [.string(name), .string(""), .string(""), .bool(!name.isEmpty)]
            ))
            return result.data?.stringValue
        } catch {
            delegate?.coordinatorDidFail(error)
            return nil
        }
    }

    public func createWorkspace(named name: String = "") {
        Task {
            do {
                // CreateWorkspace then SwitchWorkspace to it. A named workspace is saved
                // (default icon/color); an unnamed one stays ephemeral until explicitly saved.
                let result = try await self.service.call(WebCallType(
                    service: WaveService.workspace, method: "CreateWorkspace",
                    args: [.string(name), .string(""), .string(""), .bool(!name.isEmpty)]
                ))
                if let newId = result.data?.stringValue, !newId.isEmpty {
                    // Refresh up front so the new workspace is present even if the
                    // subsequent switch is delayed or short-circuits.
                    await self.refreshWorkspaceList()
                    self.switchWorkspace(newId)
                }
            } catch {
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    // MARK: - Publishing to the delegate

    private func currentWorkspace() -> Workspace? {
        guard let workspaceId else { return nil }
        return store.get(ORef.workspace(workspaceId))?.asWorkspace
    }

    private func publishWorkspace() {
        guard let ws = currentWorkspace() else { return }
        delegate?.coordinatorDidUpdateWorkspace(name: ws.name, icon: ws.icon, color: ws.color, workspaceId: ws.oid)
    }

    private func publishTabs() {
        guard let ws = currentWorkspace() else { return }
        let tabs: [TabBarItem] = ws.tabids.map { id in
            let tab = store.get(ORef.tab(id))?.asTab
            let name = tab?.name ?? ""
            let flagColor = tab?.meta["tab:flagcolor"]?.stringValue
            let bgPreset = tab?.meta["tab:background"]?.stringValue
            return TabBarItem(tabId: id, name: name.isEmpty ? "Tab" : name, flagColor: flagColor,
                              hasUnread: unreadTabs.contains(id),
                              backgroundPresetKey: (bgPreset?.isEmpty == false) ? bgPreset : nil)
        }
        delegate?.coordinatorDidUpdateTabs(tabs, activeTabId: activeTabId)
        publishTabBackground()
    }

    /// Resolve the active tab's background and push it to the chrome. Called from the same
    /// `publishTabs()` path that fires on tab activate AND on a tab's meta change (via
    /// `subscribeTabs`), so picking a background or switching tabs both update it.
    private func publishTabBackground() {
        guard let activeTabId, let tab = store.get(ORef.tab(activeTabId))?.asTab else {
            delegate?.coordinatorDidUpdateTabBackground(nil)
            return
        }
        let backgrounds = fullConfig?["backgrounds"]?.objectValue
        delegate?.coordinatorDidUpdateTabBackground(
            Self.resolveTabBackground(meta: tab.meta, backgrounds: backgrounds))
    }

    /// Resolve a tab's background config from its meta. A named `tab:background` preset (a
    /// key into the config `backgrounds` map) wins over inline `bg*` meta, mirroring
    /// Electron's `resolvedMeta = tabBg && configBg ? configBg : tabData.meta`. Returns nil
    /// when no `bg` is set. Pure → unit-testable.
    static func resolveTabBackground(
        meta: MetaMapType, backgrounds: [String: JSONValue]?
    ) -> TabBackgroundConfig? {
        var src = meta
        if let key = meta["tab:background"]?.stringValue, !key.isEmpty,
           let preset = backgrounds?[key]?.objectValue {
            src = preset
        }
        guard let bg = src["bg"]?.stringValue,
              !bg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return TabBackgroundConfig(
            bg: bg, opacity: src["bg:opacity"]?.doubleValue,
            blendMode: src["bg:blendmode"]?.stringValue)
    }

    // MARK: - Bell / desktop notifications

    /// A terminal rang the bell. Badge the tab if it is in the background, and raise a
    /// desktop notification unless the user is already looking at that pane.
    func handleBell(blockId: String, tabId: String) {
        raise(blockId: blockId, tabId: tabId, title: nil, body: "Bell")
    }

    /// A terminal emitted an OSC 9 / OSC 777 desktop notification.
    func handleNotification(blockId: String, tabId: String, title: String?, body: String) {
        let text = body.isEmpty ? "Notification" : body
        raise(blockId: blockId, tabId: tabId, title: title, body: text)
    }

    private func raise(blockId: String, tabId: String, title: String?, body: String) {
        let tabIsActive = (tabId == activeTabId)
        if Self.shouldBadgeTab(tabIsActive: tabIsActive), unreadTabs.insert(tabId).inserted {
            publishTabs()
        }
        let enabled = Self.notificationsEnabled(currentSettings())
        let windowKey = delegate?.coordinatorIsWindowKey() ?? false
        guard Self.shouldRaiseDesktopNotification(
            tabIsActive: tabIsActive, windowIsKey: windowKey,
            appIsActive: NSApplication.shared.isActive, notificationsEnabled: enabled)
        else { return }
        guard let windowId else { return }
        onDesktopNotification?(DesktopNotificationRequest(
            title: title, body: body, blockId: blockId, tabId: tabId, windowId: windowId))
    }

    /// Whether to badge a tab's pill: only when the tab is NOT the active one (a
    /// background tab the user is not currently viewing). Pure → unit-testable.
    static func shouldBadgeTab(tabIsActive: Bool) -> Bool {
        return !tabIsActive
    }

    /// Whether to raise a macOS desktop notification. Suppressed only when the user is
    /// demonstrably looking at the pane (its tab is active AND its window is key AND the
    /// app is frontmost), and always suppressed when notifications are disabled. Pure.
    static func shouldRaiseDesktopNotification(
        tabIsActive: Bool, windowIsKey: Bool, appIsActive: Bool, notificationsEnabled: Bool
    ) -> Bool {
        guard notificationsEnabled else { return false }
        return !(tabIsActive && windowIsKey && appIsActive)
    }

    /// `notification:enabled` (default true) — the global desktop-notification gate. Pure.
    static func notificationsEnabled(_ settings: [String: JSONValue]) -> Bool {
        return settings["notification:enabled"]?.boolValue ?? true
    }

    /// Activate `tabId` and move focus to `blockId` (a desktop-notification click). The
    /// tab switch clears its badge via `activate`.
    public func revealBlock(tabId: String, blockId: String) {
        if tabId != activeTabId {
            selectTab(tabId)
        } else {
            unreadTabs.remove(tabId)
            publishTabs()
        }
        // Defer the focus so the tab's layout view is the visible one when it lands.
        DispatchQueue.main.async { [weak self] in self?.delegate?.coordinatorRequestFocusBlock(blockId) }
    }

    private func publishLayoutFromModel() {
        guard let windowId, let activeTabId, let model = layoutModel else { return }
        // A late tree-change from a PREVIOUS tab's model (its subscription races the tab
        // switch) must not publish under the new activeTabId — that painted the old tree
        // into the new tab's fresh layout view for one frame (a green-border flicker).
        guard model.tabId == activeTabId else {
            dndLog("coordinator publishLayout skipped: model.tab=\(model.tabId.suffix(4)) active=\(activeTabId.suffix(4))")
            return
        }
        let tree = model.currentState()
        // Drop layout leaves whose block can no longer be resolved (a dead/orphaned
        // pane left dangling in the tree). The active tab's blockids is the authoritative
        // membership list — a leaf for a block that is neither listed there nor cached in
        // the store is gone, so it is pruned instead of rendered as a dead black pane.
        // Skip pruning when the tab has no blockids yet (freshly created / not loaded), so
        // a just-created block is never dropped before its update lands.
        let tabBlockIds = Set(store.get(ORef.tab(activeTabId))?.asTab?.blockids ?? [])
        let rootNode: LayoutNode?
        if tabBlockIds.isEmpty {
            rootNode = tree.rootNode
        } else {
            rootNode = Self.prunedLayoutRoot(tree.rootNode) { [store] blockId in
                tabBlockIds.contains(blockId) || store.get(.block(blockId)) != nil
            }
        }
        let env = BlockEnvFactory(
            transport: transport, store: store, tabId: activeTabId, windowId: windowId,
            onSplit: { [weak self] blockId, direction in
                Task { @MainActor in self?.splitFocusedBlock(blockId: blockId, direction: direction) }
            },
            onMagnify: { [weak self] blockId in
                Task { @MainActor in self?.magnifyFocusedBlock(blockId: blockId) }
            },
            onClose: { [weak self] blockId in
                Task { @MainActor in self?.closeBlock(blockId: blockId) }
            },
            onPickConnection: { [weak self] blockId in
                Task { @MainActor in self?.pickConnection(blockId: blockId) }
            },
            onOpenWebURL: { [weak self] blockId, url in
                Task { @MainActor in self?.openWebBlock(fromBlockId: blockId, url: url) }
            },
            onRequestFocus: { [weak self] blockId in
                Task { @MainActor in self?.delegate?.coordinatorRequestFocusBlock(blockId) }
            },
            onBell: { [weak self] blockId, tabId in
                Task { @MainActor in self?.handleBell(blockId: blockId, tabId: tabId) }
            },
            onNotification: { [weak self] blockId, tabId, title, body in
                Task { @MainActor in
                    self?.handleNotification(blockId: blockId, tabId: tabId, title: title, body: body)
                }
            },
            onClipboardCopy: { data in
                // OSC 52 copy: any pane (incl. background / over SSH) may set the system
                // clipboard, matching the escape's intent. Write-only — reads are dropped
                // in the scanner.
                Task { @MainActor in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
                }
            },
            connections: connectionStore,
            termThemes: termThemeMenuItems(),
            defaultTermThemeName: currentSettings()["term:theme"]?.stringValue.flatMap {
                $0.isEmpty ? nil : $0
            } ?? Self.defaultTermThemeName)
        delegate?.coordinatorDidUpdateLayout(
            env: env, root: rootNode, focusedNodeId: tree.focusedNodeId,
            magnifiedNodeId: tree.magnifiedNodeId)
    }

    /// Recursively drop layout leaves whose block fails `isBlockResolvable`, collapsing
    /// any internal node left with a single child into that child (the tiling-tree
    /// invariant: internal nodes never hold exactly one child). Returns nil when the
    /// whole subtree resolves away. Pure → unit-testable without a transport/store.
    static func prunedLayoutRoot(
        _ node: LayoutNode?, isBlockResolvable: (String) -> Bool
    ) -> LayoutNode? {
        guard let node else { return nil }
        if let children = node.children, !children.isEmpty {
            let pruned = children.compactMap { prunedLayoutRoot($0, isBlockResolvable: isBlockResolvable) }
            if pruned.isEmpty { return nil }
            if pruned.count == 1 { return pruned[0] }
            var copy = node
            copy.children = pruned
            return copy
        }
        if let blockId = node.data?.blockId, !isBlockResolvable(blockId) {
            return nil
        }
        return node
    }

    private func refreshWorkspaceList() async {
        guard let entries = try? await service.listWorkspaces() else { return }
        // Resolve names from cached/loaded workspace objects.
        let refs = entries.map { ORef.workspace($0.workspaceid) }
        _ = try? await store.loadMany(refs)
        let openWorkspaceIds = delegate?.coordinatorOpenWorkspaceIds() ?? []
        let items: [WorkspaceMenuItem] = entries.map { entry in
            let ws = store.get(ORef.workspace(entry.workspaceid))?.asWorkspace
            return WorkspaceMenuItem(
                workspaceId: entry.workspaceid,
                name: (ws?.name?.isEmpty == false ? ws!.name! : "Workspace"),
                icon: ws?.icon, color: ws?.color,
                isOpen: openWorkspaceIds.contains(entry.workspaceid),
                isCurrent: entry.workspaceid == workspaceId,
                hasSavedLayout: (ws?.meta[WorkspaceMenuItem.savedLayoutMetaKey] ?? nil) != nil
            )
        }
        delegate?.coordinatorDidUpdateWorkspaceList(items)
    }

    // MARK: - Loads

    private func loadWindow(_ id: String) async throws -> Window {
        let obj = try await store.load(ORef.window(id))
        guard let window = obj.asWindow else { throw WaveError.decoding("expected window for \(id)") }
        return window
    }

    private func loadWorkspace(_ id: String) async throws -> Workspace {
        let obj = try await store.load(ORef.workspace(id))
        guard let ws = obj.asWorkspace else { throw WaveError.decoding("expected workspace for \(id)") }
        return ws
    }

    private func loadTabSafe(_ id: String) async -> Tab? {
        if let cached = store.get(ORef.tab(id))?.asTab { return cached }
        // Restore race: just after a fresh wavesrv start the tab row can be briefly
        // unqueryable. A restored window must NEVER come up dead, so keep retrying with
        // backoff until the row resolves. The cache fast-path above means a normal tab
        // switch never hits this loop. The bound (≈10s of attempts) exists only so a
        // genuinely deleted tab can't hang forever — `activate` then falls back to a
        // default terminal so the window is still usable rather than blank.
        var delayMs: UInt64 = 100
        for _ in 0..<12 {
            if let loaded = (try? await store.load(ORef.tab(id)))?.asTab { return loaded }
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            delayMs = min(delayMs * 2, 1000)
        }
        return store.get(ORef.tab(id))?.asTab
    }

    private func loadFullConfig() async {
        let none: JSONValue? = nil
        let cfg: JSONValue? = try? await transport.call(
            command: WaveCommand.getFullConfig, data: none, route: nil, timeoutMs: nil
        )
        fullConfig = cfg
    }

    // MARK: - Settings (config read/write)

    /// Posted (object = this coordinator) after a `config` event re-pulls fullConfig, so
    /// the shared Settings window can refresh its controls from `currentSettings()`.
    public static let configReloadedNotification = Notification.Name("WaveAppCoordinatorConfigReloaded")

    /// Posted (object = the affected NSWindow) when a window's per-window appearance
    /// (gear popover) toggles transparency/blur, so the composition root re-dims that
    /// window's terminals' libghostty backgrounds. The window/frame layers are handled
    /// in-process by `WaveWindow.applyAppearance`; the terminals live in WaveTerminal,
    /// which the composition root (not WaveUI) can reach.
    public static let windowAppearanceChangedNotification = Notification.Name("WaveAppCoordinatorWindowAppearanceChanged")

    /// Posted by the gear popover's "Apply to All Windows" button. `userInfo` carries the
    /// appearance (transparent/blur/opacity); EVERY `WaveWindowController` observes it and
    /// applies it live to its own window. The originator also persists it to the global
    /// config, so the choice survives a restart.
    public static let applyAppearanceToAllNotification = Notification.Name("WaveAppCoordinatorApplyAppearanceToAll")

    private func notifyConfigReloaded() {
        NotificationCenter.default.post(name: Self.configReloadedNotification, object: self)
    }

    /// Read `<configHome>/settings.json` as text (whole file, base64 over the FileService
    /// RPC). Empty string when the file is missing/empty. Used by the raw config editor.
    public func readConfigFileText() async throws -> String {
        guard let configHome = config.configHome, !configHome.isEmpty else {
            throw WaveError.rpc("config home is not set")
        }
        return try await service.readConfigFile(configHome: configHome)
    }

    /// Write the whole `<configHome>/settings.json` (base64). The backend's filewatcher
    /// fires the `config` event afterwards, which this coordinator reloads — so live
    /// settings update without any extra plumbing.
    public func writeConfigFileText(_ text: String) async throws {
        guard let configHome = config.configHome, !configHome.isEmpty else {
            throw WaveError.rpc("config home is not set")
        }
        try await service.writeConfigFile(configHome: configHome, text: text)
    }

    /// The live `settings` map of the loaded fullConfig (the user-facing settings.json
    /// values), or empty if unloaded. The Settings window reads control values from here.
    public func currentSettings() -> [String: JSONValue] {
        return fullConfig?["settings"]?.objectValue ?? [:]
    }

    // MARK: Telemetry (forced off, no UI)

    /// Disable telemetry unless it is already explicitly `false`. Idempotent so the
    /// resulting `config` event cannot re-trigger a write (no loop). Pure → testable.
    static func shouldDisableTelemetry(_ settings: [String: JSONValue]) -> Bool {
        settings["telemetry:enabled"]?.boolValue != false
    }

    private func enforceTelemetryDisabled() {
        guard Self.shouldDisableTelemetry(currentSettings()) else { return }
        setConfigValue("telemetry:enabled", .bool(false))
    }

    // MARK: Web settings (defaulturl / openlinksinternally)

    /// `web:defaulturl` (homepage for a urlless new web block), with the Electron
    /// default as the fallback.
    static func webDefaultURL(from settings: [String: JSONValue]) -> String {
        let v = settings["web:defaulturl"]?.stringValue
        if let v, !v.isEmpty { return v }
        return "https://github.com/wavetermdev/waveterm"
    }

    /// `web:openlinksinternally` (default false, Electron `openLink`): true ⇒ a terminal
    /// hyperlink opens as a web pane; false ⇒ hand off to the system browser.
    static func shouldOpenLinksInternally(_ settings: [String: JSONValue]) -> Bool {
        settings["web:openlinksinternally"]?.boolValue ?? false
    }

    /// Inject `web:defaulturl` as the `url` of a web block that has no url/pinnedurl
    /// (the web widget ships `{view:"web"}` only). Non-web metas pass through unchanged.
    static func applyWebDefaults(toMeta meta: MetaMapType, settings: [String: JSONValue]) -> MetaMapType {
        guard meta["view"]?.stringValue == "web" else { return meta }
        let hasURL = (meta["url"]?.stringValue?.isEmpty == false)
            || (meta["pinnedurl"]?.stringValue?.isEmpty == false)
        guard !hasURL else { return meta }
        var out = meta
        out["url"] = .string(webDefaultURL(from: settings))
        return out
    }

    // MARK: Terminal themes (term:theme, per pane)

    /// The default term theme name (`frontend/app/view/term/termutil.ts` `DefaultTermTheme`).
    static let defaultTermThemeName = "default-dark"

    /// Resolve a pane's theme name: the block's own `term:theme` meta, else the global
    /// `term:theme` setting, else the default (Electron term-model resolution). Pure.
    public nonisolated static func resolveTermThemeName(blockMeta: [String: JSONValue]?, settings: [String: JSONValue]) -> String {
        if let b = blockMeta?["term:theme"]?.stringValue, !b.isEmpty { return b }
        if let g = settings["term:theme"]?.stringValue, !g.isEmpty { return g }
        return defaultTermThemeName
    }

    /// Parse `fullConfig.termthemes` into the colour map the renderer applies. Pure → the
    /// parse is unit-testable from a config blob.
    static func parseTermThemes(_ config: JSONValue?) -> [String: TermThemeColors] {
        guard let themes = config?["termthemes"]?.objectValue else { return [:] }
        var out: [String: TermThemeColors] = [:]
        for (name, value) in themes {
            guard case .object = value else { continue }
            func hex(_ key: String) -> String? {
                let s = value[key]?.stringValue
                return (s?.isEmpty == false) ? s : nil
            }
            let ansiKeys = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
                            "brightBlack", "brightRed", "brightGreen", "brightYellow",
                            "brightBlue", "brightMagenta", "brightCyan", "brightWhite"]
            out[name] = TermThemeColors(
                name: name,
                displayName: hex("display:name") ?? name,
                order: value["display:order"]?.doubleValue ?? 0,
                ansi: ansiKeys.map { hex($0) },
                foreground: hex("foreground"),
                background: hex("background"),
                cursor: hex("cursor"),
                selection: hex("selectionBackground"))
        }
        return out
    }

    /// The parsed term themes from the live fullConfig (the renderer's source).
    public func currentTermThemes() -> [String: TermThemeColors] {
        Self.parseTermThemes(fullConfig)
    }

    /// Term theme entries for the per-pane "Themes" submenu, ordered by `display:order`.
    public func termThemeMenuItems() -> [TermThemeMenuItem] {
        currentTermThemes().values
            .sorted { ($0.order, $0.displayName) < ($1.order, $1.displayName) }
            .map { TermThemeMenuItem(name: $0.name, displayName: $0.displayName) }
    }

    /// Derive the tab-bar position from a settings map. Anything other than the explicit
    /// "left" (including a missing key or an unknown value) falls back to "top". Pure, so
    /// the mapping is unit-testable without a transport.
    static func deriveTabBarPosition(_ settings: [String: JSONValue]) -> String {
        settings["app:tabbar"]?.stringValue == TabBarPosition.left ? TabBarPosition.left : TabBarPosition.top
    }

    /// Push the current `app:tabbar` position to the delegate (chrome re-orients).
    private func publishTabBarPosition() {
        delegate?.coordinatorDidUpdateTabBarPosition(Self.deriveTabBarPosition(currentSettings()))
    }

    /// Persist a single settings key via the typed `setconfig` RPC. A `nil` value
    /// deletes the key (sent as JSON null, the backend's delete sentinel). The backend
    /// broadcasts `config`, which re-pulls fullConfig and notifies the Settings window —
    /// so we do not optimistically mutate `fullConfig` here.
    public func setConfigValue(_ key: String, _ value: JSONValue?) {
        Task {
            do {
                try await self.service.setConfig([key: value ?? .null])
            } catch {
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    // MARK: - Terminal scrollback buffers (Settings overview)

    /// All stored term scrollback buffers (every workspace + orphaned zones).
    public func termScrollbackList() async throws -> [TermScrollbackEntry] {
        try await service.termScrollbackList()
    }

    /// Truncate one block's persisted term buffer.
    public func termClearBuffer(blockId: String) async throws {
        try await service.termClearBuffer(blockId: blockId)
    }

    /// Settings "Go to" action: switch to the tab (when needed) and focus the
    /// pane. `LayoutTreeView.focusBlock` stores a pending focus for blocks that
    /// have not mounted yet, so focusing right after the switch is safe.
    public func navigateToBlock(tabId: String, blockId: String) {
        if tabId == activeTabId {
            delegate?.coordinatorRequestFocusBlock(blockId)
            return
        }
        Task { @MainActor in
            await self.activate(tabId: tabId, isInitial: false)
            self.delegate?.coordinatorRequestFocusBlock(blockId)
        }
    }

    // MARK: - Widgets (right-edge launcher bar)

    /// The visible widget-bar buttons for the current config, sorted by `display:order`
    /// ascending and excluding hidden widgets. Pure pass-through to `parseWidgets` so
    /// the bar is populated from the same fullConfig the chrome already loads.
    /// Widget views the native app actually RENDERS today. Widgets for other views
    /// would only show the placeholder, so they're hidden from the launcher until their
    /// native providers land (preview/sysinfo/processviewer).
    static let implementedWidgetViews: Set<String> = ["term", "web"]

    public func widgetItems() -> [WidgetItem] {
        Self.parseWidgets(fullConfig).filter {
            Self.implementedWidgetViews.contains($0.blockDefMeta["view"]?.stringValue ?? "term")
        }
    }

    /// Parse the `widgets` map of a fullConfig blob into ordered launcher items. Kept a
    /// PURE function of the config (no transport/store) so it is unit-testable. Skips a
    /// widget whose `blockdef.meta` is missing/empty (it could not create a block) and
    /// excludes hidden widgets; the result is sorted by `display:order` ascending.
    static func parseWidgets(_ config: JSONValue?) -> [WidgetItem] {
        guard let widgets = config?["widgets"]?.objectValue else { return [] }
        var items: [WidgetItem] = []
        for (_, value) in widgets {
            guard case .object = value else { continue }
            guard let meta = value["blockdef"]?["meta"]?.objectValue, !meta.isEmpty else { continue }
            let hidden = value["display:hidden"]?.boolValue ?? false
            if hidden { continue }
            items.append(WidgetItem(
                icon: value["icon"]?.stringValue,
                label: value["label"]?.stringValue ?? value["description"]?.stringValue,
                color: value["color"]?.stringValue,
                blockDefMeta: meta,
                order: value["display:order"]?.doubleValue ?? 0,
                hidden: hidden,
                magnified: value["magnified"]?.boolValue ?? false))
        }
        return items.sorted { $0.order < $1.order }
    }

    /// Create a block from a widget BlockDef in the active tab (widget-bar click).
    /// Uses the wsh CreateBlock path (no target), which queues an `insert` layout action
    /// so the new pane is tiled like Cmd-N (GUARDS §L). Unlike `createTermBlock` there is
    /// no ensure-connect step: a widget always opens on the local machine.
    public func createWidgetBlock(meta: MetaMapType, magnified: Bool) {
        guard let activeTabId else { return }
        // A web widget ships `{view:"web"}` with no url; open `web:defaulturl` as its
        // homepage so the new pane isn't blank (Electron `homepageUrl`).
        let meta = Self.applyWebDefaults(toMeta: meta, settings: currentSettings())
        let data = CommandCreateBlockData(
            tabid: activeTabId, blockdef: BlockDef(meta: meta),
            magnified: magnified, focused: true)
        Task {
            do {
                let newRef = try await self.service.createBlockWsh(data)
                self.delegate?.coordinatorRequestFocusBlock(newRef.oid)
            } catch {
                self.delegate?.coordinatorDidFail(error)
            }
        }
    }

    /// Resolve the local-machine display name (honoring the `conn:localhostdisplayname`
    /// setting from fullConfig, else `user@host`) and seed the connection store with the
    /// current `connstatus` snapshot. Best-effort: a missing setting / failed RPC leaves
    /// the defaults in place.
    private func seedConnections() async {
        if let name = localHostDisplayNameFromConfig() {
            connectionStore.setLocalDisplayName(name)
        }
        if let statuses = try? await service.connStatus() {
            connectionStore.seed(statuses)
        }
    }

    /// `conn:localhostdisplayname` from the loaded fullConfig `settings` map, if set.
    /// Mirrors Electron's `getSettingsKeyAtom("conn:localhostdisplayname")`.
    private func localHostDisplayNameFromConfig() -> String? {
        guard let settings = fullConfig?["settings"],
              let value = settings["conn:localhostdisplayname"]?.stringValue,
              !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Auth key (GUARDS §P)

    /// 32 random bytes, std base64 — a fresh key per launch.
    static func generateAuthKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return WaveBase64.encode(Data(bytes))
    }
}
