// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveLayout tests — exercise the reducer (PROTOCOL.md §6) and the apply-and-clear
// `pendingbackendactions` round-trip (GUARDS §L). No live wavesrv: the model is
// driven against a stub WaveTransport (capturing the persisted UpdateObject call)
// and a stub ObjectStore.

import XCTest
@testable import WaveCore
@testable import WaveLayout

final class WaveLayoutTests: XCTestCase {

    // MARK: GUARDS §L — node defaults

    func testNewNodeDefaults() {
        let node = LayoutTree.newLeaf(blockId: "blk")
        XCTAssertEqual(node.size, LayoutNode.defaultSize)
        XCTAssertEqual(node.size, 10)
        XCTAssertEqual(node.flexDirection, .row)
        XCTAssertEqual(node.data?.blockId, "blk")
        XCTAssertNil(node.children)
    }

    // MARK: Reducer — insert

    func testInsertIntoEmptyTreeSetsRoot() {
        var state = LayoutTreeState()
        let leaf = LayoutTree.newLeaf(blockId: "a")
        LayoutReducer.apply(.insertNode(node: leaf), to: &state)
        LayoutReducer.updateTree(&state)
        XCTAssertEqual(state.rootNode?.data?.blockId, "a")
        XCTAssertEqual(state.leafOrder?.count, 1)
        // Focus defaults to the only leaf.
        XCTAssertEqual(state.focusedNodeId, leaf.id)
    }

    func testInsertSecondNodeBuildsChildren() {
        var state = LayoutTreeState()
        LayoutReducer.apply(.insertNode(node: LayoutTree.newLeaf(blockId: "a")), to: &state)
        LayoutReducer.updateTree(&state)
        LayoutReducer.apply(.insertNode(node: LayoutTree.newLeaf(blockId: "b")), to: &state)
        LayoutReducer.updateTree(&state)

        XCTAssertEqual(state.rootNode?.children?.count, 2)
        XCTAssertNil(state.rootNode?.data)
        XCTAssertEqual(state.leafOrder?.map { $0.blockid }, ["a", "b"])
    }

    func testInsertNodeAtIndex() {
        var state = LayoutTreeState()
        // Clear-then-insert-at-index is exactly how ApplyPortableLayout seeds a tab.
        LayoutReducer.apply(.clearTree, to: &state)
        LayoutReducer.apply(
            .insertNodeAtIndex(node: LayoutTree.newLeaf(blockId: "x"), indexArr: [0]),
            to: &state)
        LayoutReducer.updateTree(&state)
        XCTAssertEqual(state.rootNode?.data?.blockId, "x")
    }

    // MARK: Reducer — delete (collapses via balance)

    func testDeleteNodeCollapsesTree() {
        var state = LayoutTreeState()
        LayoutReducer.apply(.insertNode(node: LayoutTree.newLeaf(blockId: "a")), to: &state)
        LayoutReducer.updateTree(&state)
        let b = LayoutTree.newLeaf(blockId: "b")
        LayoutReducer.apply(.insertNode(node: b), to: &state)
        LayoutReducer.updateTree(&state)
        XCTAssertEqual(state.leafOrder?.count, 2)

        let bNodeId = LayoutTree.findNodeByBlockId(state.rootNode, blockId: "b")!.id
        LayoutReducer.apply(.deleteNode(nodeId: bNodeId), to: &state)
        LayoutReducer.updateTree(&state)

        XCTAssertEqual(state.rootNode?.data?.blockId, "a")
        XCTAssertNil(state.rootNode?.children)
        XCTAssertEqual(state.leafOrder?.count, 1)
    }

    // MARK: Reducer — resize

    func testResizeNode() {
        var state = LayoutTreeState()
        LayoutReducer.apply(.insertNode(node: LayoutTree.newLeaf(blockId: "a")), to: &state)
        LayoutReducer.apply(.insertNode(node: LayoutTree.newLeaf(blockId: "b")), to: &state)
        LayoutReducer.updateTree(&state)

        let aId = LayoutTree.findNodeByBlockId(state.rootNode, blockId: "a")!.id
        LayoutReducer.apply(.resizeNode([ResizeOperation(nodeId: aId, size: 42)]), to: &state)
        LayoutReducer.updateTree(&state)
        XCTAssertEqual(LayoutTree.findNode(state.rootNode, id: aId)?.size, 42)
    }

