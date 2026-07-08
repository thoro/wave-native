// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// E2E-5 (docs/E2E.md "Layout") — drives a REAL wavesrv (no mocks of broker/DB/pty)
// and proves PROTOCOL.md §6 + GUARDS §L end to end:
//
//   1. one terminal → split to 2×2 → resize → close one; reload the client and
//      assert the `LayoutState` tree round-trips through wavesrv (real
//      UpdateObject persist + real GetObject reload).
//   2. add a block from ANOTHER route (wsh `CreateBlockCommand`) and assert it
//      appears in the local tree via the `pendingbackendactions` apply-and-clear
//      protocol, AND that the cleared queue is persisted back to wavesrv.
//
// The layout edits go through the production `LayoutModel`/`LayoutReducer`; the
// persist + reload + event delivery go through the production `WaveTransportClient`
// + `ObjectStore` against the live backend. The shared real-wavesrv harness
// (`WaveServerProcess.startOrSkip`) is reused; all other helpers here are
// file-private to avoid colliding with the other gates' test stubs.

import XCTest
import WaveCore
@testable import WaveProtocol
import WaveStore
import WaveCommands
import WaveLayout

final class WaveLayoutE2ETests: XCTestCase {

    private var server: WaveServerProcess!
    private var transport: WaveTransportClient!
    private var store: ObjectStore!
    private var commands: WaveCommands!
    private var bridge: LayoutE2EUpdatesBridge!

    private var windowId = ""
    private var workspaceId = ""
    private var tabId = ""
    private var layoutORef = ORef(otype: "", oid: "")

    // MARK: - Setup / teardown (real wavesrv, PROTOCOL.md §7 init prefix)

    override func setUp() async throws {
        // Skips with a clear reason when no wavesrv binary is available
        // (docs/E2E.md CI builds + exports one). This is an environment
        // prerequisite, not a masked assertion failure.
        server = try WaveServerProcess.startOrSkip()

        transport = WaveTransportClient(wavesrvPath: server.binaryPath)
        transport.reconnectDelayProvider = { _ in 0 } // instant reconnect in tests
        store = ObjectStore(transport: transport)
        bridge = LayoutE2EUpdatesBridge(store: store)
        transport.updatesDelegate = bridge // GUARDS §B: inline updates → cache

        // Use the already-spawned real process; keep the harness's Process handle
        // for teardown. This configures the HTTP client + X-AuthKey (GUARDS §A).
        transport._configureServerForTesting(addrs: server.addrs, authKey: server.authKey)

        // §7.2 GetClientData → windowId (server bootstrap ran at startup).
        let clientData = try await transport.callService(
            WebCallType(service: "client", method: "GetClientData", uicontext: nil, args: []))
        let cdata = try XCTUnwrap(clientData.data, "GetClientData returned no data")
        windowId = try XCTUnwrap(cdata["windowids"]?.arrayValue?.first?.stringValue, "client has no windows")

        // §7.3/§7.4 connect ws ?stableid=window:<id> + routeannounce.
        try await transport.connect(routeId: WaveRoute.window(windowId))

        // §7.6 window → workspace → active tab → layout oref.
        let windowObj = try await store.load(.window(windowId))
        let window = try XCTUnwrap(windowObj.asWindow)
        let workspaceObj = try await store.load(.workspace(window.workspaceid))
        let workspace = try XCTUnwrap(workspaceObj.asWorkspace)
        workspaceId = workspace.oid
        tabId = workspace.activetabid.isEmpty ? try XCTUnwrap(workspace.tabids.first) : workspace.activetabid
        let tabObj = try await store.load(.tab(tabId))
        let tab = try XCTUnwrap(tabObj.asTab)
        layoutORef = try XCTUnwrap(tab.layoutStateORef, "tab \(tabId) has no layoutstate oref")

        let captureWindowId = windowId
        let captureTabId = tabId
        commands = WaveCommands(transport: transport, store: store, uiContext: {
            UIContext(windowid: captureWindowId, activetabid: captureTabId)
        })
    }

