// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveLayout — pure drag-and-drop geometry → reducer-action mapping.
//
// Ports the renderer's `determineDropDirection` (`frontend/layout/lib/utils.ts`)
// and `computeMoveNode` (`frontend/layout/lib/layoutTree.ts:43-228`). The view
// layer (WaveUI) only feeds a hovered target rect + cursor offset in and gets a
// `LayoutTreeAction` (a `swapNode` for center drops, a `moveNode` for edges) back,
// so all the index/parent arithmetic stays unit-testable without AppKit.

import CoreGraphics
import WaveCore

/// Which zone of a target pane a drop landed in. Raw values match the renderer's
/// `DropDirection` enum (`types.ts:29-39`) so the `computeMoveAction` switch is a
/// 1:1 port.
public enum DropDirection: Int, Sendable {
    case top = 0
    case right = 1
    case bottom = 2
    case left = 3
    case outerTop = 4
    case outerRight = 5
    case outerBottom = 6
    case outerLeft = 7
    case center = 8
}

public enum LayoutMove {
    /// Classify a cursor `point` (relative to the target's top-left, y-down) within a
    /// `size` box into a drop zone: the center fifth → `.center`; the inner triangle
    /// touching each edge → `.top/.right/.bottom/.left`; the outer fifth nearest an
    /// edge → the matching `.outer*`. Returns nil when the point is outside the box or
    /// sits exactly on a diagonal (ambiguous). Direct port of `determineDropDirection`.
    public static func determineDropDirection(in size: CGSize, at point: CGPoint) -> DropDirection? {
        let width = size.width
        let height = size.height
        let x = point.x
        let y = point.y
        if y < 0 || y > height || x < 0 || x > width { return nil }

        let centerX1 = (2 * width) / 5
        let centerX2 = (3 * width) / 5
        let centerY1 = (2 * height) / 5
        let centerY2 = (3 * height) / 5
        if x > centerX1 && x < centerX2 && y > centerY1 && y < centerY2 { return .center }

        let diagonal1 = y * width - x * height
        let diagonal2 = y * width + x * height - height * width
        if diagonal1 == 0 || diagonal2 == 0 { return nil }

        var code = 0
        if diagonal2 > 0 { code += 1 }
        if diagonal1 > 0 {
            code += 2
            code = 5 - code
        }

        let xOuter1 = width / 5
        let xOuter2 = width - width / 5
        let yOuter1 = height / 5
        let yOuter2 = height - height / 5
        if y < yOuter1 || y > yOuter2 || x < xOuter1 || x > xOuter2 { code += 4 }

        return DropDirection(rawValue: code)
    }

    /// Compute the reducer action for dropping `nodeToMoveId` onto `targetNodeId` in a
    /// given `direction`. Center → `swapNode`; an edge → `moveNode` placing the node
    /// next to (or wrapping out a level from) the target. Returns nil for self-drops,
    /// missing nodes, or a move that would land the node back where it already is
    /// (the dedup guard mirrors `computeMoveNode`'s trailing check).
    public static func computeMoveAction(
        root: LayoutNode?, targetNodeId: String, nodeToMoveId: String, direction: DropDirection
    ) -> LayoutTreeAction? {
        guard let root else { return nil }
        if targetNodeId.isEmpty || nodeToMoveId.isEmpty || targetNodeId == nodeToMoveId { return nil }
        guard let node = LayoutTree.findNode(root, id: targetNodeId),
              let nodeToMove = LayoutTree.findNode(root, id: nodeToMoveId)
        else { return nil }

        if direction == .center {
            if targetNodeId != root.id && nodeToMoveId != root.id {
                return .swapNode(node1Id: targetNodeId, node2Id: nodeToMoveId)
            }
            return nil
        }

        let isRoot = root.id == targetNodeId
        let parentLoc = LayoutTree.parentAndIndex(root, childId: targetNodeId)
        let parentId = parentLoc?.parentId
        let indexInParent = parentLoc?.index
        let grandparentLoc = parentId.flatMap { LayoutTree.parentAndIndex(root, childId: $0) }
        let grandparentId = grandparentLoc?.parentId
        let indexInGrandparent = grandparentLoc?.index
        let isColumn = node.flexDirection == .column
        let isRow = node.flexDirection == .row

        var move: MoveOperation?
        switch direction {
        case .center:
            return nil
        case .outerTop:
            if isColumn, let gp = grandparentId, let idx = indexInGrandparent {
                move = MoveOperation(parentId: gp, index: idx, node: nodeToMove)
                break
            }
            fallthrough
        case .top:
            if isColumn {
                move = MoveOperation(parentId: targetNodeId, index: 0, node: nodeToMove)
            } else if isRoot {
                move = MoveOperation(index: 0, insertAtRoot: true, node: nodeToMove)
            } else if let p = parentId {
                move = MoveOperation(parentId: p, index: indexInParent ?? 0, node: nodeToMove)
            }
        case .outerBottom:
            if isColumn, let gp = grandparentId, let idx = indexInGrandparent {
                move = MoveOperation(parentId: gp, index: idx + 1, node: nodeToMove)
                break
            }
            fallthrough
        case .bottom:
            if isColumn {
                move = MoveOperation(parentId: targetNodeId, index: 1, node: nodeToMove)
            } else if isRoot {
                move = MoveOperation(index: 1, insertAtRoot: true, node: nodeToMove)
            } else if let p = parentId, let idx = indexInParent {
                move = MoveOperation(parentId: p, index: idx + 1, node: nodeToMove)
            }
        case .outerLeft:
            if isRow, let gp = grandparentId, let idx = indexInGrandparent {
                move = MoveOperation(parentId: gp, index: idx, node: nodeToMove)
                break
            }
            fallthrough
        case .left:
            if isRow {
                move = MoveOperation(parentId: targetNodeId, index: 0, node: nodeToMove)
            } else if let p = parentId, let idx = indexInParent {
                move = MoveOperation(parentId: p, index: idx, node: nodeToMove)
            }
        case .outerRight:
            if isRow, let gp = grandparentId, let idx = indexInGrandparent {
                move = MoveOperation(parentId: gp, index: idx + 1, node: nodeToMove)
                break
            }
            fallthrough
        case .right:
            if isRow {
                move = MoveOperation(parentId: targetNodeId, index: 1, node: nodeToMove)
            } else if let p = parentId, let idx = indexInParent {
                move = MoveOperation(parentId: p, index: idx + 1, node: nodeToMove)
            }
        }

        guard let op = move else { return nil }
        let movedLoc = LayoutTree.parentAndIndex(root, childId: nodeToMoveId)
        let sameParent = (op.parentId == movedLoc?.parentId)
        if sameParent, let curIdx = movedLoc?.index, op.index == curIdx || op.index == curIdx + 1 {
            return nil
        }
        return .moveNode(op)
    }
}