    func testResizeRejectsOutOfRangeBatch() {
        var state = LayoutTreeState()
        LayoutReducer.apply(.insertNode(node: LayoutTree.newLeaf(blockId: "a")), to: &state)
        LayoutReducer.apply(.insertNode(node: LayoutTree.newLeaf(blockId: "b")), to: &state)
        LayoutReducer.updateTree(&state)
        let aId = LayoutTree.findNodeByBlockId(state.rootNode, blockId: "a")!.id
        let bId = LayoutTree.findNodeByBlockId(state.rootNode, blockId: "b")!.id
        // The whole batch is rejected if any op is out of [0,100].
        LayoutReducer.apply(
            .resizeNode([ResizeOperation(nodeId: aId, size: 30), ResizeOperation(nodeId: bId, size: 101)]),
            to: &state)
        XCTAssertEqual(LayoutTree.findNode(state.rootNode, id: aId)?.size, 10)
    }

    // MARK: Reducer — split

    func testSplitHorizontalWrapsRoot() {
        var state = LayoutTreeState()
        LayoutReducer.apply(.insertNode(node: LayoutTree.newLeaf(blockId: "a")), to: &state)
        LayoutReducer.updateTree(&state)
        let aId = state.rootNode!.id
        LayoutReducer.apply(
            .splitHorizontal(targetNodeId: aId, newNode: LayoutTree.newLeaf(blockId: "b"), position: .after),
            to: &state)
        LayoutReducer.updateTree(&state)
        XCTAssertEqual(state.leafOrder?.map { $0.blockid }, ["a", "b"])
    }

    func testSplitVerticalBeforePlacesNewFirst() {
        var state = LayoutTreeState()
        LayoutReducer.apply(.insertNode(node: LayoutTree.newLeaf(blockId: "a")), to: &state)
        LayoutReducer.updateTree(&state)
        let aId = state.rootNode!.id
        LayoutReducer.apply(
            .splitVertical(targetNodeId: aId, newNode: LayoutTree.newLeaf(blockId: "b"), position: .before),
            to: &state)
        LayoutReducer.updateTree(&state)
        XCTAssertEqual(state.rootNode?.flexDirection, .column)
        XCTAssertEqual(state.leafOrder?.map { $0.blockid }, ["b", "a"])
    }

    // MARK: Reducer — replace / swap

    func testReplaceNodePreservesSize() {
        var state = LayoutTreeState()
        let a = LayoutTree.newLeaf(blockId: "a", size: 25)
        LayoutReducer.apply(.insertNode(node: a), to: &state)
        LayoutReducer.updateTree(&state)
        LayoutReducer.apply(
            .replaceNode(targetNodeId: a.id, newNode: LayoutTree.newLeaf(blockId: "z", size: 99)),
            to: &state)
        LayoutReducer.updateTree(&state)
        XCTAssertEqual(state.rootNode?.data?.blockId, "z")
        XCTAssertEqual(state.rootNode?.size, 25)
    }

    func testSwapNodeExchangesLeaves() {
        var state = LayoutTreeState()
        LayoutReducer.apply(.insertNode(node: LayoutTree.newLeaf(blockId: "a")), to: &state)
        LayoutReducer.apply(.insertNode(node: LayoutTree.newLeaf(blockId: "b")), to: &state)
        LayoutReducer.updateTree(&state)
        let aId = LayoutTree.findNodeByBlockId(state.rootNode, blockId: "a")!.id
        let bId = LayoutTree.findNodeByBlockId(state.rootNode, blockId: "b")!.id
        LayoutReducer.apply(.swapNode(node1Id: aId, node2Id: bId), to: &state)
        LayoutReducer.updateTree(&state)
        XCTAssertEqual(state.leafOrder?.map { $0.blockid }, ["b", "a"])
    }

    // MARK: Drag-and-drop — drop-zone geometry (port of determineDropDirection)