    override func tearDown() async throws {
        transport?.disconnect()
        server?.terminate()
        server = nil
        transport = nil
        store = nil
        commands = nil
        bridge = nil
    }

    // MARK: - E2E-5.1 — one terminal → 2×2 → resize → close one → reload round-trip

    func testLayoutRoundTripsThroughWavesrv() async throws {
        // Four real terminal blocks (HTTP service CreateBlock → blocks persisted in
        // the wavesrv DB and added to the tab). The service path does not queue a
        // layout action; the client inserts them into the layout locally.
        let b1 = try await commands.createBlock(tabId: tabId, blockDef: Self.termBlockDef())
        let b2 = try await commands.createBlock(tabId: tabId, blockDef: Self.termBlockDef())
        let b3 = try await commands.createBlock(tabId: tabId, blockDef: Self.termBlockDef())
        let b4 = try await commands.createBlock(tabId: tabId, blockDef: Self.termBlockDef())

        let model = LayoutModel(
            layoutORef: layoutORef, transport: transport, store: store,
            windowId: windowId, tabId: tabId)
        model.persistDebounceMs = 100_000 // persist only on explicit flush
        try await model.start()

        // Start from a known-empty tree so assertions are independent of any
        // starter layout the backend may have seeded.
        model.dispatch(.clearTree)
        // one terminal …
        model.dispatch(.insertNode(node: LayoutTree.newLeaf(blockId: b1)))
        // … split to 2×2 (a row of two columns):
        //   row[ b1 , b2 ]  →  row[ col[b1,b3] , col[b2,b4] ]
        model.dispatch(.splitHorizontal(
            targetNodeId: try nodeId(model, b1), newNode: LayoutTree.newLeaf(blockId: b2), position: .after))
        model.dispatch(.splitVertical(
            targetNodeId: try nodeId(model, b1), newNode: LayoutTree.newLeaf(blockId: b3), position: .after))
        model.dispatch(.splitVertical(
            targetNodeId: try nodeId(model, b2), newNode: LayoutTree.newLeaf(blockId: b4), position: .after))

        XCTAssertEqual(Set(leafBlockIds(model)), Set([b1, b2, b3, b4]), "2×2 grid should have all four leaves")

        // resize one pane (single-op resize sets the node size directly).
        model.dispatch(.resizeNode([ResizeOperation(nodeId: try nodeId(model, b1), size: 30)]))
        XCTAssertEqual(LayoutTree.findNodeByBlockId(model.currentState().rootNode, blockId: b1)?.size, 30)

        // close one pane: delete its layout node AND delete the backing block.
        model.dispatch(.deleteNode(nodeId: try nodeId(model, b4)))
        try await commands.deleteBlock(b4)
        XCTAssertEqual(Set(leafBlockIds(model)), Set([b1, b2, b3]), "closing a pane removes exactly that leaf")

        // GUARDS §L: persist the WHOLE LayoutState object to wavesrv.
        await model.flushPersist()

        // Reload with a FRESH store (no cache) → real GetObject from wavesrv.
        let store2 = ObjectStore(transport: transport)
        let model2 = LayoutModel(
            layoutORef: layoutORef, transport: transport, store: store2,
            windowId: windowId, tabId: tabId)
        try await model2.start()

        let reloaded = model2.currentState()
        XCTAssertEqual(Set(leafBlockIds(model2)), Set([b1, b2, b3]), "tree must round-trip through wavesrv")
        XCTAssertNil(
            LayoutTree.findNodeByBlockId(reloaded.rootNode, blockId: b4),
            "the closed pane must not reappear after reload")
        XCTAssertEqual(
            LayoutTree.findNodeByBlockId(reloaded.rootNode, blockId: b1)?.size, 30,
            "the resized size must survive the persist/reload round-trip")
        XCTAssertNil(reloaded.pendingBackendActions, "a round-tripped layout has no queued backend actions")
    }

    // MARK: - E2E-5.2 — block created from another route appears via pendingbackendactions

