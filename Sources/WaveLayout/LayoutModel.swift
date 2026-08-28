// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveLayout — the per-tab layout model: ties the reducer to the object store and
// the transport.
//
// Implements PROTOCOL.md §6 and encodes GUARDS §L:
//   * `LayoutState` is a SEPARATE WaveObj loaded/saved via its own oref
//     (`Tab.layoutstate`), never as part of `Tab`.
//   * On load (and on any backend update) `pendingbackendactions` are applied to the
//     local tree, then the object is persisted back with that array CLEARED — this is
//     how a backend-created block (e.g. a `wsh` command opening a block) appears in
//     the tiles (`pkg/wcore/layout.go:82-142`, renderer
//     `frontend/layout/lib/layoutModel.ts:387-409`).
//   * The WHOLE `LayoutState` object is persisted on change, debounced ~100ms — there
//     is no granular layout RPC. Persist goes through the generic HTTP service
//     `ObjectService.UpdateObject` (PROTOCOL.md §6 / §0;
//     `pkg/service/objectservice/objectservice.go:142`).

import Foundation
import WaveCore
import WaveStore

/// Per-tab tiling layout model. Owns the live `LayoutTreeState`, applies reducer
/// actions, drives the debounced whole-object persist, and runs the apply-and-clear
/// `pendingbackendactions` protocol.
///
/// Thread-safe: all mutable state is guarded by an internal lock; transport I/O runs
/// off-lock. Geometry-driven drag/drop gesture math (`computeMoveNode`) and resize
/// previews are view concerns and live in WaveUI — this model consumes the resulting
/// `LayoutTreeAction`s.
public final class LayoutModel: @unchecked Sendable {

    /// The `LayoutState` oref (`layout:<oid>`) this model owns (GUARDS §L: a
    /// separate object from the tab).
    public let layoutORef: ORef

    private let transport: WaveTransport
    private let store: ObjectStoreProtocol
    private let windowId: String
    /// The tab this model renders. Exposed so the owner can reject a stale publish:
    /// during a tab switch `activeTabId` flips before the new tab's model has loaded,
    /// and a late tree-change from the OLD model must not render under the NEW tab id
    /// (it briefly painted the old tab's tree into the new tab's fresh layout view).
    public let tabId: String

    private let lock = NSLock()
    private var state = LayoutTreeState()
    private var lastVersion = 0
    private var processedActionIds = Set<String>()
    /// An ephemeral overlay node (backend `insert` with `ephemeral:true`). Kept out
    /// of the persisted tree, mirroring the renderer's ephemeral-node handling.
    private var ephemeralNode: LayoutNode?

    private var persistGeneration = 0
    private var storeToken: SubscriptionToken?

    /// Debounce window for the whole-object persist (GUARDS §L: ~100ms).
    public var persistDebounceMs: Int = 100

    /// Invoked (off-lock) with a `blockId` when a backend `delete` /
    /// `cleanuporphaned` action removes a block from the layout. The WaveCommands
    /// layer wires this to `DeleteBlock`.
    public var onNodeDelete: (@Sendable (String) -> Void)?

    /// Supplies the owning tab's `blockids` for `cleanuporphaned` (renderer reads
    /// `tab.blockids`). Returns nil/empty to skip orphan cleanup.
    public var tabBlockIdsProvider: (@Sendable () -> [String])?

    /// Invoked (off-lock) whenever the tree changes (initial load, applied backend
    /// actions, or a local dispatch) so the owner can re-render the tiles.
    public var onTreeChanged: (@Sendable () -> Void)?

    public init(
        layoutORef: ORef,
        transport: WaveTransport,
        store: ObjectStoreProtocol,
        windowId: String,
        tabId: String
    ) {
        precondition(layoutORef.otype == OType.layout, "LayoutModel requires a layout oref (GUARDS §L)")
        self.layoutORef = layoutORef
        self.transport = transport
        self.store = store
        self.windowId = windowId
        self.tabId = tabId
    }

    // MARK: - Lifecycle

    /// Load the `LayoutState` (its own oref — GUARDS §L), build the tree, run any
    /// pending backend actions, and subscribe for future updates.
    public func start() async throws {
        let obj = try await store.load(layoutORef)
        guard let ls = obj.asLayout else {
            throw WaveError.decoding("expected layout object for \(layoutORef.string)")
        }
        await applyLayoutState(ls, isInitialLoad: true)
        subscribe()
    }