    func testDropDirectionZones() {
        let box = CGSize(width: 100, height: 100)
        XCTAssertEqual(LayoutMove.determineDropDirection(in: box, at: CGPoint(x: 50, y: 50)), .center)
        XCTAssertEqual(LayoutMove.determineDropDirection(in: box, at: CGPoint(x: 50, y: 30)), .top)
        XCTAssertEqual(LayoutMove.determineDropDirection(in: box, at: CGPoint(x: 70, y: 50)), .right)
        XCTAssertEqual(LayoutMove.determineDropDirection(in: box, at: CGPoint(x: 50, y: 70)), .bottom)
        XCTAssertEqual(LayoutMove.determineDropDirection(in: box, at: CGPoint(x: 30, y: 50)), .left)
        // Outer fifth nearest an edge → the matching Outer* zone.
        XCTAssertEqual(LayoutMove.determineDropDirection(in: box, at: CGPoint(x: 50, y: 5)), .outerTop)
        XCTAssertEqual(LayoutMove.determineDropDirection(in: box, at: CGPoint(x: 95, y: 50)), .outerRight)
        // Outside the box → nil.
        XCTAssertNil(LayoutMove.determineDropDirection(in: box, at: CGPoint(x: -1, y: 50)))
        XCTAssertNil(LayoutMove.determineDropDirection(in: box, at: CGPoint(x: 50, y: 101)))
    }

    // MARK: Drag-and-drop — action computation (port of computeMoveNode)

    func testDropCenterProducesSwap() {
        var state = LayoutTreeState()
        LayoutReducer.apply(.insertNode(node: LayoutTree.newLeaf(blockId: "a")), to: &state)
        LayoutReducer.apply(.insertNode(node: LayoutTree.newLeaf(blockId: "b")), to: &state)
        LayoutReducer.updateTree(&state)
        let aId = LayoutTree.findNodeByBlockId(state.rootNode, blockId: "a")!.id
        let bId = LayoutTree.findNodeByBlockId(state.rootNode, blockId: "b")!.id

        guard case let .swapNode(n1, n2)? = LayoutMove.computeMoveAction(
            root: state.rootNode, targetNodeId: aId, nodeToMoveId: bId, direction: .center)
        else { return XCTFail("expected swapNode") }
        XCTAssertEqual(Set([n1, n2]), Set([aId, bId]))
    }

    func testDropOnSelfIsNoop() {
        var state = LayoutTreeState()
        LayoutReducer.apply(.insertNode(node: LayoutTree.newLeaf(blockId: "a")), to: &state)
        LayoutReducer.apply(.insertNode(node: LayoutTree.newLeaf(blockId: "b")), to: &state)
        LayoutReducer.updateTree(&state)
        let aId = LayoutTree.findNodeByBlockId(state.rootNode, blockId: "a")!.id
        XCTAssertNil(LayoutMove.computeMoveAction(
            root: state.rootNode, targetNodeId: aId, nodeToMoveId: aId, direction: .center))
        XCTAssertNil(LayoutMove.computeMoveAction(
            root: state.rootNode, targetNodeId: aId, nodeToMoveId: aId, direction: .right))
    }

    func testDropEdgeProducesMoveAndPreservesLeaves() {
        var state = LayoutTreeState()
        LayoutReducer.apply(.insertNode(node: LayoutTree.newLeaf(blockId: "a")), to: &state)
        LayoutReducer.apply(.insertNode(node: LayoutTree.newLeaf(blockId: "b")), to: &state)
        LayoutReducer.updateTree(&state)
        let aId = LayoutTree.findNodeByBlockId(state.rootNode, blockId: "a")!.id
        let bId = LayoutTree.findNodeByBlockId(state.rootNode, blockId: "b")!.id

        guard case .moveNode? = LayoutMove.computeMoveAction(
            root: state.rootNode, targetNodeId: aId, nodeToMoveId: bId, direction: .bottom)
        else { return XCTFail("expected moveNode") }

        let action = LayoutMove.computeMoveAction(
            root: state.rootNode, targetNodeId: aId, nodeToMoveId: bId, direction: .bottom)!
        LayoutReducer.apply(action, to: &state)
        LayoutReducer.updateTree(&state)
        XCTAssertEqual(Set(state.leafOrder?.map { $0.blockid } ?? []), Set(["a", "b"]))
    }

    // MARK: balanceNode

    func testBalanceCollapsesSingleChild() {
        var root = LayoutTree.newNode(children: [LayoutTree.newLeaf(blockId: "only")])
        LayoutTree.balanceNode(&root)
        XCTAssertEqual(root.data?.blockId, "only")
        XCTAssertNil(root.children)
    }

    func testClearTreeEmptiesState() {
        var state = LayoutTreeState()
        LayoutReducer.apply(.insertNode(node: LayoutTree.newLeaf(blockId: "a")), to: &state)
        LayoutReducer.updateTree(&state)
        LayoutReducer.apply(.clearTree, to: &state)
        LayoutReducer.updateTree(&state)
        XCTAssertNil(state.rootNode)
        XCTAssertEqual(state.leafOrder?.count ?? 0, 0)
        XCTAssertNil(state.focusedNodeId)
    }

