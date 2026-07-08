// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveLayout — reducer action types.
//
// Implements PROTOCOL.md §6. The `LayoutActionType` string constants mirror BOTH
// the backend `LayoutActionData.actiontype` values (`pkg/wcore/layout.go:18-26`)
// and the renderer's `LayoutTreeActionType` enum
// (`frontend/layout/lib/types.ts:74-92`) — they share the same wire strings, so a
// queued `pendingbackendactions` entry maps 1:1 onto a reducer action.

import Foundation
import WaveCore

/// Wire-string constants for layout actions. These match the Go backend
/// (`pkg/wcore/layout.go:18-26`) and the renderer enum 1:1, which is what lets a
/// backend-queued action (`LayoutActionData.actiontype`) drive the reducer.
public enum LayoutActionType {
    public static let insert = "insert"
    public static let insertAtIndex = "insertatindex"
    public static let delete = "delete"
    /// Removes a block's layout node WITHOUT deleting the block itself (unlike
    /// `delete`, which triggers a client-side DeleteBlock). Queued by the backend
    /// when a block moves to another tab.
    public static let removeNode = "removenode"
    public static let clearTree = "clear"
    public static let replace = "replace"
    public static let splitHorizontal = "splithorizontal"
    public static let splitVertical = "splitvertical"
    public static let cleanupOrphaned = "cleanuporphaned"

    // Reducer-only actions (driven by the UI, never queued by the backend).
    public static let move = "move"
    public static let swap = "swap"
    public static let resize = "resize"
    public static let focus = "focus"
    public static let magnify = "magnify"
}

/// Split insertion side (`"before" | "after"`, `frontend/layout/lib/types.ts:222`).
public enum SplitPosition: String, Sendable {
    case before
    case after
}

/// A single node resize (`ResizeNodeOperation`, `types.ts:236-247`).
public struct ResizeOperation: Sendable, Equatable {
    public let nodeId: String
    public let size: Double
    public init(nodeId: String, size: Double) {
        self.nodeId = nodeId
        self.size = size
    }
}

/// A computed move (`MoveOperation`, `types.ts`): where to drop `node`. Either
/// `parentId` or `insertAtRoot` is set, never both.
public struct MoveOperation: Sendable {
    public var parentId: String?
    public var index: Int
    public var insertAtRoot: Bool
    public var node: LayoutNode
    public init(parentId: String? = nil, index: Int, insertAtRoot: Bool = false, node: LayoutNode) {
        self.parentId = parentId
        self.index = index
        self.insertAtRoot = insertAtRoot
        self.node = node
    }
}

/// A structural action against the layout tree (the reducer input). Mirrors the
/// renderer's `LayoutTreeAction` variants that mutate the persisted tree
/// (`frontend/layout/lib/layoutTree.ts`). Geometry-driven gesture computation
/// (`computeMoveNode`) and the throttled drag-preview/pending-action machinery are
/// view concerns and live in WaveUI, not here — see the module notes.
public enum LayoutTreeAction: Sendable {
    case insertNode(node: LayoutNode, magnified: Bool = false, focused: Bool = false)
    case insertNodeAtIndex(node: LayoutNode, indexArr: [Int], magnified: Bool = false, focused: Bool = false)
    case deleteNode(nodeId: String)
    case resizeNode([ResizeOperation])
    case splitHorizontal(targetNodeId: String, newNode: LayoutNode, position: SplitPosition, focused: Bool = false)
    case splitVertical(targetNodeId: String, newNode: LayoutNode, position: SplitPosition, focused: Bool = false)
    case replaceNode(targetNodeId: String, newNode: LayoutNode, focused: Bool = false)
    case swapNode(node1Id: String, node2Id: String)
    case moveNode(MoveOperation)
    case clearTree
    case focusNode(nodeId: String)
    case magnifyNodeToggle(nodeId: String)
}
