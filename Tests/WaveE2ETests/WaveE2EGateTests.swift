// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveE2ETests — the real-wavesrv GATES (docs/E2E.md "Gates").
//
// These drive the REAL `WaveTransportClient` + `ObjectStore` + `WaveCommands`
// against a real isolated `wavesrv` (spawned by `WaveServerProcess`). NOTHING is
// mocked here — not the server, its DB/filestore, nor the wps broker (E2E.md
// "What is NOT mocked"). The connected client attaches to the harness's already
// running server via the `_configureServerForTesting` test seam so the harness
// keeps ownership of the `Process` (one server, clean teardown).
//
// Gates implemented in this file:
//   E2E-1 Transport  — GUARDS §A (auth header, ?stableid, routeannounce, ASYM
//                      framing, reqid/resid round-trip, ping->pong past 15s,
//                      auto-reconnect + re-announce + re-subscribe) and §P
//                      (spawn + WAVESRV-ESTART, via WaveServerProcess).
//   E2E-2 Store      — GUARDS §B (apply inline WebReturnType.updates; live
//                      waveobj:update by oref-string scope; version-guarded merge
//                      drops stale / out-of-order updates).
//   E2E-3 Commands   — GUARDS §C (SetActiveTab is the controller-start trigger;
//                      honor CloseTab's {closewindow,newactivetabid}; refuse to
//                      move the LAST tab out of a workspace) plus create / reorder
//                      / move across the object graph.
//
// E2E-4 (terminal byte-stream fuzz), E2E-5 (layout round-trip), E2E-6 (web), and
// E2E-7 (chrome/snapshot) are explicitly OUT OF SCOPE for this file — see the
// "Gates not expressed here" note at the bottom.

import Foundation
import XCTest
@testable import WaveCore
@testable import WaveProtocol
@testable import WaveStore
@testable import WaveCommands

// MARK: - Connected client environment

/// A fully connected native client wired to a real isolated `wavesrv`: the real
/// `WaveTransportClient` attached to the harness server, an `ObjectStore`, and
/// `WaveCommands`, plus the PROTOCOL §7 bootstrap graph (client/window/workspace/
/// tab). Owns nothing the harness owns — `shutdown()` disconnects the WS and
/// terminates the server.
final class WaveTestEnv: @unchecked Sendable {
    let server: WaveServerProcess
    let transport: WaveTransportClient
    let store: ObjectStore
    let commands: WaveCommands
    let wsFactory: RecordingWSChannelFactory

    let clientId: String
    let windowId: String
    let workspaceId: String
    let activeTabId: String

    private let activeTabBox: E2EBox<String>

    private init(
        server: WaveServerProcess, transport: WaveTransportClient, store: ObjectStore,
        wsFactory: RecordingWSChannelFactory, commands: WaveCommands, activeTabBox: E2EBox<String>,
        clientId: String, windowId: String, workspaceId: String, activeTabId: String
    ) {
        self.server = server
        self.transport = transport
        self.store = store
        self.wsFactory = wsFactory
        self.commands = commands
        self.activeTabBox = activeTabBox
        self.clientId = clientId
        self.windowId = windowId
        self.workspaceId = workspaceId
        self.activeTabId = activeTabId
    }

    /// Reflect a new active tab in the `UIContext` handed to subsequent commands
    /// (GUARDS §C: the service dispatcher injects this into `UIContext` params).
    func setUIContextActiveTab(_ tabId: String) { activeTabBox.set(tabId) }

    /// Boot a real server (or `XCTSkip`) and a connected client (PROTOCOL §7).
    static func boot() async throws -> WaveTestEnv {
        // Spawning is synchronous (blocks on the ESTART semaphore internally).
        let server = try WaveServerProcess.startOrSkip()
        do {
            return try await connect(to: server)
        } catch {
            server.terminate()
            throw error
        }
    }