    func testBackendCreatedBlockAppearsViaPendingActions() async throws {
        let model = LayoutModel(
            layoutORef: layoutORef, transport: transport, store: store,
            windowId: windowId, tabId: tabId)
        try await model.start()

        let baseline = leafBlockIds(model).count

        // "Another route": the wsh CreateBlockCommand. The backend creates the block,
        // QUEUES an `insert` into LayoutState.pendingbackendactions (with a server
        // -assigned actionid, wcore/layout.go:89-90), and broadcasts a
        // `waveobj:update` for the layout oref (wshserver.go:240-313). The model is
        // subscribed to that oref, so the event drives apply-and-clear (GUARDS §L).
        let newRef = try await commands.createBlock(
            CommandCreateBlockData(tabid: tabId, blockdef: Self.termBlockDef()))
        XCTAssertEqual(newRef.otype, OType.block)
        let newBlockId = newRef.oid

        // GUARDS §L: the backend-created block must APPEAR in the local tree.
        let appeared = await waitUntil(timeout: 8.0) {
            LayoutTree.findNodeByBlockId(model.currentState().rootNode, blockId: newBlockId) != nil
        }
        XCTAssertTrue(appeared, "wsh-created block must appear via pendingbackendactions (GUARDS §L)")
        XCTAssertEqual(leafBlockIds(model).count, baseline + 1, "exactly one new leaf should be added")
        XCTAssertNil(
            model.currentState().pendingBackendActions,
            "the local pending queue must be CLEARED after applying (GUARDS §L)")

        // GUARDS §L: the apply-and-clear must be PERSISTED back to wavesrv with the
        // pending queue empty — otherwise the backend re-delivers the action forever.
        var clearedOnBackend = false
        var rootPersisted = false
        for _ in 0..<160 {
            let rtn = try await transport.callService(WebCallType(
                service: "object", method: "GetObject", uicontext: nil,
                args: [.string(layoutORef.string)]))
            if let data = rtn.data, !data.isNull, let ls = try? data.decode(LayoutState.self) {
                clearedOnBackend = (ls.pendingbackendactions?.isEmpty ?? true)
                rootPersisted = ls.rootLayoutNode != nil
                if clearedOnBackend && rootPersisted { break }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(clearedOnBackend, "persisted LayoutState must carry an empty pending queue (GUARDS §L)")
        XCTAssertTrue(rootPersisted, "the applied tree (with the new block) must be persisted back")

        // And the persisted tree actually contains the new block (fresh-store reload).
        let store2 = ObjectStore(transport: transport)
        let model2 = LayoutModel(
            layoutORef: layoutORef, transport: transport, store: store2,
            windowId: windowId, tabId: tabId)
        try await model2.start()
        XCTAssertNotNil(
            LayoutTree.findNodeByBlockId(model2.currentState().rootNode, blockId: newBlockId),
            "the wsh-created block must be present in the reloaded, persisted tree")
    }

    // MARK: - Helpers

    private static func termBlockDef() -> BlockDef {
        BlockDef(meta: ["view": .string("term"), "controller": .string("shell")])
    }

    private func nodeId(_ model: LayoutModel, _ blockId: String) throws -> String {
        try XCTUnwrap(
            LayoutTree.findNodeByBlockId(model.currentState().rootNode, blockId: blockId)?.id,
            "no layout node for block \(blockId)")
    }

    private func leafBlockIds(_ model: LayoutModel) -> [String] {
        (model.currentState().leafOrder ?? []).map { $0.blockid }
    }

    /// Poll `condition` until true or `timeout` elapses (event delivery + the
    /// apply-and-clear persist ride real WS + HTTP round-trips).
    private func waitUntil(timeout: TimeInterval, _ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
}

// MARK: - File-private updates bridge (GUARDS §B)

/// Routes the transport's inline `WebReturnType.updates` into the object cache
/// (GUARDS §B). File-private so it never collides with the other gates' bridges.
private final class LayoutE2EUpdatesBridge: WaveTransportUpdatesDelegate, @unchecked Sendable {
    private let store: ObjectStore
    init(store: ObjectStore) { self.store = store }
    func transport(_ transport: WaveTransportClient, didReceive updates: [WaveObjUpdate]) {
        store.applyUpdates(updates)
    }
}
