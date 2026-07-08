// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveLayout — pure node-tree primitives.
//
// Implements PROTOCOL.md §6 ("Node tree: recursive LayoutNode { id, data?{ blockId },
// children?[], flexDirection, size }") and encodes GUARDS §L (size defaults to 10;
// flexDirection is "row"|"column"; a node holds children XOR data).
//
// Faithful value-type port of the Electron renderer's tree helpers
// `frontend/layout/lib/layoutNode.ts` and the `balanceNode` walk. The renderer
// mutates LayoutNode object references in place; here LayoutNode is a Swift value
// type, so mutation flows through `inout` and recursive index-path helpers
// (`updateNode` / `updateParent`) rather than retained references.

import Foundation
import WaveCore

/// Maximum children a node may hold before insertion descends a level
/// (`frontend/layout/lib/layoutTree.ts:35` — `DEFAULT_MAX_CHILDREN`).
public let layoutDefaultMaxChildren = 5

/// Pure operations over the `LayoutNode` tree (PROTOCOL.md §6). All functions are
/// value-type: they take `inout LayoutNode` (or return a new node) instead of
/// mutating a shared reference.
public enum LayoutTree {

    // MARK: - Construction (`layoutNode.ts:16-34`)

    /// `reverseFlexDirection` (`frontend/layout/lib/utils.ts`).
    public static func reverse(_ dir: FlexDirection) -> FlexDirection {
        dir == .row ? .column : .row
    }

    /// `newLayoutNode` (`layoutNode.ts:16-34`). GUARDS §L: `size` defaults to 10,
    /// `flexDirection` defaults to `.row`; a node is valid only when it has
    /// children XOR data.
    public static func newNode(
        flexDirection: FlexDirection = .row,
        size: Double = LayoutNode.defaultSize,
        children: [LayoutNode]? = nil,
        data: TabLayoutData? = nil
    ) -> LayoutNode {
        let node = LayoutNode(
            id: UUID().uuidString.lowercased(),
            data: data,
            children: children,
            flexDirection: flexDirection,
            size: size
        )
        assert(validateNode(node), "newNode produced an invalid LayoutNode (GUARDS §L)")
        return node
    }

    /// Convenience: a leaf node wrapping a block (`data.blockId`).
    public static func newLeaf(blockId: String, size: Double = LayoutNode.defaultSize) -> LayoutNode {
        newNode(size: size, data: TabLayoutData(blockId: blockId))
    }

    /// `validateNode` (`layoutNode.ts:145-156`): exactly one of children/data, and
    /// no empty children array (GUARDS §L structural invariant).
    public static func validateNode(_ node: LayoutNode) -> Bool {
        if (node.children == nil) == (node.data == nil) { return false }
        if node.children?.isEmpty == true { return false }
        return true
    }

    // MARK: - Read-only search (`layoutNode.ts:113-138`)

    /// `findNode` (`layoutNode.ts:113-122`) — returns a copy of the matching node.
    public static func findNode(_ node: LayoutNode?, id: String) -> LayoutNode? {
        guard let node else { return nil }
        if node.id == id { return node }
        guard let children = node.children else { return nil }
        for child in children {
            if let found = findNode(child, id: id) { return found }
        }
        return nil
    }

    /// Find the leaf whose `data.blockId` matches (renderer `getNodeByBlockId`).
    public static func findNodeByBlockId(_ node: LayoutNode?, blockId: String) -> LayoutNode? {
        guard let node else { return nil }
        if node.data?.blockId == blockId { return node }
        guard let children = node.children else { return nil }
        for child in children {
            if let found = findNodeByBlockId(child, blockId: blockId) { return found }
        }
        return nil
    }

    /// `findParent` (`layoutNode.ts:130-138`) — the id of the node whose children
    /// contain `childId`.
    public static func findParentId(_ node: LayoutNode?, childId: String) -> String? {
        guard let node, let children = node.children else { return nil }
        if children.contains(where: { $0.id == childId }) { return node.id }
        for child in children {
            if let found = findParentId(child, childId: childId) { return found }
        }
        return nil
    }