    /// PROTOCOL §7 init sequence against an already-running server.
    private static func connect(to server: WaveServerProcess) async throws -> WaveTestEnv {
        let wsFactory = RecordingWSChannelFactory()
        let transport = WaveTransportClient(
            wavesrvPath: server.binaryPath,
            channelFactory: wsFactory,
            session: .shared)
        // Make GUARDS §A auto-reconnect instant for deterministic tests.
        transport.reconnectDelayProvider = { _ in 0 }
        // Attach to the harness's running server (HTTP works immediately).
        transport._configureServerForTesting(addrs: server.addrs, authKey: server.authKey)

        // §7.2: HTTP GetClientData -> clientId + windowids (proves §0 service +
        // §A auth header over HTTP, before the WS is open).
        let clientRtn = try await transport.callService(
            WebCallType(service: "client", method: "GetClientData", args: []))
        if let err = clientRtn.error, !err.isEmpty {
            throw WaveError.rpc("GetClientData: \(err)")
        }
        guard
            let data = clientRtn.data, !data.isNull,
            let clientId = data["oid"]?.stringValue, !clientId.isEmpty,
            let windowId = data["windowids"]?.arrayValue?.first?.stringValue, !windowId.isEmpty
        else {
            throw WaveError.decoding(
                "GetClientData returned no client/window: \(String(describing: clientRtn.data))")
        }

        // §7.3-4: open WS ?stableid=window:<id> with X-AuthKey, ping/pong, then
        // routeannounce to $control BEFORE any routed call (all inside connect()).
        try await transport.connect(routeId: WaveRoute.window(windowId))

        let store = ObjectStore(transport: transport)

        // §7.6: load client -> window -> workspace -> tab.
        guard let window = try await store.load(.window(windowId)).asWindow else {
            throw WaveError.decoding("loaded object for \(windowId) is not a window")
        }
        guard !window.workspaceid.isEmpty else {
            throw WaveError.decoding("window \(windowId) has no workspaceid")
        }
        guard let ws = try await store.load(.workspace(window.workspaceid)).asWorkspace else {
            throw WaveError.decoding("loaded object for \(window.workspaceid) is not a workspace")
        }
        guard !ws.activetabid.isEmpty else {
            throw WaveError.decoding("workspace \(window.workspaceid) has no active tab")
        }
        _ = try await store.load(.tab(ws.activetabid))

        let activeTabBox = E2EBox(ws.activetabid)
        let commands = WaveCommands(transport: transport, store: store) {
            UIContext(windowid: windowId, activetabid: activeTabBox.current)
        }
        return WaveTestEnv(
            server: server, transport: transport, store: store, wsFactory: wsFactory,
            commands: commands, activeTabBox: activeTabBox,
            clientId: clientId, windowId: windowId,
            workspaceId: window.workspaceid, activeTabId: ws.activetabid)
    }

    func shutdown() {
        transport.disconnect()
        server.terminate()
    }
}

// MARK: - Real, force-droppable WS channel (for GUARDS §A reconnect)

/// Wraps the REAL `URLSessionWSChannel` so a test can forcibly drop the live
/// socket. Not a mock — every byte flows over the real WebSocket to the real
/// wavesrv; we only retain a handle so we can close it mid-stream.
final class RecordingWSChannel: WSChannel, @unchecked Sendable {
    private let inner: WSChannel
    init(inner: WSChannel) { self.inner = inner }
    func send(_ data: Data) async throws { try await inner.send(data) }
    func receive() async throws -> Data { try await inner.receive() }
    func close() { inner.close() }
    /// Simulate a network drop: closing the underlying task makes the transport's
    /// receive loop throw -> handleConnectionLost -> auto-reconnect (GUARDS §A).
    func forceDrop() { inner.close() }
}

/// Vends `RecordingWSChannel`s over the real `URLSessionWSChannelFactory`,
/// retaining the most-recent one and counting connects (a reconnect opens a NEW
/// socket, so `connectCount` increments).
final class RecordingWSChannelFactory: WSChannelFactory, @unchecked Sendable {
    private let inner: URLSessionWSChannelFactory
    private let lock = NSLock()
    private var channels: [RecordingWSChannel] = []