    // MARK: GUARDS §L — backend-created-block pending-action round-trip

    func testPendingBackendActionsRoundTrip() async throws {
        // A backend-created block arrives as a queued [clear, insertatindex] (exactly
        // how ApplyPortableLayout seeds a tab via wsh).
        let pending: [LayoutActionData] = [
            LayoutActionData(actiontype: LayoutActionType.clearTree, actionid: "act-0", blockid: ""),
            LayoutActionData(
                actiontype: LayoutActionType.insertAtIndex, actionid: "act-1",
                blockid: "blkX", indexarr: [0]),
        ]
        let ls = LayoutState(oid: "L1", version: 3, pendingbackendactions: pending)

        let transport = StubTransport()
        let store = StubStore(layout: ls)
        let model = LayoutModel(
            layoutORef: ORef.layout("L1"),
            transport: transport, store: store,
            windowId: "w1", tabId: "t1")
        model.persistDebounceMs = 100_000  // never let the debounce timer fire mid-test

        try await model.start()

        // Tree now contains the backend block.
        let state = model.currentState()
        XCTAssertEqual(state.rootNode?.data?.blockId, "blkX")
        XCTAssertNil(state.pendingBackendActions, "pending queue must be cleared (GUARDS §L)")

        // The persist was a generic ObjectService.UpdateObject carrying otype=layout,
        // a populated rootnode, and a CLEARED pending queue.
        let call = try XCTUnwrap(transport.lastServiceCall)
        XCTAssertEqual(call.service, "object")
        XCTAssertEqual(call.method, "UpdateObject")
        XCTAssertEqual(call.uicontext?.windowid, "w1")
        XCTAssertEqual(call.uicontext?.activetabid, "t1")
        XCTAssertEqual(call.args.count, 2)
        XCTAssertEqual(call.args[1].boolValue, false)  // returnUpdates

        let obj = try XCTUnwrap(call.args.first?.objectValue)
        XCTAssertEqual(obj[OTypeKeyName]?.stringValue, OType.layout)
        XCTAssertNil(obj["pendingbackendactions"], "persisted queue must be empty (GUARDS §L)")
        let rootNode = try XCTUnwrap(obj["rootnode"]).decode(LayoutNode.self)
        XCTAssertEqual(rootNode.data?.blockId, "blkX")
    }

    func testPendingActionsAreDedupedByActionId() async throws {
        let pending: [LayoutActionData] = [
            LayoutActionData(
                actiontype: LayoutActionType.insertAtIndex, actionid: "once",
                blockid: "blkY", indexarr: [0]),
        ]
        let ls = LayoutState(oid: "L2", version: 1, pendingbackendactions: pending)
        let model = LayoutModel(
            layoutORef: ORef.layout("L2"),
            transport: StubTransport(), store: StubStore(layout: ls),
            windowId: "w", tabId: "t")
        model.persistDebounceMs = 100_000

        try await model.start()
        // Re-deliver the same queue (e.g. an echoed waveobj:update). The action id is
        // already processed, so it must NOT insert a second copy.
        await model.applyLayoutState(ls, isInitialLoad: false)

        XCTAssertEqual(model.currentState().leafOrder?.count, 1)
        XCTAssertEqual(model.currentState().rootNode?.data?.blockId, "blkY")
    }

    func testBackendSplitActionFocusesNewPane() async throws {
        // A Cmd-D split queues a backend split action with focused:true. Dropping the
        // flag left focusedNodeId on the split SOURCE, so a later Cmd-W (which reads
        // the model's focused node) closed the previously focused pane.
        let pending: [LayoutActionData] = [
            LayoutActionData(
                actiontype: LayoutActionType.insertAtIndex, actionid: "s-0",
                blockid: "blkA", indexarr: [0], focused: true),
        ]
        let ls = LayoutState(oid: "L7", version: 1, pendingbackendactions: pending)
        let model = LayoutModel(
            layoutORef: ORef.layout("L7"),
            transport: StubTransport(), store: StubStore(layout: ls),
            windowId: "w", tabId: "t")
        model.persistDebounceMs = 100_000

        try await model.start()

        let split = LayoutState(oid: "L7", version: 2, pendingbackendactions: [
            LayoutActionData(
                actiontype: LayoutActionType.splitHorizontal, actionid: "s-1",
                blockid: "blkB", focused: true, targetblockid: "blkA", position: "after"),
        ])
        await model.applyLayoutState(split, isInitialLoad: false)

        let state = model.currentState()
        XCTAssertEqual(state.leafOrder?.count, 2)
        let newLeaf = try XCTUnwrap(LayoutTree.findNodeByBlockId(state.rootNode, blockId: "blkB"))
        XCTAssertEqual(state.focusedNodeId, newLeaf.id, "split with focused:true must focus the NEW pane")
    }