    /// Cancel the store subscription. Does not flush pending persists.
    public func stop() {
        storeToken?.cancel()
        storeToken = nil
    }

    private func subscribe() {
        storeToken = store.subscribe(layoutORef) { [weak self] obj in
            guard let self, let ls = obj?.asLayout else { return }
            self.onBackendUpdate(ls)
        }
    }

    /// A snapshot of the current tree state.
    public func currentState() -> LayoutTreeState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    // MARK: - Local mutation

    /// Apply a reducer action from the UI, recompute the tree, and schedule a
    /// debounced persist (renderer `treeReducer(action, setState=true)`).
    public func dispatch(_ action: LayoutTreeAction) {
        lock.lock()
        LayoutReducer.apply(action, to: &state)
        LayoutReducer.updateTree(&state)
        lock.unlock()
        onTreeChanged?()
        schedulePersist()
    }

    // MARK: - Backend → client (apply-and-clear, GUARDS §L)

    private func onBackendUpdate(_ ls: LayoutState) {
        // The local tree is authoritative while mounted; a backend update only
        // matters for queued structural actions (renderer `onBackendUpdate`).
        lock.lock()
        if ls.version > lastVersion { lastVersion = ls.version }
        let hasPending = (ls.pendingbackendactions?.isEmpty == false)
        lock.unlock()
        guard hasPending else { return }
        Task { await applyLayoutState(ls, isInitialLoad: false) }
    }

    /// Build (or reconcile) the tree from a `LayoutState` and run its
    /// `pendingbackendactions`, then persist back with the queue cleared (GUARDS §L).
    public func applyLayoutState(_ ls: LayoutState, isInitialLoad: Bool) async {
        var blocksToDelete: [String] = []

        lock.lock()
        lastVersion = max(lastVersion, ls.version)
        if isInitialLoad {
            state.rootNode = ls.rootLayoutNode
            state.focusedNodeId = ls.focusednodeid
            state.magnifiedNodeId = ls.magnifiednodeid
            state.pendingBackendActions = ls.pendingbackendactions
        }

        let actions = ls.pendingbackendactions ?? []
        // Clear locally before applying — the persisted write must carry an empty
        // queue so the backend does not re-deliver these actions (GUARDS §L).
        state.pendingBackendActions = nil

        for action in actions {
            guard let actionId = action.actionid, !actionId.isEmpty else { continue }
            if processedActionIds.contains(actionId) { continue }
            processedActionIds.insert(actionId)
            applyBackendActionLocked(action, blocksToDelete: &blocksToDelete)
        }

        let didReseed = reseedFullyWipedLocked()
        LayoutReducer.updateTree(&state)
        let rootSnapshot = state.rootNode
        lock.unlock()

        // A backend action can reference a block whose own waveobj update hasn't reached
        // the local store yet (the LayoutState broadcast can win that race). The renderer
        // PRUNES leaves it cannot resolve, and nothing re-publishes when the block lands
        // later — the new pane would stay invisible until the NEXT tree change, at which
        // point every stalled pane pops in at once (the "second Cmd-D shows two panes"
        // wedge). Pull any unresolved block into the store before notifying the renderer.
        if !actions.isEmpty || didReseed {
            for blockId in Self.leafBlockIds(rootSnapshot) where store.get(.block(blockId)) == nil {
                _ = try? await store.load(.block(blockId))
            }
        }

        onTreeChanged?()

        for blockId in blocksToDelete {
            onNodeDelete?(blockId)
        }

        // Initial load with nothing queued still needs a leaf-order pass but no
        // write-back; only persist when we actually consumed queued actions — or when
        // we just self-healed a wiped tree, which must be written back so the recovery
        // is durable in the stored LayoutState.
        if !actions.isEmpty || didReseed {
            await flushPersist()
        }
    }

    /// The block ids of every leaf in the tree, in traversal order.
    private static func leafBlockIds(_ root: LayoutNode?) -> [String] {
        var out: [String] = []
        func walk(_ node: LayoutNode?) {
            guard let node else { return }
            if let blockId = node.data?.blockId { out.append(blockId) }
            node.children?.forEach { walk($0) }
        }
        walk(root)
        return out
    }