    init(session: URLSession = .shared) {
        self.inner = URLSessionWSChannelFactory(session: session)
    }

    var connectCount: Int { lock.lock(); defer { lock.unlock() }; return channels.count }
    var latest: RecordingWSChannel? { lock.lock(); defer { lock.unlock() }; return channels.last }

    func connect(url: URL, authKey: String) async throws -> WSChannel {
        let real = try await inner.connect(url: url, authKey: authKey)
        let rec = RecordingWSChannel(inner: real)
        lock.lock(); channels.append(rec); lock.unlock()
        return rec
    }
}

// MARK: - Small helpers

/// Thread-safe box for capturing values inside `@Sendable` handlers.
final class E2EBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ initial: T) { self.value = initial }
    var current: T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: T) { lock.lock(); defer { lock.unlock() }; value = newValue }
}

/// Base class for the real-wavesrv gates: boots a server + connected client in
/// `setUp`, tears both down in `tearDown`. Tests `XCTSkip` (not fail) when no
/// wavesrv binary is configured.
class WaveE2ECase: XCTestCase {
    var env: WaveTestEnv!
    /// Subscriptions kept alive for the duration of a test (deinit cancels them).
    var liveTokens: [SubscriptionToken] = []

    override func setUp() async throws {
        try await super.setUp()
        env = try await WaveTestEnv.boot()
    }

    override func tearDown() async throws {
        liveTokens.removeAll()
        env?.shutdown()
        env = nil
        try await super.tearDown()
    }

    /// Poll `condition` until true or `timeout`; fail the test on timeout.
    func waitUntil(
        _ message: String, timeout: TimeInterval = 12,
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timeout (\(timeout)s) waiting for: \(message)", file: file, line: line)
    }

    /// Reload a workspace straight from the server (HTTP GetObject), bypassing any
    /// stale cache view, and return it.
    func reloadWorkspace(_ id: String) async throws -> Workspace {
        guard let ws = try await env.store.load(.workspace(id)).asWorkspace else {
            throw WaveError.decoding("object \(id) is not a workspace")
        }
        return ws
    }

    func reloadTab(_ id: String) async throws -> Tab {
        guard let tab = try await env.store.load(.tab(id)).asTab else {
            throw WaveError.decoding("object \(id) is not a tab")
        }
        return tab
    }
}

// MARK: - E2E-1 Transport (GUARDS §A / §P)

final class E2E1TransportTests: WaveE2ECase {

    /// Connect + announce + HTTP + a wsh reqid/resid round-trip (GUARDS §A).
    func testConnectAnnounceAndRoundTrip() async throws {
        XCTAssertTrue(env.transport.isConnected, "transport should be connected after boot")
        XCTAssertEqual(env.transport.routeId, WaveRoute.window(env.windowId),
                       "must announce window:<id> as the route (GUARDS §A ?stableid + routeannounce)")
        XCTAssertNotNil(env.transport.addrs, "addrs must be discovered (GUARDS §P ESTART)")
        XCTAssertFalse(env.clientId.isEmpty, "GetClientData over HTTP must succeed (GUARDS §A auth header)")

        // wsh round-trip: SetMeta (callVoid) then GetMeta (call) — proves outbound
        // ASYM framing + reqid/resid matching against the real server.
        let oref = ORef.window(env.windowId)
        let marker = "e2e-\(UUID().uuidString)"
        try await env.commands.setMeta(oref, meta: ["e2e:marker": .string(marker)])
        let meta = try await env.commands.getMeta(oref)
        XCTAssertEqual(meta["e2e:marker"]?.stringValue, marker,
                       "wsh SetMeta/GetMeta round-trip must reflect our value (GUARDS §A)")
    }

