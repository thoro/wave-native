// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveLayout — the layout-tree reducer.
//
// Implements PROTOCOL.md §6 ("The FE reducer mutates the tree locally"). Faithful
// value-type port of `frontend/layout/lib/layoutTree.ts` (insert / insertAtIndex /
// delete / resize / split{Horizontal,Vertical} / replace / swap / move / clearTree
// / focus / magnify) plus `balanceNode` from `layoutNode.ts`.
//
// GUARDS §L: node `size` defaults to 10 and `flexDirection` is row|column (enforced
// by `LayoutTree.newNode`); structural validity (children XOR data) is asserted in
// `balanceNode`.

import Foundation
import WaveCore

/// In-memory layout-tree state — the reducer's working copy of a `LayoutState`
/// WaveObj (`frontend/layout/lib/types.ts:305-315` `LayoutTreeState`). This is a
/// SEPARATE object from `Tab` (GUARDS §L); it is built from / written back to the
/// `LayoutState` referenced by `Tab.layoutstate`.
public struct LayoutTreeState: Sendable, Equatable {
    public var rootNode: LayoutNode?
    public var focusedNodeId: String?
    public var magnifiedNodeId: String?
    /// Computed ordered leaf list (driven by `LayoutReducer.updateTree`).
    public var leafOrder: [LeafOrderEntry]?
    /// Backend-queued structural changes awaiting apply-and-clear (GUARDS §L).
    public var pendingBackendActions: [LayoutActionData]?

    public init(
        rootNode: LayoutNode? = nil,
        focusedNodeId: String? = nil,
        magnifiedNodeId: String? = nil,
        leafOrder: [LeafOrderEntry]? = nil,
        pendingBackendActions: [LayoutActionData]? = nil
    ) {
        self.rootNode = rootNode
        self.focusedNodeId = focusedNodeId
        self.magnifiedNodeId = magnifiedNodeId
        self.leafOrder = leafOrder
        self.pendingBackendActions = pendingBackendActions
    }
}

/// Pure reducer over `LayoutTreeState`. `apply` mutates structure only; call
/// `updateTree` afterward (the renderer does this inside `updateTree`) to rebalance
/// and recompute the leaf order / focus / magnify validity.
public enum LayoutReducer {

    /// Apply a single structural action (`treeReducer`, `layoutModel.ts:615-700`).
    public static func apply(_ action: LayoutTreeAction, to state: inout LayoutTreeState) {
        switch action {
        case let .insertNode(node, magnified, focused):
            insertNode(&state, node: node, magnified: magnified, focused: focused)
        case let .insertNodeAtIndex(node, indexArr, magnified, focused):
            insertNodeAtIndex(&state, node: node, indexArr: indexArr, magnified: magnified, focused: focused)
        case let .deleteNode(nodeId):
            deleteNode(&state, nodeId: nodeId)
        case let .resizeNode(ops):
            resizeNode(&state, operations: ops)
        case let .splitHorizontal(targetNodeId, newNode, position, focused):
            split(&state, axis: .row, targetNodeId: targetNodeId, newNode: newNode, position: position, focused: focused)
        case let .splitVertical(targetNodeId, newNode, position, focused):
            split(&state, axis: .column, targetNodeId: targetNodeId, newNode: newNode, position: position, focused: focused)
        case let .replaceNode(targetNodeId, newNode, focused):
            replaceNode(&state, targetNodeId: targetNodeId, newNode: newNode, focused: focused)
        case let .swapNode(node1Id, node2Id):
            swapNode(&state, node1Id: node1Id, node2Id: node2Id)
        case let .moveNode(op):
            moveNode(&state, op: op)
        case .clearTree:
            clearTree(&state)
        case let .focusNode(nodeId):
            state.focusedNodeId = nodeId
        case let .magnifyNodeToggle(nodeId):
            magnifyNodeToggle(&state, nodeId: nodeId)
        }
    }

    /// `updateTree` (`layoutModel.ts:724-775`): rebalance the tree, recompute the
    /// leaf order, and drop a focused/magnified id that no longer points at a leaf.
    public static func updateTree(_ state: inout LayoutTreeState, balance: Bool = true) {
        if balance, state.rootNode != nil {
            LayoutTree.balanceNode(&state.rootNode!)
        }
        let order = LayoutTree.leafOrder(state.rootNode)
        state.leafOrder = order
        validateFocusedNode(&state, leafOrder: order)
        validateMagnifiedNode(&state, leafOrder: order)
    }

    // MARK: - Insert (`layoutTree.ts:279-321`)