    /// Self-heal for the layout/blockids divergence that surfaces as an empty pane:
    /// the tab still owns blocks (`tab.blockids`) but the layout tree has no node for
    /// them. The known cause is a full wipe — a backend `clear` that applied while its
    /// paired `insert` was dropped (deduped / missing `indexarr`), then persisted as
    /// `rootnode:null`. We re-insert the owned blocks as leaves so a valid block (with
    /// its scrollback) is never stranded, both preventing the bad persist on the live
    /// path and repairing an already-broken tab on initial load.
    ///
    /// Deliberately gated on the FULL-wipe signature (`rootNode == nil`): a non-empty
    /// tree that is merely missing one block can be a close still in flight, and
    /// re-adding it there would resurrect a block the user just closed. Must hold
    /// `lock`; returns whether it changed the tree.
    private func reseedFullyWipedLocked() -> Bool {
        guard state.rootNode == nil else { return false }
        guard let blockIds = tabBlockIdsProvider?(), !blockIds.isEmpty else { return false }
        for blockId in blockIds {
            LayoutReducer.apply(
                .insertNode(node: LayoutTree.newLeaf(blockId: blockId), magnified: false, focused: false),
                to: &state)
        }
        return true
    }

    /// Translate one backend `LayoutActionData` into a reducer action and apply it.
    /// Must be called with `lock` held. Collects block ids that should be deleted
    /// (callbacks fire off-lock).
    private func applyBackendActionLocked(_ action: LayoutActionData, blocksToDelete: inout [String]) {
        let size = action.nodesize.map { Double($0) } ?? LayoutNode.defaultSize
        switch action.actiontype {
        case LayoutActionType.insert:
            if action.ephemeral == true {
                ephemeralNode = LayoutTree.newLeaf(blockId: action.blockid)
                return
            }
            LayoutReducer.apply(
                .insertNode(
                    node: LayoutTree.newLeaf(blockId: action.blockid),
                    magnified: action.magnified ?? false,
                    focused: action.focused ?? false),
                to: &state)

        case LayoutActionType.insertAtIndex:
            guard let indexArr = action.indexarr else { return }
            LayoutReducer.apply(
                .insertNodeAtIndex(
                    node: LayoutTree.newLeaf(blockId: action.blockid, size: size),
                    indexArr: indexArr,
                    magnified: action.magnified ?? false,
                    focused: action.focused ?? false),
                to: &state)

        case LayoutActionType.delete:
            guard let leaf = LayoutTree.findNodeByBlockId(state.rootNode, blockId: action.blockid) else { return }
            blocksToDelete.append(action.blockid)
            LayoutReducer.apply(.deleteNode(nodeId: leaf.id), to: &state)

        case LayoutActionType.removeNode:
            // The block moved to another tab: remove its node but do NOT collect it
            // into blocksToDelete (the block lives on under its new tab).
            guard let leaf = LayoutTree.findNodeByBlockId(state.rootNode, blockId: action.blockid) else { return }
            LayoutReducer.apply(.deleteNode(nodeId: leaf.id), to: &state)

        case LayoutActionType.clearTree:
            LayoutReducer.apply(.clearTree, to: &state)

        case LayoutActionType.replace:
            guard let targetBlockId = action.targetblockid,
                  let target = LayoutTree.findNodeByBlockId(state.rootNode, blockId: targetBlockId)
            else { return }
            LayoutReducer.apply(
                .replaceNode(
                    targetNodeId: target.id,
                    newNode: LayoutTree.newLeaf(blockId: action.blockid, size: size),
                    focused: action.focused ?? false),
                to: &state)

        case LayoutActionType.splitHorizontal, LayoutActionType.splitVertical:
            guard let targetBlockId = action.targetblockid,
                  let target = LayoutTree.findNodeByBlockId(state.rootNode, blockId: targetBlockId),
                  let position = action.position.flatMap(SplitPosition.init(rawValue:))
            else { return }
            // `focused` must flow through here: a Cmd-D split sends focused:true, and
            // dropping it left `focusedNodeId` on the split SOURCE while the UI focused
            // the new pane — a later Cmd-W then closed the previously focused pane.
            let newNode = LayoutTree.newLeaf(blockId: action.blockid, size: size)
            if action.actiontype == LayoutActionType.splitHorizontal {
                LayoutReducer.apply(
                    .splitHorizontal(
                        targetNodeId: target.id, newNode: newNode, position: position,
                        focused: action.focused ?? false),
                    to: &state)
            } else {
                LayoutReducer.apply(
                    .splitVertical(
                        targetNodeId: target.id, newNode: newNode, position: position,
                        focused: action.focused ?? false),
                    to: &state)
            }

        case LayoutActionType.cleanupOrphaned:
            cleanupOrphanedLocked(blocksToDelete: &blocksToDelete)

        default:
            assertionFailure("unsupported backend layout action: \(action.actiontype)")
        }
    }