    /// Ping->pong keeps the socket alive past the server's 15s read deadline:
    /// after idling >15s we must STILL be on the same connection (no reconnect)
    /// and a fresh round-trip must work (GUARDS §A `pkg/web/ws.go:148-177`).
    func testPingPongKeepsSocketAlivePast15s() async throws {
        let connectsBefore = env.wsFactory.connectCount
        XCTAssertEqual(connectsBefore, 1, "exactly one socket so far")

        // Idle past the 15s read deadline. If we failed to pong, the server would
        // drop us and the transport would auto-reconnect (connectCount would rise).
        try await Task.sleep(nanoseconds: 17 * 1_000_000_000)

        XCTAssertTrue(env.transport.isConnected, "socket must survive past 15s via ping->pong")
        XCTAssertEqual(env.wsFactory.connectCount, connectsBefore,
                       "no reconnect should have occurred (ping/pong kept it alive)")

        // Confirm the long-lived socket is still usable with a real round-trip.
        let oref = ORef.window(env.windowId)
        let marker = "alive-\(UUID().uuidString)"
        try await env.commands.setMeta(oref, meta: ["e2e:alive": .string(marker)])
        let meta = try await env.commands.getMeta(oref)
        XCTAssertEqual(meta["e2e:alive"]?.stringValue, marker,
                       "round-trip must still work after idling past 15s")
    }

    /// Force-drop the live socket and assert auto-reconnect AND re-announce AND
    /// re-subscribe: a waveobj:update delivered AFTER the drop proves the route
    /// was re-announced and the subscription re-registered (GUARDS §A).
    func testForceDropAutoReconnectReannounceResubscribe() async throws {
        let tabId = env.activeTabId
        let latestName = E2EBox<String?>(nil)
        // Subscribe BEFORE the drop; the transport must re-register this after
        // reconnect (subscriptions are per-connection, GUARDS §A).
        let token = env.store.subscribe(.tab(tabId)) { obj in
            latestName.set(obj?.asTab?.name)
        }
        liveTokens.append(token)

        let connectsBefore = env.wsFactory.connectCount
        XCTAssertNotNil(env.wsFactory.latest, "should have a live channel to drop")
        env.wsFactory.latest?.forceDrop()

        // Auto-reconnect must open a NEW socket and come back connected.
        try await waitUntil("auto-reconnect opens a new socket") {
            self.env.wsFactory.connectCount > connectsBefore
        }
        try await waitUntil("transport reconnects") { self.env.transport.isConnected }

        // Give the re-sent routeannounce + eventsub time to register server-side.
        try await Task.sleep(nanoseconds: 400_000_000)

        // Mutate the tab name over wsh (no inline updates -> the change can ONLY
        // reach us via a waveobj:update event, which requires the route to have
        // been re-announced and the subscription re-registered).
        let newName = "reconnected-\(UUID().uuidString.prefix(8))"
        try await env.commands.updateTabName(tabId: tabId, newName: String(newName))

        try await waitUntil("waveobj:update delivered after reconnect (re-announce + re-subscribe)") {
            self.env.store.get(.tab(tabId))?.asTab?.name == String(newName)
        }
        XCTAssertEqual(latestName.current, String(newName),
                       "observer should have fired via the re-subscribed event")
    }
}

// MARK: - E2E-2 Object store (GUARDS §B)

final class E2E2StoreTests: WaveE2ECase {

    /// GUARDS §B: the inline `WebReturnType.updates` from a service mutation are
    /// applied to the SAME cache — visible WITHOUT any explicit reload.
    func testInlineUpdatesAppliedFromServiceResponse() async throws {
        let newTabId = try await env.commands.createTab(
            workspaceId: env.workspaceId, tabName: "inline-update-tab", activateTab: true)
        XCTAssertFalse(newTabId.isEmpty)

        // No reload: these reads hit the cache only. They are populated solely by
        // the inline updates applied during createTab (GUARDS §B).
        let cachedWorkspace = env.store.get(.workspace(env.workspaceId))?.asWorkspace
        XCTAssertNotNil(cachedWorkspace, "workspace must be in cache from inline updates")
        XCTAssertTrue(cachedWorkspace?.tabids.contains(newTabId) ?? false,
                      "new tab id must appear in the workspace tabids via inline updates")
        XCTAssertNotNil(env.store.get(.tab(newTabId))?.asTab,
                        "new tab object must be cached via inline updates")
    }