    private static func insertNode(_ state: inout LayoutTreeState, node: LayoutNode, magnified: Bool, focused: Bool) {
        guard state.rootNode != nil else {
            state.rootNode = node
            if focused { state.focusedNodeId = node.id }
            return
        }
        if let loc = LayoutTree.findNextInsertLocation(state.rootNode!, maxChildren: layoutDefaultMaxChildren) {
            LayoutTree.updateNode(&state.rootNode!, id: loc.node.id) {
                LayoutTree.addChildAt(&$0, idx: loc.index, children: [node])
            }
        }
        if magnified {
            state.magnifiedNodeId = node.id
            state.focusedNodeId = node.id
        }
        if focused { state.focusedNodeId = node.id }
    }

    private static func insertNodeAtIndex(
        _ state: inout LayoutTreeState, node: LayoutNode, indexArr: [Int], magnified: Bool, focused: Bool
    ) {
        guard state.rootNode != nil else {
            state.rootNode = node
            if focused { state.focusedNodeId = node.id }
            return
        }
        guard let loc = LayoutTree.findInsertLocationFromIndexArr(state.rootNode!, indexArr) else {
            return
        }
        LayoutTree.updateNode(&state.rootNode!, id: loc.node.id) {
            LayoutTree.addChildAt(&$0, idx: loc.index + 1, children: [node])
        }
        if magnified {
            state.magnifiedNodeId = node.id
            state.focusedNodeId = node.id
        }
        if focused { state.focusedNodeId = node.id }
    }

    // MARK: - Delete (`layoutTree.ts:354-377`)

    private static func deleteNode(_ state: inout LayoutTreeState, nodeId: String) {
        guard state.rootNode != nil else { return }
        if state.rootNode!.id == nodeId {
            state.rootNode = nil
            if state.focusedNodeId == nodeId { state.focusedNodeId = nil }
            return
        }
        LayoutTree.updateParent(&state.rootNode!, childId: nodeId) { parent, idx in
            parent.children!.remove(at: idx)
        }
        if state.focusedNodeId == nodeId { state.focusedNodeId = nil }
    }

    // MARK: - Resize (`layoutTree.ts:379-391`)

    private static func resizeNode(_ state: inout LayoutTreeState, operations: [ResizeOperation]) {
        guard state.rootNode != nil else { return }
        for op in operations {
            // Mirror the renderer guard: a single bad op aborts the whole batch.
            if op.nodeId.isEmpty || op.size < 0 || op.size > 100 { return }
        }
        for op in operations {
            LayoutTree.updateNode(&state.rootNode!, id: op.nodeId) { $0.size = op.size }
        }
    }

    // MARK: - Split (`layoutTree.ts:454-534`)

    private static func split(
        _ state: inout LayoutTreeState, axis: FlexDirection, targetNodeId: String,
        newNode: LayoutNode, position: SplitPosition, focused: Bool
    ) {
        guard let targetNode = LayoutTree.findNode(state.rootNode, id: targetNodeId) else { return }
        let parentId = LayoutTree.findParentId(state.rootNode, childId: targetNodeId)

        let parentMatchesAxis: Bool = {
            guard let parentId, let parent = LayoutTree.findNode(state.rootNode, id: parentId) else { return false }
            return parent.flexDirection == axis
        }()

        if let parentId, parentMatchesAxis {
            LayoutTree.updateNode(&state.rootNode!, id: parentId) { parent in
                guard let idx = parent.children!.firstIndex(where: { $0.id == targetNodeId }) else { return }
                let insertIndex = position == .before ? idx : idx + 1
                parent.children!.insert(newNode, at: insertIndex)
            }
        } else {
            var groupNode = LayoutTree.newNode(flexDirection: axis, size: targetNode.size, children: [targetNode])
            groupNode.children = position == .before ? [newNode, targetNode] : [targetNode, newNode]
            if let parentId {
                LayoutTree.updateNode(&state.rootNode!, id: parentId) { parent in
                    if let idx = parent.children!.firstIndex(where: { $0.id == targetNodeId }) {
                        parent.children![idx] = groupNode
                    }
                }
            } else {
                state.rootNode = groupNode
            }
        }
        if focused { state.focusedNodeId = newNode.id }
    }

    // MARK: - Replace (`layoutTree.ts:426-450`)

    private static func replaceNode(
        _ state: inout LayoutTreeState, targetNodeId: String, newNode: LayoutNode, focused: Bool
    ) {
        guard let root = state.rootNode else { return }
        if root.id == targetNodeId {
            var replacement = newNode
            replacement.size = root.size
            state.rootNode = replacement
        } else {
            guard let parentId = LayoutTree.findParentId(state.rootNode, childId: targetNodeId) else { return }
            LayoutTree.updateNode(&state.rootNode!, id: parentId) { parent in
                guard let idx = parent.children!.firstIndex(where: { $0.id == targetNodeId }) else { return }
                var replacement = newNode
                replacement.size = parent.children![idx].size
                parent.children![idx] = replacement
            }
        }
        if focused { state.focusedNodeId = newNode.id }
    }