    private func cleanupOrphanedLocked(blocksToDelete: inout [String]) {
        // Mirror the renderer guard (`frontend/layout/lib/layoutModel.ts:415`): never
        // treat blocks as orphaned while the tree is fully empty. An empty tree is the
        // corruption signature (handled by reseedFullyWipedLocked), not a genuine set
        // of orphans — deleting here would destroy every still-valid block.
        guard state.rootNode != nil else { return }
        guard let blockIds = tabBlockIdsProvider?(), !blockIds.isEmpty else { return }
        var present = Set<String>()
        func walk(_ node: LayoutNode?) {
            guard let node else { return }
            if let blockId = node.data?.blockId { present.insert(blockId) }
            node.children?.forEach(walk)
        }
        walk(state.rootNode)
        for blockId in blockIds where !present.contains(blockId) {
            blocksToDelete.append(blockId)
        }
    }

    // MARK: - Persist (whole object, debounced — GUARDS §L)

    private func schedulePersist() {
        lock.lock()
        persistGeneration += 1
        let generation = persistGeneration
        lock.unlock()

        let delayNs = UInt64(max(0, persistDebounceMs)) * 1_000_000
        Task { [weak self] in
            if delayNs > 0 { try? await Task.sleep(nanoseconds: delayNs) }
            guard let self else { return }
            self.lock.lock()
            let stale = self.persistGeneration != generation
            self.lock.unlock()
            if stale { return }
            await self.sendPersist()
        }
    }

    /// Persist immediately, bypassing the debounce (used after applying pending
    /// backend actions and for deterministic flushing).
    public func flushPersist() async {
        lock.lock()
        persistGeneration += 1
        lock.unlock()
        await sendPersist()
    }

    private func sendPersist() async {
        lock.lock()
        let layoutJSON: JSONValue
        do {
            layoutJSON = try buildLayoutObjectLocked()
        } catch {
            lock.unlock()
            return
        }
        lock.unlock()

        let call = WebCallType(
            service: "object",
            method: "UpdateObject",
            uicontext: UIContext(windowid: windowId, activetabid: tabId),
            args: [layoutJSON, .bool(false)])

        do {
            let rtn = try await transport.callService(call)
            // GUARDS §B: apply any inline updates from the service response.
            if let updates = rtn.updates, !updates.isEmpty {
                store.applyUpdates(updates)
            }
        } catch {
            // A failed persist leaves the local tree authoritative; the next change
            // (or reconnect-driven reload) re-syncs. Surface nothing here.
        }
    }

    /// Encode the current tree as a `LayoutState` JSON object. The generic
    /// `UpdateObject` decoder is polymorphic on a top-level `otype` field
    /// (`pkg/waveobj/waveobj.go` `FromJsonMap`), which the typed `LayoutState`
    /// struct does not carry — so it is injected here. Must hold `lock`.
    private func buildLayoutObjectLocked() throws -> JSONValue {
        var ls = LayoutState(oid: layoutORef.oid, version: lastVersion)
        try ls.setRootLayoutNode(state.rootNode)
        ls.focusednodeid = state.focusedNodeId
        ls.magnifiednodeid = state.magnifiedNodeId
        ls.leaforder = state.leafOrder
        ls.pendingbackendactions = state.pendingBackendActions

        let encoded = try JSONValue.encode(ls)
        guard case .object(var obj) = encoded else {
            throw WaveError.decoding("layout state did not encode to a JSON object")
        }
        obj[OTypeKeyName] = .string(OType.layout)
        return .object(obj)
    }
}

/// The polymorphic-object discriminator key (`pkg/waveobj/waveobj.go:20`
/// `OTypeKeyName`). The HTTP `UpdateObject` service decodes a `WaveObj` by reading
/// this field, so a persisted `LayoutState` JSON must include it.
public let OTypeKeyName = "otype"