    /// GUARDS §B: a live `waveobj:update` event (scope = the oref STRING) updates
    /// the cache. UpdateTabName is wsh-only (no inline updates), so the new name
    /// can reach us ONLY through the subscribed event path.
    func testWaveObjUpdateEventUpdatesCache() async throws {
        let tabId = env.activeTabId
        let token = env.store.subscribe(.tab(tabId)) { _ in }
        liveTokens.append(token)
        // Let the eventsub register before we mutate.
        try await Task.sleep(nanoseconds: 250_000_000)

        let newName = "evented-\(UUID().uuidString.prefix(8))"
        try await env.commands.updateTabName(tabId: tabId, newName: String(newName))

        try await waitUntil("waveobj:update event updates the cache") {
            self.env.store.get(.tab(tabId))?.asTab?.name == String(newName)
        }
    }

    /// GUARDS §B: version-guarded merge. An equal-or-older version is dropped; a
    /// strictly newer version is applied. Out-of-order delivery is normal, so the
    /// guard must not flicker back to stale state.
    func testVersionGuardedMerge() async throws {
        let tabId = env.activeTabId
        let current = try await reloadTab(tabId)
        let baseVersion = current.version

        // Older version with a different name -> MUST be dropped.
        var stale = current
        stale.version = baseVersion - 1
        stale.name = "STALE-SHOULD-BE-DROPPED"
        XCTAssertFalse(env.store.merge(.tab(stale)), "older-version merge must be dropped (GUARDS §B)")
        XCTAssertEqual(env.store.get(.tab(tabId))?.asTab?.name, current.name,
                       "cache must not regress to the stale value")

        // Equal version -> also dropped (guard is `<=`).
        var sameVersion = current
        sameVersion.version = baseVersion
        sameVersion.name = "SAME-VERSION-SHOULD-BE-DROPPED"
        XCTAssertFalse(env.store.merge(.tab(sameVersion)), "equal-version merge must be dropped (GUARDS §B)")

        // Strictly newer -> applied.
        var newer = current
        newer.version = baseVersion + 100
        newer.name = "NEWER-APPLIED"
        XCTAssertTrue(env.store.merge(.tab(newer)), "newer-version merge must be applied (GUARDS §B)")
        XCTAssertEqual(env.store.get(.tab(tabId))?.asTab?.name, "NEWER-APPLIED")

        // Out-of-order applyUpdates with an older version -> ignored (same guard
        // path the waveobj:update events flow through).
        var ooo = current
        ooo.version = baseVersion + 1
        ooo.name = "OUT-OF-ORDER-OLDER"
        let update = WaveObjUpdate(
            updatetype: updateTypeUpdate, otype: OType.tab, oid: tabId,
            obj: try JSONValue.encode(ooo))
        env.store.applyUpdates([update])
        XCTAssertEqual(env.store.get(.tab(tabId))?.asTab?.name, "NEWER-APPLIED",
                       "out-of-order older update must be ignored (GUARDS §B)")
    }
}

// MARK: - E2E-3 Commands (GUARDS §C)

final class E2E3CommandsTests: WaveE2ECase {