    /// (parentId, index-in-parent) for `childId`, or nil if it is the root / absent.
    public static func parentAndIndex(_ node: LayoutNode?, childId: String) -> (parentId: String, index: Int)? {
        guard let node, let children = node.children else { return nil }
        if let idx = children.firstIndex(where: { $0.id == childId }) {
            return (node.id, idx)
        }
        for child in children {
            if let found = parentAndIndex(child, childId: childId) { return found }
        }
        return nil
    }

    // MARK: - In-place mutation helpers (value-type stand-in for JS references)

    /// Find the node with `id` and apply `body` to it in place. Returns whether it
    /// was found.
    @discardableResult
    public static func updateNode(
        _ node: inout LayoutNode, id: String, _ body: (inout LayoutNode) -> Void
    ) -> Bool {
        if node.id == id {
            body(&node)
            return true
        }
        guard node.children != nil else { return false }
        for i in node.children!.indices {
            if updateNode(&node.children![i], id: id, body) { return true }
        }
        return false
    }

    /// Find the parent of `childId` and apply `body(parent, index)` in place.
    @discardableResult
    public static func updateParent(
        _ node: inout LayoutNode, childId: String, _ body: (inout LayoutNode, Int) -> Void
    ) -> Bool {
        guard node.children != nil else { return false }
        if let idx = node.children!.firstIndex(where: { $0.id == childId }) {
            body(&node, idx)
            return true
        }
        for i in node.children!.indices {
            if updateParent(&node.children![i], childId: childId, body) { return true }
        }
        return false
    }

    // MARK: - Structural ops (`layoutNode.ts:43-105`)

    /// `addIntermediateNode` (`layoutNode.ts:75-91`): wrap the node's data/children
    /// one or two levels deeper, swapping ids so the original id stays at the top.
    /// Returns the inserted intermediate node (as a value).
    @discardableResult
    public static func addIntermediateNode(_ node: inout LayoutNode) -> LayoutNode {
        var intermediate: LayoutNode
        if let data = node.data {
            intermediate = newNode(flexDirection: reverse(node.flexDirection), data: data)
            node.data = nil
        } else {
            let inner = newNode(flexDirection: node.flexDirection, children: node.children)
            intermediate = newNode(flexDirection: reverse(node.flexDirection), children: [inner])
        }
        let intermediateId = intermediate.id
        intermediate.id = node.id
        node.id = intermediateId
        node.children = [intermediate]
        return intermediate
    }

    /// `addChildAt` (`layoutNode.ts:43-66`): insert `children` at `idx`, flattening
    /// same-flex-direction children and adding an intermediate node when needed.
    public static func addChildAt(_ node: inout LayoutNode, idx: Int, children: [LayoutNode]) {
        if children.isEmpty { return }
        if node.children == nil {
            _ = addIntermediateNode(&node)
        }
        var toAdd: [LayoutNode] = []
        for var v in children {
            if v.flexDirection != node.flexDirection {
                toAdd.append(v)
            } else if let grand = v.children {
                toAdd.append(contentsOf: grand)
            } else {
                v.flexDirection = reverse(node.flexDirection)
                toAdd.append(v)
            }
        }
        if node.children!.count <= idx {
            node.children!.append(contentsOf: toAdd)
        } else if idx >= 0 {
            node.children!.insert(contentsOf: toAdd, at: idx)
        }
    }

    /// `removeChild` (`layoutNode.ts:100-105`): remove the first child with `childId`
    /// found at or after `startingIndex`.
    public static func removeChild(_ parent: inout LayoutNode, childId: String, startingIndex: Int = 0) {
        guard let children = parent.children else { return }
        var idx: Int? = nil
        for i in children.indices where i >= startingIndex && children[i].id == childId {
            idx = i
            break
        }
        guard let removeAt = idx else { return }
        parent.children!.remove(at: removeAt)
    }

    // MARK: - Insert-location search (`layoutNode.ts:227-285`)

    /// `findNextInsertLocation` (`layoutNode.ts:227-281`): the first node/index where
    /// a new node can be inserted, filling each node to `maxChildren` breadth-first.
    public static func findNextInsertLocation(
        _ node: LayoutNode, maxChildren: Int = layoutDefaultMaxChildren
    ) -> (node: LayoutNode, index: Int)? {
        guard let loc = findNextInsertLocationHelper(node, maxChildren, 1) else { return nil }
        return (loc.node, loc.index)
    }