    // MARK: - Swap (`layoutTree.ts:323-352`)

    private static func swapNode(_ state: inout LayoutTreeState, node1Id: String, node2Id: String) {
        guard let root = state.rootNode else { return }
        if node1Id == root.id || node2Id == root.id || node1Id == node2Id { return }
        guard
            let loc1 = LayoutTree.parentAndIndex(state.rootNode, childId: node1Id),
            let loc2 = LayoutTree.parentAndIndex(state.rootNode, childId: node2Id),
            var node1 = LayoutTree.findNode(state.rootNode, id: node1Id),
            var node2 = LayoutTree.findNode(state.rootNode, id: node2Id)
        else { return }

        let node1Size = node1.size
        node1.size = node2.size
        node2.size = node1Size

        if loc1.parentId == loc2.parentId {
            LayoutTree.updateNode(&state.rootNode!, id: loc1.parentId) { parent in
                parent.children![loc1.index] = node2
                parent.children![loc2.index] = node1
            }
        } else {
            LayoutTree.updateNode(&state.rootNode!, id: loc1.parentId) { $0.children![loc1.index] = node2 }
            LayoutTree.updateNode(&state.rootNode!, id: loc2.parentId) { $0.children![loc2.index] = node1 }
        }
    }

    // MARK: - Move (`layoutTree.ts:230-277`)

    private static func moveNode(_ state: inout LayoutTreeState, op: MoveOperation) {
        guard state.rootNode != nil else { return }
        if op.parentId != nil && op.insertAtRoot { return }

        var node = LayoutTree.findNode(state.rootNode, id: op.node.id) ?? op.node
        let oldParentId = LayoutTree.findParentId(state.rootNode, childId: op.node.id)

        var startingIndex = 0
        if let oldParentId, let parentId = op.parentId {
            if oldParentId == parentId {
                if let curIdx = LayoutTree.parentAndIndex(state.rootNode, childId: op.node.id)?.index,
                   curIdx >= op.index {
                    startingIndex = op.index + 1
                }
            } else {
                node.size = LayoutNode.defaultSize
            }
        }

        if op.parentId == nil, op.insertAtRoot {
            if state.rootNode!.children == nil {
                _ = LayoutTree.addIntermediateNode(&state.rootNode!)
            }
            LayoutTree.addChildAt(&state.rootNode!, idx: op.index, children: [node])
        } else if let parentId = op.parentId {
            LayoutTree.updateNode(&state.rootNode!, id: parentId) {
                LayoutTree.addChildAt(&$0, idx: op.index, children: [node])
            }
        } else {
            return
        }

        if let oldParentId {
            LayoutTree.updateNode(&state.rootNode!, id: oldParentId) {
                LayoutTree.removeChild(&$0, childId: node.id, startingIndex: startingIndex)
            }
        }
    }

    // MARK: - Clear / magnify (`layoutTree.ts:402-424`)

    private static func clearTree(_ state: inout LayoutTreeState) {
        state.rootNode = nil
        state.leafOrder = nil
        state.focusedNodeId = nil
        state.magnifiedNodeId = nil
    }

    private static func magnifyNodeToggle(_ state: inout LayoutTreeState, nodeId: String) {
        guard let root = state.rootNode, root.id != nodeId else { return }
        if state.magnifiedNodeId == nodeId {
            state.magnifiedNodeId = nil
        } else {
            state.magnifiedNodeId = nodeId
            state.focusedNodeId = nodeId
        }
    }

    // MARK: - Focus / magnify validation (`layoutModel.ts:908-945`)

    private static func validateFocusedNode(_ state: inout LayoutTreeState, leafOrder: [LeafOrderEntry]) {
        guard let focused = state.focusedNodeId else {
            state.focusedNodeId = leafOrder.first?.nodeid
            return
        }
        if leafOrder.contains(where: { $0.nodeid == focused }) { return }
        state.focusedNodeId = leafOrder.first?.nodeid
    }

    private static func validateMagnifiedNode(_ state: inout LayoutTreeState, leafOrder: [LeafOrderEntry]) {
        guard let magnified = state.magnifiedNodeId else { return }
        // A single remaining leaf cannot stay magnified (renderer drops it).
        if leafOrder.count <= 1 || !leafOrder.contains(where: { $0.nodeid == magnified }) {
            state.magnifiedNodeId = nil
        }
    }
}