    /// Full lifecycle across the object graph: create workspace + tabs, reorder,
    /// SetActiveTab (the §C controller-start trigger), MoveTab across workspaces,
    /// then CloseTab honoring its return.
    func testCreateReorderSetActiveMoveCloseTabs() async throws {
        // New workspace (comes with one starter tab).
        let wsA = try await env.commands.createWorkspace(name: "E2E-A")
        XCTAssertFalse(wsA.isEmpty)
        let starterTab = try await reloadWorkspace(wsA).activetabid
        XCTAssertFalse(starterTab.isEmpty)

        // Add two more tabs.
        let t2 = try await env.commands.createTab(workspaceId: wsA, tabName: "t2", activateTab: false)
        let t3 = try await env.commands.createTab(workspaceId: wsA, tabName: "t3", activateTab: false)

        var wsAState = try await reloadWorkspace(wsA)
        XCTAssertEqual(Set(wsAState.tabids), Set([starterTab, t2, t3]),
                       "workspace should contain all three tabs")

        // Reorder via UpdateWorkspaceTabIds (a permutation of the current ids).
        let reordered = [t3, starterTab, t2]
        try await env.commands.updateWorkspaceTabIds(workspaceId: wsA, tabIds: reordered)
        wsAState = try await reloadWorkspace(wsA)
        XCTAssertEqual(wsAState.tabids, reordered, "tab order must persist (UpdateWorkspaceTabIds)")

        // SetActiveTab — GUARDS §C: the trigger that starts the active tab's
        // controllers. Assert the backend recorded the active tab.
        try await env.commands.setActiveTab(workspaceId: wsA, tabId: t2)
        env.setUIContextActiveTab(t2)
        wsAState = try await reloadWorkspace(wsA)
        XCTAssertEqual(wsAState.activetabid, t2, "SetActiveTab must change the active tab (GUARDS §C)")

        // MoveTab t3 to a second workspace.
        let wsB = try await env.commands.createWorkspace(name: "E2E-B")
        try await env.commands.moveTab(sourceWorkspaceId: wsA, destWorkspaceId: wsB, tabId: t3)
        let wsAAfterMove = try await reloadWorkspace(wsA)
        let wsBAfterMove = try await reloadWorkspace(wsB)
        XCTAssertFalse(wsAAfterMove.tabids.contains(t3), "t3 must leave the source workspace")
        XCTAssertTrue(wsBAfterMove.tabids.contains(t3), "t3 must arrive in the dest workspace")

        // CloseTab t2 — GUARDS §C: honor the return. wsA still has >1 tab, so the
        // window must NOT close and a new active tab id must be provided.
        let result = try await env.commands.closeTab(workspaceId: wsA, tabId: t2)
        XCTAssertFalse(result.closewindow, "closing a non-last tab must not close the window")
        let wsAAfterClose = try await reloadWorkspace(wsA)
        XCTAssertFalse(wsAAfterClose.tabids.contains(t2), "closed tab must be gone")
        XCTAssertFalse(result.newactivetabid.isEmpty, "a replacement active tab must be returned")
        XCTAssertTrue(wsAAfterClose.tabids.contains(result.newactivetabid),
                      "the returned newactivetabid must be one of the remaining tabs (GUARDS §C)")
    }

    /// GUARDS §C [MUST-NOT]: moving the LAST tab out of a workspace is rejected.
    /// A freshly created workspace has exactly one tab, so the move must throw.
    func testMoveLastTabRejected() async throws {
        let wsC = try await env.commands.createWorkspace(name: "E2E-C")
        let wsCState = try await reloadWorkspace(wsC)
        let onlyTab = wsCState.activetabid
        XCTAssertFalse(onlyTab.isEmpty)
        XCTAssertEqual(wsCState.tabids.count, 1, "precondition: exactly one tab")

        do {
            try await env.commands.moveTab(
                sourceWorkspaceId: wsC, destWorkspaceId: env.workspaceId, tabId: onlyTab)
            XCTFail("moving the last tab out of a workspace must be rejected (GUARDS §C)")
        } catch let error as WaveError {
            guard case .rpc = error else {
                return XCTFail("expected WaveError.rpc for last-tab move, got \(error)")
            }
        }

        // The tab must still be in its original workspace (no partial move).
        let wsCAfter = try await reloadWorkspace(wsC)
        XCTAssertTrue(wsCAfter.tabids.contains(onlyTab),
                      "rejected move must leave the workspace unchanged")
    }
}