    private static func findNextInsertLocationHelper(
        _ node: LayoutNode, _ maxChildren: Int, _ curDepth: Int
    ) -> (node: LayoutNode, index: Int, depth: Int)? {
        guard let children = node.children else { return (node, 1, curDepth) }
        var locs: [(node: LayoutNode, index: Int, depth: Int)] = []
        if children.count < maxChildren {
            locs.append((node, children.count, curDepth))
        }
        for child in children.reversed() {
            if let loc = findNextInsertLocationHelper(child, maxChildren, curDepth + 1) {
                locs.append(loc)
            }
        }
        locs.sort {
            pow(Double($0.depth), Double($0.index + maxChildren))
                < pow(Double($1.depth), Double($1.index + maxChildren))
        }
        return locs.first
    }

    /// `findInsertLocationFromIndexArr` (`layoutNode.ts:241-261`): traverse using the
    /// backend-provided index path, normalizing each index against the current node.
    public static func findInsertLocationFromIndexArr(
        _ node: LayoutNode, _ indexArr: [Int]
    ) -> (node: LayoutNode, index: Int)? {
        if indexArr.isEmpty { return nil }
        var arr = indexArr
        let raw = arr.removeFirst()
        let childrenLength = node.children?.count ?? 1
        let lastChildIndex = childrenLength - 1
        let nextIndex: Int
        if raw < 0 {
            nextIndex = childrenLength - max(raw, -childrenLength)
        } else {
            nextIndex = min(raw, lastChildIndex)
        }
        if arr.isEmpty || node.children == nil {
            return (node, nextIndex)
        }
        return findInsertLocationFromIndexArr(node.children![nextIndex], arr)
    }

    // MARK: - Balance (`layoutNode.ts:182-214`)

    /// `balanceNode` (`layoutNode.ts:182-214`): minimize nested single-child nodes,
    /// drop empty children, and correct flex-direction order. GUARDS §L invariant:
    /// every visited node is valid (children XOR data).
    @discardableResult
    public static func balanceNode(_ node: inout LayoutNode) -> LayoutNode {
        precondition(validateNode(node), "balanceNode visited an invalid node (GUARDS §L)")

        // BEFORE: flatten same-direction wrappers and lift single grandchildren.
        if let children = node.children {
            var restructured: [LayoutNode] = []
            for var child in children {
                if child.flexDirection == node.flexDirection {
                    child.flexDirection = reverse(node.flexDirection)
                }
                if let grand = child.children, grand.count == 1, grand[0].children != nil {
                    restructured.append(contentsOf: grand[0].children!)
                } else if child.children?.isEmpty == true {
                    continue
                } else {
                    restructured.append(child)
                }
            }
            node.children = restructured
        }

        // RECURSE
        if node.children != nil {
            for i in node.children!.indices {
                balanceNode(&node.children![i])
            }
        }

        // AFTER: collapse a single leaf child into this node.
        if let children = node.children {
            if children.count == 1, children[0].children == nil {
                node.data = children[0].data
                node.id = children[0].id
                node.children = nil
            }
        }
        return node
    }

    // MARK: - Leaf order (`layoutModel.ts:1572-1583`)

    /// Computed ordered leaf list (`getLeafOrder`). The renderer sorts leaves by a
    /// concatenated per-level index `treeKey`; with `maxChildren == 5` that is exactly
    /// a pre-order depth-first traversal of the leaves, which we compute directly.
    public static func leafOrder(_ root: LayoutNode?) -> [LeafOrderEntry] {
        var result: [LeafOrderEntry] = []
        func walk(_ node: LayoutNode) {
            if let children = node.children, !children.isEmpty {
                for child in children { walk(child) }
            } else if let blockId = node.data?.blockId {
                result.append(LeafOrderEntry(nodeid: node.id, blockid: blockId))
            }
        }
        if let root { walk(root) }
        return result
    }

    /// `totalChildrenSize` (`layoutNode.ts:283-285`).
    public static func totalChildrenSize(_ node: LayoutNode) -> Double {
        node.children?.reduce(0) { $0 + $1.size } ?? 0
    }
}