    func testRemoveNodeActionRemovesNodeWithoutDeletingBlock() async throws {
        let pending: [LayoutActionData] = [
            LayoutActionData(
                actiontype: LayoutActionType.insertAtIndex, actionid: "r-0",
                blockid: "blkA", indexarr: [0]),
            LayoutActionData(
                actiontype: LayoutActionType.insertAtIndex, actionid: "r-1",
                blockid: "blkB", indexarr: [1]),
        ]
        let ls = LayoutState(oid: "L6", version: 1, pendingbackendactions: pending)
        let model = LayoutModel(
            layoutORef: ORef.layout("L6"),
            transport: StubTransport(), store: StubStore(layout: ls),
            windowId: "w", tabId: "t")
        model.persistDebounceMs = 100_000
        let deleted = DeletedBlocksBox()
        model.onNodeDelete = { deleted.append($0) }

        try await model.start()
        XCTAssertEqual(model.currentState().leafOrder?.count, 2)

        // blkA moved to another tab: the backend queues `removenode`, which must drop
        // the layout node but must NOT trigger a client-side DeleteBlock (`delete`
        // semantics) — the block lives on under its new tab.
        let move = LayoutState(oid: "L6", version: 2, pendingbackendactions: [
            LayoutActionData(actiontype: LayoutActionType.removeNode, actionid: "r-2", blockid: "blkA"),
        ])
        await model.applyLayoutState(move, isInitialLoad: false)

        let state = model.currentState()
        XCTAssertEqual(state.leafOrder?.count, 1)
        XCTAssertNil(LayoutTree.findNodeByBlockId(state.rootNode, blockId: "blkA"))
        XCTAssertEqual(state.rootNode?.data?.blockId, "blkB")
        XCTAssertTrue(deleted.values.isEmpty, "removenode must not delete the moved block")
    }

    // MARK: Self-heal — wiped layout / blockids divergence (empty pane)

    func testReseedsWipedLayoutOnInitialLoad() async throws {
        // T2-style corruption: the stored layout is fully wiped (rootnode:null) but the
        // tab still owns a valid block. On load we must re-seed it from tab.blockids
        // and persist the recovery — not show an empty pane.
        let ls = LayoutState(oid: "L3", version: 7)
        let transport = StubTransport()
        let model = LayoutModel(
            layoutORef: ORef.layout("L3"),
            transport: transport, store: StubStore(layout: ls),
            windowId: "w", tabId: "t")
        model.persistDebounceMs = 100_000
        model.tabBlockIdsProvider = { ["blkA"] }

        try await model.start()

        let state = model.currentState()
        XCTAssertEqual(state.rootNode?.data?.blockId, "blkA", "wiped layout must be re-seeded from tab.blockids")
        XCTAssertEqual(state.leafOrder?.count, 1)

        // The recovery must be written back so it is durable.
        let call = try XCTUnwrap(transport.lastServiceCall, "self-heal must persist the recovered layout")
        let obj = try XCTUnwrap(call.args.first?.objectValue)
        let rootNode = try XCTUnwrap(obj["rootnode"]).decode(LayoutNode.self)
        XCTAssertEqual(rootNode.data?.blockId, "blkA")
    }

    func testClearWithoutPairedInsertDoesNotStrandBlock() async throws {
        // The live corruption path: the seed delivers a `clear` but its paired `insert`
        // is dropped. Without self-heal this persists rootnode:null while the block
        // stays in tab.blockids → permanent empty pane.
        let pending: [LayoutActionData] = [
            LayoutActionData(actiontype: LayoutActionType.clearTree, actionid: "c-0", blockid: ""),
        ]
        let ls = LayoutState(oid: "L4", version: 2, pendingbackendactions: pending)
        let transport = StubTransport()
        let model = LayoutModel(
            layoutORef: ORef.layout("L4"),
            transport: transport, store: StubStore(layout: ls),
            windowId: "w", tabId: "t")
        model.persistDebounceMs = 100_000
        model.tabBlockIdsProvider = { ["blkZ"] }

        try await model.start()

        XCTAssertEqual(
            model.currentState().rootNode?.data?.blockId, "blkZ",
            "a dropped insert must not strand the owned block")
        let obj = try XCTUnwrap(transport.lastServiceCall?.args.first?.objectValue)
        let rootNode = try XCTUnwrap(obj["rootnode"]).decode(LayoutNode.self)
        XCTAssertEqual(rootNode.data?.blockId, "blkZ")
    }

    func testReseedDoesNotResurrectIntoNonEmptyTree() async throws {
        // Guard the gating: a non-empty tree merely missing a block id (e.g. a close
        // still in flight) must NOT be re-seeded — only a FULL wipe is repaired.
        let pending: [LayoutActionData] = [
            LayoutActionData(
                actiontype: LayoutActionType.insertAtIndex, actionid: "i-0",
                blockid: "blkX", indexarr: [0]),
        ]
        let ls = LayoutState(oid: "L5", version: 1, pendingbackendactions: pending)
        let model = LayoutModel(
            layoutORef: ORef.layout("L5"),
            transport: StubTransport(), store: StubStore(layout: ls),
            windowId: "w", tabId: "t")
        model.persistDebounceMs = 100_000
        model.tabBlockIdsProvider = { ["blkX", "stale"] }

        try await model.start()

        let state = model.currentState()
        XCTAssertEqual(state.leafOrder?.count, 1, "non-empty tree must not be re-seeded")
        XCTAssertEqual(state.rootNode?.data?.blockId, "blkX")
        XCTAssertNil(LayoutTree.findNodeByBlockId(state.rootNode, blockId: "stale"))
    }
}

// MARK: - Stubs

/// Thread-safe collector for `onNodeDelete` callbacks (a `@Sendable` closure can't
/// capture a mutable local).
private final class DeletedBlocksBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return _values
    }
    func append(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        _values.append(value)
    }
}

private final class StubTransport: WaveTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastServiceCall: WebCallType?
    var lastServiceCall: WebCallType? {
        lock.lock(); defer { lock.unlock() }
        return _lastServiceCall
    }

    var addrs: ServerAddrs? { nil }
    var routeId: String? { nil }
    var isConnected: Bool { true }
    var onReconnect: (@Sendable () -> Void)?

    func spawn(env: [String: String]) async throws -> ServerAddrs { throw WaveError.notConnected }
    func connect(routeId: String) async throws {}
    func reconnect() async throws {}
    func disconnect() {}

    func call<Req: Encodable & Sendable, Res: Decodable & Sendable>(
        command: String, data: Req?, route: String?, timeoutMs: Int64?
    ) async throws -> Res { throw WaveError.notConnected }

    func callVoid<Req: Encodable & Sendable>(
        command: String, data: Req?, route: String?, timeoutMs: Int64?
    ) async throws {}

    func notify<Req: Encodable & Sendable>(command: String, data: Req?, route: String?) throws {}

    func stream<Req: Encodable & Sendable>(
        command: String, data: Req?, route: String?,
        onChunk: @escaping @Sendable (Result<RpcMessage, WaveError>) -> Void
    ) throws -> SubscriptionToken { SubscriptionToken {} }

    func callService(_ call: WebCallType) async throws -> WebReturnType {
        lock.lock()
        _lastServiceCall = call
        lock.unlock()
        return WebReturnType(success: true)
    }

    func fetchFile(zoneId: String, name: String, offset: Int64) async throws -> (data: Data, info: WaveFile) {
        throw WaveError.notConnected
    }

    func subscribe(
        _ request: SubscriptionRequest, handler: @escaping @Sendable (WaveEvent) -> Void
    ) -> SubscriptionToken { SubscriptionToken {} }
}

private final class StubStore: ObjectStoreProtocol, @unchecked Sendable {
    private let layout: LayoutState
    init(layout: LayoutState) { self.layout = layout }

    func get(_ oref: ORef) -> AnyWaveObj? { .layout(layout) }
    func load(_ oref: ORef) async throws -> AnyWaveObj { .layout(layout) }
    func loadMany(_ orefs: [ORef]) async throws -> [AnyWaveObj] { [.layout(layout)] }
    @discardableResult func merge(_ obj: AnyWaveObj) -> Bool { true }
    func applyUpdates(_ updates: [WaveObjUpdate]) {}
    func subscribe(
        _ oref: ORef, handler: @escaping @Sendable (AnyWaveObj?) -> Void
    ) -> SubscriptionToken { SubscriptionToken {} }
}
