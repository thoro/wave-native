// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — renders a `LayoutState` node tree into tiled block frames.
// Implements PROTOCOL.md §6 (node tree: flexDirection row|column, size weights)
// and STYLE.md §5/§7 (3px tile gap, 8px block radius via BlockFrameView).
// Encodes GUARDS §L: `size` defaults to 10; `flexDirection` is row|column; the
// tree is consumed from the SEPARATE `LayoutState` object (Tab.layoutstate).
//
// The geometry is split into a PURE function (`LayoutTiler`) so the row/column +
// size-weight + gap math is unit-tested without AppKit (Tests/WaveUITests).

import AppKit
import WaveCore
import WaveLayout

/// A computed placement of one leaf block within a rect.
struct LayoutLeafFrame: Equatable, Sendable {
    let nodeId: String
    let blockId: String
    let frame: CGRect
    init(nodeId: String, blockId: String, frame: CGRect) {
        self.nodeId = nodeId
        self.blockId = blockId
        self.frame = frame
    }
}

/// The linear key-frame track of one pane during a split/resize transition: its frame
/// interpolates from `start` to `end` (Core Animation linear timing). `frame(at:)` gives the
/// frame at a time fraction in [0, 1], so the intended animation can be asserted at key timings
/// without running Core Animation.
struct PaneKeyframes: Equatable {
    let blockId: String
    let start: CGRect
    let end: CGRect
    func frame(at t: CGFloat) -> CGRect {
        CGRect(
            x: start.minX + (end.minX - start.minX) * t,
            y: start.minY + (end.minY - start.minY) * t,
            width: start.width + (end.width - start.width) * t,
            height: start.height + (end.height - start.height) * t)
    }
}

/// A draggable boundary between two adjacent sibling nodes in a flex container.
/// `frame` is the gap rect; dragging it trades size-weight between the two nodes.
struct LayoutSplitter: Equatable, Sendable {
    let beforeNodeId: String
    let afterNodeId: String
    /// Parent flexDirection == .row → a vertical bar dragged left/right.
    let horizontal: Bool
    let frame: CGRect
    let beforeWeight: Double
    let afterWeight: Double
    /// The parent container's usable axis length in px (axis length minus gaps) and
    /// the sum of all sibling weights — together they convert a pixel drag delta into
    /// a weight delta (`weightPerPixel = weightSum / usableLength`).
    let usableLength: CGFloat
    let weightSum: Double

    var key: String { "\(beforeNodeId)|\(afterNodeId)" }
}

/// Pure tiling math for the layout node tree (PROTOCOL §6, GUARDS §L).
enum LayoutTiler {
    /// Compute leaf frames for `root` filling `bounds`. Coordinates are top-left
    /// origin (use in a flipped NSView). `gap` is inserted between siblings.
    static func computeFrames(
        root: LayoutNode?, in bounds: CGRect, gap: CGFloat = Theme.blockTileGap,
        magnifiedNodeId: String? = nil
    ) -> [LayoutLeafFrame] {
        guard let root else { return [] }
        var out: [LayoutLeafFrame] = []
        place(node: root, in: bounds, gap: gap, into: &out)
        guard let magnifiedNodeId,
              let idx = out.firstIndex(where: { $0.nodeId == magnifiedNodeId })
        else { return out }
        // Magnify (Electron parity — `window:magnifiedblocksize` 0.95): the magnified
        // leaf floats centered at 95% of the area, OVER its still-tiled siblings (the
        // view layer dims them behind it and raises this one with a shadow). Sibling
        // frames are kept at their normal positions so the block-view cache — and thus
        // the sibling terminals — survive the toggle (dropping them would remount and
        // re-run backfill).
        let leaf = out[idx]
        let magnifySize: CGFloat = 0.95
        let w = (bounds.width * magnifySize).rounded()
        let h = (bounds.height * magnifySize).rounded()
        let frame = CGRect(
            x: bounds.minX + ((bounds.width - w) / 2).rounded(),
            y: bounds.minY + ((bounds.height - h) / 2).rounded(),
            width: w, height: h
        ).integralPixels
        out[idx] = LayoutLeafFrame(nodeId: leaf.nodeId, blockId: leaf.blockId, frame: frame)
        return out
    }

    private static func place(
        node: LayoutNode, in rect: CGRect, gap: CGFloat, into out: inout [LayoutLeafFrame]
    ) {
        // Leaf: a node carrying a blockId (and no children) renders a block.
        if let blockId = node.data?.blockId, (node.children?.isEmpty ?? true) {
            out.append(LayoutLeafFrame(nodeId: node.id, blockId: blockId, frame: rect.integralPixels))
            return
        }
        guard let children = node.children, !children.isEmpty else { return }

        let horizontal = (node.flexDirection == .row)
        let totalGap = gap * CGFloat(children.count - 1)
        // GUARDS §L: a non-positive size falls back to the default weight.
        let weights = children.map { $0.size > 0 ? $0.size : LayoutNode.defaultSize }
        let weightSum = weights.reduce(0, +)
        let available = (horizontal ? rect.width : rect.height) - totalGap
        let usable = max(available, 0)

        var cursor = horizontal ? rect.minX : rect.minY
        for (idx, child) in children.enumerated() {
            let fraction = weightSum > 0 ? CGFloat(weights[idx] / weightSum) : (1 / CGFloat(children.count))
            let extent = usable * fraction
            let childRect: CGRect
            if horizontal {
                childRect = CGRect(x: cursor, y: rect.minY, width: extent, height: rect.height)
            } else {
                childRect = CGRect(x: rect.minX, y: cursor, width: rect.width, height: extent)
            }
            place(node: child, in: childRect, gap: gap, into: &out)
            cursor += extent + gap
        }
    }

    /// Compute draggable boundaries between adjacent siblings for the whole tree.
    /// One splitter sits in each inter-child gap of every internal node, oriented per
    /// that node's flexDirection.
    static func computeSplitters(
        root: LayoutNode?, in bounds: CGRect, gap: CGFloat = Theme.blockTileGap
    ) -> [LayoutSplitter] {
        guard let root else { return [] }
        var out: [LayoutSplitter] = []
        collectSplitters(node: root, in: bounds, gap: gap, into: &out)
        return out
    }

    private static func collectSplitters(
        node: LayoutNode, in rect: CGRect, gap: CGFloat, into out: inout [LayoutSplitter]
    ) {
        guard let children = node.children, !children.isEmpty else { return }

        let horizontal = (node.flexDirection == .row)
        let totalGap = gap * CGFloat(children.count - 1)
        let weights = children.map { $0.size > 0 ? $0.size : LayoutNode.defaultSize }
        let weightSum = weights.reduce(0, +)
        let available = (horizontal ? rect.width : rect.height) - totalGap
        let usable = max(available, 0)

        var cursor = horizontal ? rect.minX : rect.minY
        for (idx, child) in children.enumerated() {
            let fraction = weightSum > 0 ? CGFloat(weights[idx] / weightSum) : (1 / CGFloat(children.count))
            let extent = usable * fraction
            let childRect: CGRect
            if horizontal {
                childRect = CGRect(x: cursor, y: rect.minY, width: extent, height: rect.height)
            } else {
                childRect = CGRect(x: rect.minX, y: cursor, width: rect.width, height: extent)
            }
            // The boundary preceding this child lives in the gap that follows the
            // previous sibling: [cursor - gap, cursor).
            if idx > 0 {
                let frame: CGRect = horizontal
                    ? CGRect(x: cursor - gap, y: rect.minY, width: gap, height: rect.height)
                    : CGRect(x: rect.minX, y: cursor - gap, width: rect.width, height: gap)
                out.append(LayoutSplitter(
                    beforeNodeId: children[idx - 1].id, afterNodeId: child.id,
                    horizontal: horizontal, frame: frame,
                    beforeWeight: weights[idx - 1], afterWeight: weights[idx],
                    usableLength: usable, weightSum: weightSum))
            }
            cursor += extent + gap
            collectSplitters(node: child, in: childRect, gap: gap, into: &out)
        }
    }
}

/// A cardinal direction for keyboard pane navigation (⌘⌥ arrows). `isHorizontal`
/// separates column moves (left/right) from row moves (up/down).
enum PaneDirection {
    case left, right, up, down
    var isHorizontal: Bool { self == .left || self == .right }
}

extension LayoutTiler {
    /// The nearest leaf in `direction` from `current`, using `perp` as the sticky
    /// perpendicular coordinate — the kept row-height for horizontal moves, the kept
    /// column-width for vertical ones (iTerm2 "goal column" model). Returns nil at the
    /// outer edge (no pane lies in that direction). Coordinates are the flipped,
    /// top-left-origin space of `computeFrames` (up == smaller y).
    static func neighbor(
        from current: CGRect, among frames: [LayoutLeafFrame],
        direction: PaneDirection, perp: CGFloat, tolerance: CGFloat = 1.0
    ) -> LayoutLeafFrame? {
        let eps: CGFloat = 0.5
        // Leaves strictly on the far side of `current` along the travel axis.
        let candidates = frames.filter { f in
            if f.frame == current { return false }
            switch direction {
            case .right: return f.frame.minX >= current.maxX - eps
            case .left: return f.frame.maxX <= current.minX + eps
            case .down: return f.frame.minY >= current.maxY - eps
            case .up: return f.frame.maxY <= current.minY + eps
            }
        }
        guard !candidates.isEmpty else { return nil }
        // Gap along the travel axis — smallest gap is the *adjacent* column/row.
        func primaryGap(_ f: CGRect) -> CGFloat {
            switch direction {
            case .right: return f.minX - current.maxX
            case .left: return current.minX - f.maxX
            case .down: return f.minY - current.maxY
            case .up: return current.minY - f.maxY
            }
        }
        let minGap = candidates.map { primaryGap($0.frame) }.min()!
        let nearest = candidates.filter { primaryGap($0.frame) <= minGap + tolerance }
        // Within that adjacent track, the pane whose perpendicular span best matches
        // `perp` (distance 0 when `perp` falls inside it).
        func perpDistance(_ f: CGRect) -> CGFloat {
            let lo = direction.isHorizontal ? f.minY : f.minX
            let hi = direction.isHorizontal ? f.maxY : f.maxX
            if perp >= lo, perp <= hi { return 0 }
            return Swift.min(abs(perp - lo), abs(perp - hi))
        }
        return nearest.min { perpDistance($0.frame) < perpDistance($1.frame) }
    }
}

private extension CGRect {
    /// Snap to whole pixels to avoid seams between tiles.
    var integralPixels: CGRect {
        CGRect(x: origin.x.rounded(), y: origin.y.rounded(),
               width: width.rounded(), height: height.rounded())
    }
}

/// The flipped container that tiles `BlockFrameView`s from a `LayoutState` tree.
final class LayoutTreeView: NSView {
    private let env: BlockEnvFactory
    private let provider: BlockViewProvider

    /// The tab this tree renders (lets the controller decide whether to rebuild).
    let tabId: String

    private var rootNode: LayoutNode?
    private var focusedNodeId: String?
    private var magnifiedNodeId: String?
    private var frames: [LayoutLeafFrame] = []
    /// Reuse block frames across re-tiles, keyed by blockId.
    private var blockViews: [String: BlockFrameView] = [:]
    /// Reuse splitter views across re-tiles, keyed by `LayoutSplitter.key`.
    private var splitterViews: [String: SplitterView] = [:]

    /// Set while a splitter resize is being dragged so `rebuild` applies frames
    /// immediately (animating each drag step would lag the cursor).
    private var suppressLayoutAnimation = false

    /// Blocks with an in-flight split/magnify `animateTransition`. A non-structural echo that
    /// arrives mid-animation (e.g. the backend re-publishing the split with slightly different
    /// sizes) must NOT snap these panes to their target — that cancels the CA animation and the
    /// pane visibly jumps instead of animating. Cleared per block when its animation completes.
    private var animatingBlockIds: Set<String> = []
    /// Panes whose zPosition must drop back to 0 once their in-flight animation
    /// finishes (un-magnify keeps the shrinking pane floating until it lands).
    private var zDemoteOnCompletion: Set<String> = []

    /// Shared animation-completion bookkeeping for both transition paths.
    private func finishPaneAnimation(_ blockId: String) {
        animatingBlockIds.remove(blockId)
        if zDemoteOnCompletion.remove(blockId) != nil {
            blockViews[blockId]?.layer?.zPosition = 0
        }
        if animatingBlockIds.isEmpty {
            // Sweep stragglers whose animation was snapped away by a guard, so no
            // pane is left floating once everything has settled.
            for id in zDemoteOnCompletion { blockViews[id]?.layer?.zPosition = 0 }
            zDemoteOnCompletion.removeAll()
            needsLayout = true
        }
    }

    /// Last rendered structure (arrangement, sizes excluded) so `setLayout` can tell a
    /// geometry-only resize (snap) from a structural change (animate). See `setLayout`.
    private var lastStructureSignature: [String] = []

    /// A block to focus as soon as its content mounts (focus-follows-split). The new
    /// pane's view may not exist yet when the split RPC returns, so we remember it.
    private var pendingFocusBlockId: String?

    /// The block carried by an in-flight pane→tab NSDraggingSession (a header drag
    /// that left this view). Its pane stays dimmed until the session ends.
    private var dragSessionBlockId: String?

    /// Sticky perpendicular coordinates for ⌘⌥ arrow pane navigation (iTerm2 "goal
    /// column"): `navGoalY` is the row-height kept while moving left/right, `navGoalX`
    /// the column-width kept while moving up/down. Cleared on any non-navigation focus
    /// change (`focusBlock`) so a click restarts the run.
    private var navGoalX: CGFloat?
    private var navGoalY: CGFloat?

    /// Raised when a block requests focus (so the coordinator can persist
    /// `LayoutState.focusednodeid`). Carries (nodeId, blockId).
    var onFocusBlock: ((String, String) -> Void)?

    /// Dispatch seam for mouse-driven tree mutations (splitter resize, and future
    /// move/swap gestures). Wired by `WaveWindowController` to
    /// `AppCoordinator.dispatchLayout` → `LayoutModel.dispatch`.
    var onLayoutAction: ((LayoutTreeAction) -> Void)?

    init(env: BlockEnvFactory, provider: BlockViewProvider) {
        self.env = env
        self.provider = provider
        self.tabId = env.tabId
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.windowBackground.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Replace the rendered tree. Pass the focused node id from
    /// `LayoutState.focusednodeid` so the green border lands on the right block.
    func setLayout(root: LayoutNode?, focusedNodeId: String?, magnifiedNodeId: String?) {
        rootNode = root
        self.focusedNodeId = focusedNodeId
        self.magnifiedNodeId = magnifiedNodeId
        // Animate only STRUCTURAL changes (panes added/removed/reordered, or magnify
        // toggled). A splitter resize re-weights existing panes without changing the
        // arrangement — it must snap 1:1 with the cursor, not animate (and its backend
        // echo must not animate either). So compare the arrangement (sizes excluded) and
        // only animate when it actually changed.
        let signature = LayoutTreeView.structureSignature(root: root, magnifiedNodeId: magnifiedNodeId)
        let structural = signature != lastStructureSignature
        lastStructureSignature = signature
        rebuild(structural: structural)
    }

    /// The tree arrangement with sizes excluded: the nesting of container nodes (id +
    /// direction) and leaf nodeIds in traversal order, plus the magnified node. A resize
    /// keeps this identical (same panes, same shape), so it snaps; a split/close/move/
    /// magnify changes it, so it animates. Container nesting MUST be part of the
    /// signature: a header-drag that re-parents a pane (row[A,B,C] → row[A,col[B,C]])
    /// keeps the leaf traversal order identical, and treating that as non-structural
    /// skipped the stale-splitter sweep — the old A|B divider stayed behind as a second
    /// draggable bar still resizing the old node pair.
    static func structureSignature(root: LayoutNode?, magnifiedNodeId: String?) -> [String] {
        var ids: [String] = []
        func walk(_ node: LayoutNode) {
            if node.data?.blockId != nil, (node.children?.isEmpty ?? true) {
                ids.append(node.id)
                return
            }
            ids.append("open:\(node.id):\(node.flexDirection.rawValue)")
            for child in node.children ?? [] { walk(child) }
            ids.append("close")
        }
        if let root { walk(root) }
        ids.append("mag:\(magnifiedNodeId ?? "")")
        return ids
    }

    /// Re-render the tree. `structural` MUST be true only when the tree/magnify state
    /// changed (setLayout) — NOT for a geometry-only pass (layout()). Adding/removing/
    /// re-ordering subviews dirties this view's layout, so doing it on every layout()
    /// pass creates a feedback loop (NSView "continued for 300 iterations" → crash once
    /// the window's update-constraints count exceeds its limit, hit with ≥3 panes).
    /// A geometry pass therefore only repositions existing views.
    private func rebuild(structural: Bool) {
        let oldFrames = frames
        frames = LayoutTiler.computeFrames(root: rootNode, in: bounds, magnifiedNodeId: magnifiedNodeId)
        // A redundant non-structural echo (e.g. the backend re-publishing a magnify we just
        // applied locally) computes IDENTICAL frames. Re-setting view.frame/alpha then would
        // snap a view to its target mid-animation, cutting the magnify/un-magnify transition.
        // So when geometry didn't change, leave frame/alpha untouched (the instant props —
        // focus border, hidden, magnify flag — are still refreshed below).
        let geometryChanged = frames != oldFrames
        let liveBlockIds = Set(frames.map { $0.blockId })

        // Drop views for blocks no longer present (structure change only).
        if structural {
            for (blockId, view) in blockViews where !liveBlockIds.contains(blockId) {
                view.removeFromSuperview()
                blockViews.removeValue(forKey: blockId)
            }
        }

        // Self-heal: a mounted BlockFrameView that is NOT tracked in blockViews is
        // unreachable by every layout/hide/remove path above -- it stays frozen at its
        // last frame ABOVE live panes and silently swallows their clicks (seen in the
        // field as per-tab selection/chrome dead zones parked at a stale 95% magnify
        // frame). The leak's origin is still unknown, so sweep on every pass and log
        // the identity to trace it.
        let tracked = Set(blockViews.values.map(ObjectIdentifier.init))
        for sub in subviews {
            guard let stale = sub as? BlockFrameView, !tracked.contains(ObjectIdentifier(stale)) else { continue }
            NSLog("LAYOUT ORPHAN swept: block=%@ node=%@ frame=%@ tab=%@",
                  stale.blockRef.oid, stale.nodeId, NSStringFromRect(stale.frame), tabId)
            stale.removeFromSuperview()
        }

        let hasMagnified = magnifiedNodeId != nil && frames.contains { $0.nodeId == magnifiedNodeId }
        let multiPane = frames.count > 1
        // Animate structural transitions (magnify, split, move) but NOT a geometry pass
        // (window resize must snap), the live splitter resize (suppressed), or the very
        // first paint / a freshly added pane.
        let animate = structural && !suppressLayoutAnimation && window != nil && !blockViews.isEmpty
        if Self.splitDebug {
            NSLog("SPLITDBG rebuild structural=\(structural) animate=\(animate) geom=\(geometryChanged) n=\(frames.count) bounds=\(NSStringFromRect(bounds))")
        }

        let applyLayout = { [self] in
            for leaf in frames {
                let isNew = blockViews[leaf.blockId] == nil
                let view = blockView(for: leaf)
                if Self.splitDebug {
                    let br = (animate && isNew) ? "GROW" : animate ? "ANIM"
                        : ((geometryChanged || isNew) ? (animatingBlockIds.contains(leaf.blockId) ? "skip-anim" : "SNAP") : "none")
                    NSLog("SPLITDBG   pane=\(leaf.blockId.suffix(4)) isNew=\(isNew) start=\(NSStringFromRect(view.frame)) target=\(NSStringFromRect(leaf.frame)) -> \(br)")
                }
                let isMag = leaf.nodeId == magnifiedNodeId
                // Electron parity: a magnified pane floats; the others stay visible but
                // dimmed behind it (--magnified-block-opacity 0.6).
                let targetAlpha: CGFloat = (hasMagnified && !isMag) ? 0.6 : 1.0
                view.isHidden = false
                // Only the MAIN window may show the green focus border (one border across
                // all windows). Rebuilds run in background windows too (e.g. after a tab
                // moves away), and unconditionally re-applying the border here resurrected
                // it after the window resigned. Gate on MAIN, not KEY: a tab drag bounces
                // key to the drag flotilla window for a few ms at drag start/drop (border
                // flicker), while main stays put for the whole gesture.
                view.isFocused = (window?.isMainWindow ?? false) && (leaf.nodeId == focusedNodeId)
                view.canMagnify = multiPane
                view.setMagnified(hasMagnified && isMag)
                // Float the magnified pane above its dimmed siblings via zPosition, NOT by
                // re-inserting the subview. addSubview(positioned:) detaches and re-attaches
                // the layer, which cancels the in-flight frame animation and snaps the pane
                // straight to its final 95% size — the "jumps to large, then animates" bug.
                // zPosition reorders compositing without touching the layer's animation.
                let targetZ: CGFloat = (hasMagnified && isMag) ? 1 : 0
                if animate, (view.layer?.zPosition ?? 0) > targetZ {
                    // Un-magnify: the pane must stay ABOVE its siblings for the whole
                    // shrink — dropping z at the start slides it under them mid-animation.
                    // Demoted when its animation completes (finishPaneAnimation).
                    zDemoteOnCompletion.insert(leaf.blockId)
                } else {
                    view.layer?.zPosition = targetZ
                    zDemoteOnCompletion.remove(leaf.blockId)
                }
                if animate && isNew {
                    // A newly split-in pane starts with ZERO extent on the split axis (full on the
                    // other), anchored at the right/bottom outer edge; its content is snapped to
                    // final size and the growing frame reveals it (clip-reveal). The start frame
                    // is set explicitly so it never begins the animation from a stale origin.
                    let place = Self.splitPlacement(rootNode: rootNode, leafNodeId: leaf.nodeId)
                    view.frame = Self.growStartFrame(
                        for: leaf.frame, horizontal: place.horizontal, atStart: place.atStart)
                    animateTransition(view, to: leaf.frame, alpha: targetAlpha, clipGrow: !isMag)
                } else if animate {
                    animateTransition(view, to: leaf.frame, alpha: targetAlpha, clipGrow: !isMag)
                } else if geometryChanged || isNew {
                    // Don't snap a pane whose split/magnify animation is still running — a
                    // redundant non-structural echo (same panes, slightly different backend
                    // sizes) would otherwise cancel the CA animation and make it jump.
                    if animatingBlockIds.contains(leaf.blockId) { continue }
                    view.frame = leaf.frame
                    view.alphaValue = targetAlpha
                }
            }
        }

        // animateTransition adds each pane's CA animation itself; no NSAnimationContext.
        applyLayout()
        rebuildSplitters(hasMagnified: hasMagnified, structural: structural)
        if Self.splitDebug, animate { startDebugSampler() }
    }

    /// WAVE_SPLITDEBUG: sample presentation frames of every pane (and its inner content)
    /// every 100ms for ~2.5s so the actually-rendered animation can be read from the log.
    private var debugSamplerTimer: Timer?
    private func startDebugSampler() {
        debugSamplerTimer?.invalidate()
        let t0 = CACurrentMediaTime()
        debugSamplerTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let el = CACurrentMediaTime() - t0
            var parts: [String] = []
            for (blockId, view) in self.blockViews {
                let pres = view.layer?.presentation()?.frame ?? view.frame
                let inner = view.subviews.first
                let innerPres = inner?.layer?.presentation()?.frame ?? inner?.frame ?? .zero
                let content = inner?.subviews.first { !($0 is NSTextField) }
                let contentPres = content?.layer?.presentation()?.frame ?? content?.frame ?? .zero
                let clip = view.layer?.masksToBounds == true ? "clip" : "noclip"
                parts.append("\(blockId.suffix(4)) pane=\(NSStringFromRect(pres)) inner=\(NSStringFromRect(innerPres)) sub=\(NSStringFromRect(contentPres)) \(clip)")
            }
            NSLog("SPLITDBG SAMPLE t=%.2f  %@", el, parts.joined(separator: " || "))
            if el > 2.5 { timer.invalidate() }
        }
        RunLoop.main.add(debugSamplerTimer!, forMode: .common)
    }

    /// Env-gated frame tracing for diagnosing split/magnify animation (WAVE_SPLITDEBUG=1).
    private static var splitDebug: Bool { ProcessInfo.processInfo.environment["WAVE_SPLITDEBUG"] != nil }

    /// Magnify/split transition matching Electron (tilelayout.scss: 0.15s linear).
    /// We deliberately do NOT scale a layer transform — that scaled the whole subtree, so
    /// the terminal/web content visibly stretched and bent during the motion.
    ///
    /// Split/close transitions set the MODEL frame once and sweep the pane with explicit
    /// presentation-only CA animations (see the body); magnify keeps the legacy animator
    /// path (it must not clip, and its subtree layout animates along inside the group).
    ///
    /// Guard against re-issuing the animation when nothing moved: a redundant structural
    /// echo (the backend re-publishing a magnify we already applied) arrives with the frame
    /// ALREADY at target. Re-issuing the animation then restarts it from the layer's
    /// half-way presentation, so the pane/border visibly "starts" mid-size. If the frame
    /// is unchanged, leave the in-flight animation alone.
    private func animateTransition(_ view: BlockFrameView, to target: NSRect, alpha: CGFloat,
                                   clipGrow: Bool) {
        let start = view.frame
        let blockId = view.blockRef.oid
        // Animate as long as the TARGET is real and the start isn't a fully-degenerate .zero
        // frame (an uninitialized view that would fly in from the origin). A deliberate grow
        // start has zero extent on ONE axis (a full-height/width sliver) — that must animate.
        guard target.width > 1, target.height > 1, (start.width > 1 || start.height > 1) else {
            if Self.splitDebug { NSLog("SPLITDBG     animateTransition SNAP(guard) block=\(blockId.suffix(4)) start=\(NSStringFromRect(start)) target=\(NSStringFromRect(target))") }
            view.frame = target; view.alphaValue = alpha; return
        }

        let frameChanged = abs(start.minX - target.minX) > 0.5 || abs(start.minY - target.minY) > 0.5
            || abs(start.width - target.width) > 0.5 || abs(start.height - target.height) > 0.5
        let alphaChanged = abs(view.alphaValue - alpha) > 0.001
        if Self.splitDebug { NSLog("SPLITDBG     animateTransition block=\(blockId.suffix(4)) start=\(NSStringFromRect(start)) target=\(NSStringFromRect(target)) frameChanged=\(frameChanged) alphaChanged=\(alphaChanged)") }
        guard frameChanged || alphaChanged else { return }

        // Electron parity is 0.15s; WAVE_MAGDUR overrides it for visual debugging.
        let dur = ProcessInfo.processInfo.environment["WAVE_MAGDUR"].flatMap(Double.init) ?? 0.15
        let animStart = CACurrentMediaTime()
        if Self.splitDebug { NSLog("SPLITDBG     animateTransition START block=\(blockId.suffix(4)) dur=\(dur) split=\(clipGrow && frameChanged)") }

        // Magnify (keeps its drop shadow, must not clip) and alpha-only changes (sibling
        // dim) use the legacy animator path: the frame ticks and the subtree layout
        // animates along inside the group.
        guard clipGrow, frameChanged else {
            animatingBlockIds.insert(blockId)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = dur
                ctx.timingFunction = CAMediaTimingFunction(name: .linear)
                ctx.allowsImplicitAnimation = true
                if frameChanged { view.animator().frame = target }
                if alphaChanged { view.animator().alphaValue = alpha }
                view.layoutSubtreeIfNeeded()
            } completionHandler: { [weak self] in
                self?.finishPaneAnimation(blockId)
            }
            return
        }

        // Split/close transition — ONE timeline. The MODEL is set to the final geometry
        // exactly once (single layout pass, single terminal/pty resize); the visible sweep
        // is an explicit presentation-only CA animation of the pane layer, with the frame
        // styling (clip, rounding, border box, edge-tracking buttons) driven by synced
        // explicit animations in `beginSplitTransition`. The previous ticking-animator +
        // animated-layout approach ran the background/border/clip on DIFFERENT timelines,
        // which visibly diverged (content sweeping outside the focus border, the black
        // scrim poking out of the top-right corner).
        animatingBlockIds.insert(blockId)
        view.frame = target
        view.alphaValue = alpha
        view.layoutSubtreeIfNeeded()

        CATransaction.begin()
        let token = view.beginSplitTransition(startSize: start.size, duration: dur)
        CATransaction.setCompletionBlock { [weak self, weak view] in
            if Self.splitDebug {
                let el = CACurrentMediaTime() - animStart
                NSLog("SPLITDBG     animateTransition DONE block=\(blockId.suffix(4)) elapsed=\(String(format: "%.3f", el)) model=\(view.map { NSStringFromRect($0.frame) } ?? "nil")")
            }
            // A newer transition may own the styling/animatingBlockIds entry by now —
            // only the CURRENT transition's completion tears down and unblocks.
            guard view?.endSplitTransition(token: token) ?? false else { return }
            // Also runs the geometry pass suppressed during the animation so layout settles.
            self?.finishPaneAnimation(blockId)
        }
        if let layer = view.layer {
            let a = layer.anchorPoint
            let pos = CABasicAnimation(keyPath: "position")
            pos.fromValue = CGPoint(x: start.minX + a.x * start.width,
                                    y: start.minY + a.y * start.height)
            pos.toValue = CGPoint(x: target.minX + a.x * target.width,
                                  y: target.minY + a.y * target.height)
            let boundsAnim = CABasicAnimation(keyPath: "bounds")
            boundsAnim.fromValue = CGRect(origin: layer.bounds.origin, size: start.size)
            boundsAnim.toValue = CGRect(origin: layer.bounds.origin, size: target.size)
            for anim in [pos, boundsAnim] {
                anim.duration = dur
                anim.timingFunction = CAMediaTimingFunction(name: .linear)
            }
            layer.add(pos, forKey: "splitPosition")
            layer.add(boundsAnim, forKey: "splitBounds")
        }
        CATransaction.commit()
    }

    /// The start frame for a newly split-in pane. It keeps the FULL perpendicular extent
    /// (full height for a horizontal/row split, full width for a vertical/column split) and has
    /// ZERO extent along the split axis (default `scale` 0), anchored at the slot's outer edge —
    /// so `animateTransition` grows it out from 0 to its final size while the neighbor shrinks by
    /// the same amount, the two meeting at a divider that sweeps in from the edge. `atStart` (the
    /// first child) anchors at the low edge; otherwise the high edge.
    static func growStartFrame(for target: NSRect, horizontal: Bool, atStart: Bool,
                               scale: CGFloat = 0) -> NSRect {
        if horizontal {
            let w = target.width * scale
            let x = atStart ? target.minX : target.maxX - w
            return NSRect(x: x, y: target.minY, width: w, height: target.height)
        }
        let h = target.height * scale
        let y = atStart ? target.minY : target.maxY - h
        return NSRect(x: target.minX, y: y, width: target.width, height: h)
    }

    /// Split axis + side of a freshly inserted leaf, from its parent container: `horizontal`
    /// when the parent is a row (side-by-side), `atStart` when it's the first child. Defaults
    /// to a high-edge horizontal grow when the parent can't be resolved.
    private static func splitPlacement(rootNode: LayoutNode?, leafNodeId: String) -> (horizontal: Bool, atStart: Bool) {
        guard let rootNode,
              let (parentId, index) = LayoutTree.parentAndIndex(rootNode, childId: leafNodeId),
              let parent = LayoutTree.findNode(rootNode, id: parentId)
        else { return (true, false) }
        return (parent.flexDirection == .row, index == 0)
    }

    /// The per-pane key-frames for a layout transition, composing exactly what `rebuild`
    /// animates: an existing pane interpolates from its old frame to its new one; a newly
    /// split-in pane grows from `growStartFrame` (full perpendicular extent, small along the
    /// split axis, anchored at the right/bottom outer edge) to its final slot. Pure, so the
    /// split animation can be asserted at key timings without running Core Animation.
    static func splitKeyframes(from old: [LayoutLeafFrame], to new: [LayoutLeafFrame],
                               rootNode: LayoutNode?) -> [PaneKeyframes] {
        var oldByBlock: [String: CGRect] = [:]
        for f in old { oldByBlock[f.blockId] = f.frame }
        return new.map { leaf in
            if let start = oldByBlock[leaf.blockId] {
                return PaneKeyframes(blockId: leaf.blockId, start: start, end: leaf.frame)
            }
            let place = splitPlacement(rootNode: rootNode, leafNodeId: leaf.nodeId)
            let start = growStartFrame(for: leaf.frame, horizontal: place.horizontal, atStart: place.atStart)
            return PaneKeyframes(blockId: leaf.blockId, start: start, end: leaf.frame)
        }
    }

    /// Place the draggable dividers. A magnified tab shows a single pane, so it has
    /// no resizable boundaries. Splitter views are added/removed/re-ordered only on a
    /// structural pass; a geometry pass just repositions the existing ones.
    private func rebuildSplitters(hasMagnified: Bool, structural: Bool) {
        let splitters = hasMagnified ? [] : LayoutTiler.computeSplitters(root: rootNode, in: bounds)
        let liveKeys = Set(splitters.map { $0.key })
        // Sweep stale splitters on EVERY pass, not just structural ones (same self-heal
        // rationale as the BlockFrameView orphan sweep in rebuild): a boundary that no
        // longer exists must never keep a live drag target — a leaked one shows up as a
        // phantom divider that resizes a node pair the tree no longer has.
        for (key, view) in splitterViews where !liveKeys.contains(key) {
            view.removeFromSuperview()
            splitterViews.removeValue(forKey: key)
        }
        for splitter in splitters {
            let view = splitterView(for: splitter)
            view.update(splitter)
            // Keep dividers above the block frames so they receive the drag (only on a
            // structural pass — a newly added pane is added above, so re-raise then).
            if structural { addSubview(view) }
        }
    }

    private func splitterView(for splitter: LayoutSplitter) -> SplitterView {
        if let existing = splitterViews[splitter.key] { return existing }
        let view = SplitterView()
        view.onResize = { [weak self] ops in
            guard let self else { return }
            // The dispatch -> model -> publish -> setLayout -> rebuild chain is
            // synchronous, so bracketing the dispatch suppresses animation for this
            // live resize step (the cursor must track the divider 1:1).
            self.suppressLayoutAnimation = true
            self.onLayoutAction?(.resizeNode(ops))
            self.suppressLayoutAnimation = false
        }
        addSubview(view)
        splitterViews[splitter.key] = view
        return view
    }

    private func blockView(for leaf: LayoutLeafFrame) -> BlockFrameView {
        if let existing = blockViews[leaf.blockId] { return existing }
        let blockEnv = env.makeEnv(blockRef: .block(leaf.blockId))
        let view = BlockFrameView(nodeId: leaf.nodeId, env: blockEnv, provider: provider)
        view.onRequestFocus = { [weak self] nodeId in
            // Focus locally (move the green border + keyboard focus to this pane). The
            // onFocusBlock callback was a no-op, so clicks never switched focus.
            self?.focusBlock(leaf.blockId)
            self?.onFocusBlock?(nodeId, leaf.blockId)
        }
        view.onHeaderDrag = { [weak self] nodeId, event in
            self?.beginHeaderDrag(nodeId: nodeId, event: event)
        }
        view.onToggleMagnify = { [weak self] nodeId in
            self?.onLayoutAction?(.magnifyNodeToggle(nodeId: nodeId))
        }
        view.onContentMounted = { [weak self, weak view] in
            guard let self, let view else { return }
            // Focus-follows-split: a freshly created pane's terminal mounts async,
            // after the deferred focusActiveBlock() has run; claim firstResponder once
            // its content lands. We match by BLOCK id (the split's new block, which the
            // backend's focusednodeid does not reliably point at), falling back to the
            // focused leaf for the normal case.
            if view.blockRef.oid == self.pendingFocusBlockId {
                self.pendingFocusBlockId = nil
                view.focusContent()
                self.applyFocusBorder(toBlockId: view.blockRef.oid)
                // Persist into the layout model too (like focusBlock's tail). Setting
                // the border first makes syncFocusToResponder's "already focused"
                // early-return swallow its dispatch, so without this the model kept
                // the OLD pane and window-level Cmd-W/D/M acted on it.
                if let nodeId = self.frames.first(where: { $0.blockId == view.blockRef.oid })?.nodeId {
                    self.onLayoutAction?(.focusNode(nodeId: nodeId))
                }
            } else if view.nodeId == self.focusedNodeId {
                view.focusContent()
            }
        }
        addSubview(view)
        blockViews[leaf.blockId] = view
        // Content mounts SYNCHRONOUSLY inside the view's init when the block object
        // is already in the store cache (applyLayoutState pre-loads it), which fires
        // onContentMounted before the closure above exists. Replay it, or a pending
        // focus-follows-split id never clears — and then EVERY later layout publish
        // (focusActiveBlock's pending branch) steals keyboard focus back to this
        // pane, fighting any pane the user clicks afterwards.
        if view.hasMountedContent { view.onContentMounted?() }
        return view
    }

    /// Drag a pane by its header and drop it onto another to rearrange the tiling.
    /// Center drop → swap; an edge drop → move next to that edge. Runs a self-contained
    /// tracking loop (like `SplitterView`) so the gesture owns the mouse until release;
    /// nothing is dispatched mid-drag (no rebuild), so the captured `frames` stay valid.
    /// Dragging OUT of the view hands the gesture off to an NSDraggingSession carrying
    /// the block, so the pane can be dropped on a tab pill (this window's strip or
    /// another window's) to move it into that tab.
    private func beginHeaderDrag(nodeId draggedId: String, event: NSEvent) {
        // A magnified tab shows a single pane — there is nowhere to drop (and a
        // drag-out would leave the magnify state pointing at a departed node).
        guard magnifiedNodeId == nil else { return }
        let draggedView = frames.first(where: { $0.nodeId == draggedId })
            .flatMap { blockViews[$0.blockId] }
        draggedView?.alphaValue = 0.6

        let overlay = makeDropOverlay()
        addSubview(overlay)

        var dropTarget: LayoutLeafFrame?
        var dropDirection: DropDirection?
        var dragging = true
        while dragging, let evt = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if evt.type == .leftMouseUp { dragging = false }
            let p = convert(evt.locationInWindow, from: nil)
            if evt.type == .leftMouseDragged, !bounds.contains(p) {
                // The pane left the layout area (toward the tab strip / another
                // window): abandon the tracking loop and let an NSDraggingSession own
                // the rest of the gesture. The pane stays dimmed until it ends.
                overlay.removeFromSuperview()
                beginBlockDragSession(nodeId: draggedId, event: evt)
                return
            }
            guard let target = frames.first(where: { $0.frame.contains(p) && $0.nodeId != draggedId }),
                  let dir = LayoutMove.determineDropDirection(
                      in: target.frame.size,
                      at: CGPoint(x: p.x - target.frame.minX, y: p.y - target.frame.minY))
            else {
                dropTarget = nil
                dropDirection = nil
                overlay.isHidden = true
                continue
            }
            dropTarget = target
            dropDirection = dir
            overlay.frame = dropHighlightFrame(direction: dir, target: target.frame)
            overlay.isHidden = false
        }

        overlay.removeFromSuperview()
        draggedView?.alphaValue = 1.0

        guard let target = dropTarget, let dir = dropDirection,
              let action = LayoutMove.computeMoveAction(
                  root: rootNode, targetNodeId: target.nodeId,
                  nodeToMoveId: draggedId, direction: dir)
        else { return }
        onLayoutAction?(action)
    }

    /// Hand an in-progress header drag off to an NSDraggingSession carrying the pane's
    /// block, so it can leave this tab. `TabBarView` accepts the drop on a pill
    /// (moving the block into that tab); `RootContentView` raises background windows
    /// hovered mid-drag, which is what makes the cross-window path reachable.
    private func beginBlockDragSession(nodeId: String, event: NSEvent) {
        guard let leaf = frames.first(where: { $0.nodeId == nodeId }),
              let view = blockViews[leaf.blockId] else { return }
        let item = NSPasteboardItem()
        item.setString(leaf.blockId, forType: BlockDragPayload.blockIdType)
        item.setString(tabId, forType: BlockDragPayload.tabIdType)

        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let image = Self.paneDragImage(for: view)
        // Center the (scaled-down) image under the cursor — a full pane-sized image
        // would obscure the pills it is being aimed at.
        let p = convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(
            CGRect(x: p.x - image.size.width / 2, y: p.y - image.size.height / 2,
                   width: image.size.width, height: image.size.height),
            contents: image)

        dragSessionBlockId = leaf.blockId
        beginDraggingSession(with: [dragItem], event: event, source: self)
        dndLog("pane session begun block=\(leaf.blockId.suffix(4)) tab=\(tabId.suffix(4))")
    }

    /// A thumbnail snapshot of the pane for the drag image, scaled to a small fixed
    /// bound. (The terminal's Metal surface may not render into the snapshot; the
    /// pane chrome is enough to read as "a pane".)
    static func paneDragImage(for view: NSView) -> NSImage {
        let bounds = view.bounds
        let maxDim: CGFloat = 220
        let scale = min(1, maxDim / max(bounds.width, bounds.height, 1))
        let size = NSSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
        let image = NSImage(size: size)
        guard bounds.width > 0, bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return image
        }
        view.cacheDisplay(in: bounds, to: rep)
        image.lockFocus()
        rep.draw(in: NSRect(origin: .zero, size: size), from: bounds,
                 operation: .copy, fraction: 0.8, respectFlipped: true, hints: nil)
        image.unlockFocus()
        return image
    }

    private func makeDropOverlay() -> NSView {
        let overlay = PointerTransparentView()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = Theme.accent.withAlphaComponent(0.2).cgColor
        overlay.layer?.borderColor = Theme.accent.cgColor
        overlay.layer?.borderWidth = 2
        overlay.layer?.cornerRadius = Theme.radiusLarge
        overlay.isHidden = true
        return overlay
    }

    /// The portion of `target` a drop would occupy: the matching half for an edge zone,
    /// the whole pane for a center (swap) drop.
    private func dropHighlightFrame(direction: DropDirection, target: CGRect) -> CGRect {
        switch direction {
        case .center:
            return target
        case .top, .outerTop:
            return CGRect(x: target.minX, y: target.minY, width: target.width, height: target.height / 2)
        case .bottom, .outerBottom:
            return CGRect(x: target.minX, y: target.midY, width: target.width, height: target.height / 2)
        case .left, .outerLeft:
            return CGRect(x: target.minX, y: target.minY, width: target.width / 2, height: target.height)
        case .right, .outerRight:
            return CGRect(x: target.midX, y: target.minY, width: target.width / 2, height: target.height)
        }
    }

    override func layout() {
        // A geometry pass re-applies block-view frames and re-solves their constraints, which
        // cancels an in-flight split/magnify CA animation — the panes snap instead of animating.
        // The split's newly added pane + splitter dirty layout and trigger such passes a few ms
        // into the animation (a close adds nothing, which is exactly why only splits snapped).
        // Skip while animating; the animation completion handler re-triggers a settling pass.
        if !animatingBlockIds.isEmpty { return }
        super.layout()
        rebuild(structural: false)
    }

    /// The magnified pane is floated by zPosition (so its frame animation isn't cancelled
    /// by a subview re-insert), but AppKit hit-tests in subview order, not zPosition — a
    /// dimmed sibling behind the magnified pane could otherwise steal the click. Route
    /// clicks within the magnified pane to it explicitly.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let magId = magnifiedNodeId,
           let magBlockId = frames.first(where: { $0.nodeId == magId })?.blockId,
           let magView = blockViews[magBlockId] {
            let local = convert(point, from: superview)
            if magView.frame.contains(local) {
                return magView.hitTest(local) ?? magView
            }
        }
        return super.hitTest(point)
    }

    /// Pane focus follows keyboard focus. Some focus routes never pass through this
    /// view's own click paths: a WKWebView claims the firstResponder itself on a click
    /// into page content, and a header's URL field hands focus to the window's field
    /// editor. Observing the window's firstResponder catches every route with one
    /// mechanism. The handler only RECORDS focus (green border + persisted
    /// focusednodeid) — it must never move the responder itself, which would re-fire
    /// the observation (loop) or steal keyboard focus from a header text field — and
    /// it defers a runloop hop so layout is never mutated mid-responder-transition.
    private var responderObservation: NSKeyValueObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        responderObservation = nil
        guard let window else { return }
        responderObservation = window.observe(\.firstResponder) { [weak self] _, _ in
            DispatchQueue.main.async { self?.syncFocusToResponder() }
        }
    }

    private func syncFocusToResponder() {
        guard !isHidden, let responder = window?.firstResponder as? NSView else { return }
        guard let entry = blockViews.first(where: { responder.isDescendant(of: $0.value) }) else { return }
        let blockId = entry.key
        dndLog("layoutview syncFocus responder=\(type(of: responder)) block=\(blockId.suffix(4)) focusedNode=\(focusedNodeId?.suffix(4) ?? "nil")")
        if frames.first(where: { $0.nodeId == focusedNodeId })?.blockId == blockId { return }
        navGoalX = nil
        navGoalY = nil
        applyFocusBorder(toBlockId: blockId)
        if let nodeId = frames.first(where: { $0.blockId == blockId })?.nodeId {
            onLayoutAction?(.focusNode(nodeId: nodeId))
        }
    }

    /// Move the window firstResponder to the focused leaf's content (focus-follows
    /// -tab). On a tab switch the controller only flips `isHidden`, so the content
    /// view's `viewDidMoveToWindow` never re-fires; this re-establishes focus.
    /// Falls back to the first frame when no node is focused, matching
    /// LayoutReducer.validateFocusedNode (defaults focus to leafOrder.first).
    func focusActiveBlock() {
        guard window != nil else { return }
        // A split set a pending block to focus: let it win (it mounts async). Don't
        // steal focus to the first leaf here, or it would override focus-follows-split
        // — the backend's focusednodeid doesn't reliably point at the new pane.
        // A pending id whose block is no longer in this tree is STALE (the block moved
        // or closed before its content mounted) — drop it, or a later stray mount would
        // re-assert the focus border out of turn.
        if let pending = pendingFocusBlockId {
            if let view = blockViews[pending] {
                dndLog("layoutview focusActiveBlock pending=\(pending.suffix(4))")
                view.focusContent()
                return
            }
            pendingFocusBlockId = nil
        }
        let leaf = frames.first(where: { $0.nodeId == focusedNodeId }) ?? frames.first
        guard let leaf else { return }
        dndLog("layoutview focusActiveBlock leaf=\(leaf.blockId.suffix(4)) focusedNode=\(focusedNodeId?.suffix(4) ?? "nil")")
        blockViews[leaf.blockId]?.focusContent()
    }

    /// Whether the window's firstResponder sits inside a web pane's PAGE content
    /// (the WKWebView subtree). Keys sent down the responder chain would then be
    /// claimed by the web view, so the controller must run app-global ⌘ bindings
    /// from the window's preempt hook instead of the normal after-chain hook.
    var firstResponderIsWebPageContent: Bool {
        guard !isHidden, let responder = window?.firstResponder as? NSView else { return false }
        guard let frame = blockViews.values.first(where: { responder.isDescendant(of: $0) }) else { return false }
        return frame.ownsWebPageResponder(responder)
    }

    /// Reload the focused block's content (Cmd-R). Resolves the focused pane — the
    /// firstResponder's owning frame, else the focus-border node, else the first leaf —
    /// and asks it to reload; only a web block acts on it (a terminal's bridge has no
    /// reload action).
    func reloadFocusedBlock() {
        focusedBlockFrame()?.reloadContent()
    }

    /// The block frame that currently holds keyboard focus, for routing window-level
    /// shortcuts (reload) to the active pane. Prefers the firstResponder's owning frame
    /// (a clicked web pane makes its WKWebView first responder), then the green-border
    /// node, then the first leaf.
    private func focusedBlockFrame() -> BlockFrameView? {
        if let responder = window?.firstResponder as? NSView {
            for view in blockViews.values where responder === view || responder.isDescendant(of: view) {
                return view
            }
        }
        if let leaf = frames.first(where: { $0.nodeId == focusedNodeId }) {
            return blockViews[leaf.blockId]
        }
        return frames.first.flatMap { blockViews[$0.blockId] }
    }

    /// Focus a specific block by id (focus-follows-split). If its view + content are
    /// already mounted, focus now; otherwise remember it and focus on content-mount.
    func focusBlock(_ blockId: String) {
        // Any focus change that isn't a ⌘⌥ arrow move (e.g. a click) restarts the sticky
        // run; `navigatePane` re-sets these AFTER calling focusBlock.
        dndLog("layoutview focusBlock tab=\(tabId.suffix(4)) block=\(blockId.suffix(4)) mounted=\(blockViews[blockId]?.window != nil)")
        navGoalX = nil
        navGoalY = nil
        pendingFocusBlockId = blockId
        guard let view = blockViews[blockId], view.window != nil else { return }
        // Border/state first, keyboard second: the responder change from
        // focusContent() re-enters syncFocusToResponder, which then no-ops because
        // this pane is already recorded as focused.
        applyFocusBorder(toBlockId: blockId)
        view.focusContent()
        // A pending id is ONLY for content that hasn't mounted yet (focus-follows-
        // split). Leaving it set for a mounted pane makes it a sticky focus theft:
        // every later layout publish runs focusActiveBlock, whose pending branch
        // would re-assert THIS pane over wherever the user has since clicked
        // (observed as web panes never regaining focus — the .focusNode dispatch a
        // web click triggers published a layout update that immediately snapped
        // focus back to the previously clicked terminal).
        if view.hasMountedContent { pendingFocusBlockId = nil }
        // Persist the click-driven focus into the layout model. The green border lives
        // only in this view's local `focusedNodeId`; window-level Cmd-W / split / magnify
        // read `model.focusedNodeId` (AppCoordinator.currentFocusedBlockId), so without
        // this dispatch they would act on the PREVIOUSLY focused pane. The resulting
        // re-render only re-applies `isFocused` (setLayout never calls focusBlock), so
        // there is no focus loop.
        if let nodeId = frames.first(where: { $0.blockId == blockId })?.nodeId {
            onLayoutAction?(.focusNode(nodeId: nodeId))
        }
    }

    /// Reflect the owning window's key state on the focus border. A background (non-key)
    /// window must NOT show the green border; becoming key restores it on the same pane.
    /// `focusedNodeId` is preserved either way so no focus is lost on deactivation.
    func setWindowActive(_ active: Bool) {
        guard active else {
            for f in frames { blockViews[f.blockId]?.isFocused = false }
            return
        }
        for f in frames { blockViews[f.blockId]?.isFocused = (f.nodeId == focusedNodeId) }
    }

    /// Move the green focus border to `blockId` (and update local `focusedNodeId`).
    /// Used by focus-follows-split because the backend's focusednodeid does not point
    /// at the new pane; a later layout update or a click re-syncs it.
    private func applyFocusBorder(toBlockId blockId: String) {
        dndLog("layoutview applyFocusBorder tab=\(tabId.suffix(4)) block=\(blockId.suffix(4)) found=\(frames.contains { $0.blockId == blockId })")
        guard let leaf = frames.first(where: { $0.blockId == blockId }) else { return }
        focusedNodeId = leaf.nodeId
        let active = window?.isMainWindow ?? false
        for f in frames { blockViews[f.blockId]?.isFocused = active && (f.blockId == blockId) }
    }

    /// Move keyboard focus to the neighboring pane in `direction` (⌘⌥ arrows). The sticky
    /// perpendicular coordinate keeps your row-height while sliding across columns (and
    /// column-width across rows), so left↔right / up↔down round-trips return to the same
    /// pane. A no-op at the outer edge.
    func navigatePane(_ direction: PaneDirection) {
        // Navigate over the real tiled grid even while a pane is magnified (a magnified
        // leaf floats centered, which would otherwise distort neighbor geometry).
        let navFrames = magnifiedNodeId == nil
            ? frames
            : LayoutTiler.computeFrames(root: rootNode, in: bounds, magnifiedNodeId: nil)
        guard let current = navFrames.first(where: { $0.nodeId == focusedNodeId }) else {
            // No / stale focus: land on the first leaf, matching the model's focus default.
            if let first = navFrames.first { focusBlock(first.blockId) }
            return
        }
        let perp = direction.isHorizontal
            ? (navGoalY ?? current.frame.midY)
            : (navGoalX ?? current.frame.midX)
        guard let target = LayoutTiler.neighbor(
            from: current.frame, among: navFrames, direction: direction, perp: perp
        ) else { return }
        focusBlock(target.blockId)  // clears navGoalX / navGoalY
        if direction.isHorizontal {
            navGoalY = perp
            navGoalX = target.frame.midX
        } else {
            navGoalX = perp
            navGoalY = target.frame.midY
        }
    }
}

extension LayoutTreeView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // A pane only means something to Wave's own strips; outside the app it is
        // nothing droppable.
        context == .withinApplication ? .move : []
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        dndLog("pane session ended block=\(dragSessionBlockId?.suffix(4) ?? "nil") op=\(operation.rawValue)")
        // On an accepted drop the backend's removenode rebuilds this tree (dropping
        // the view); on a cancelled drag the pane is still here — undim it either way.
        if let blockId = dragSessionBlockId {
            blockViews[blockId]?.alphaValue = 1.0
            dragSessionBlockId = nil
        }
    }
}

/// A thin draggable divider between two sibling tiles. Translates a pixel drag into
/// a size-weight trade between its two bordering nodes and emits one `resizeNode`
/// batch per drag step (the model debounces the persist, GUARDS §L).
private final class SplitterView: NSView {
    /// Smallest on-screen extent a pane may shrink to during a resize.
    private static let minPaneExtent: CGFloat = 50
    /// Widen the 3px gap into an easier grab target without overlapping much content.
    private static let grabInset: CGFloat = 3

    private var splitter: LayoutSplitter?
    var onResize: (([ResizeOperation]) -> Void)?

    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func update(_ splitter: LayoutSplitter) {
        let orientationChanged = (self.splitter?.horizontal != splitter.horizontal)
        self.splitter = splitter
        frame = splitter.horizontal
            ? splitter.frame.insetBy(dx: -Self.grabInset, dy: 0)
            : splitter.frame.insetBy(dx: 0, dy: -Self.grabInset)
        if orientationChanged {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        let cursor: NSCursor = (splitter?.horizontal ?? true) ? .resizeLeftRight : .resizeUpDown
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = Theme.accent.withAlphaComponent(0.35).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// Run a self-contained tracking loop so the gesture survives the re-tiles each
    /// `resizeNode` dispatch triggers (a rebuild repositions this view live). All
    /// math is relative to the drag-start geometry captured here, so interim rebuilds
    /// don't perturb it.
    override func mouseDown(with event: NSEvent) {
        guard let splitter, let container = superview else { return }
        let horizontal = splitter.horizontal
        let usable = splitter.usableLength
        let weightSum = splitter.weightSum
        guard usable > 0, weightSum > 0 else { return }

        let startPoint = container.convert(event.locationInWindow, from: nil)
        let startAxis = horizontal ? startPoint.x : startPoint.y
        let before0 = splitter.beforeWeight
        let after0 = splitter.afterWeight
        let pairSum = before0 + after0
        let beforeId = splitter.beforeNodeId
        let afterId = splitter.afterNodeId

        let weightPerPixel = weightSum / Double(usable)
        let minWeight = min(pairSum / 2, (Double(Self.minPaneExtent) / Double(usable)) * weightSum)

        var dragging = true
        while dragging, let evt = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if evt.type == .leftMouseUp {
                dragging = false
                continue
            }
            let p = container.convert(evt.locationInWindow, from: nil)
            let cur = horizontal ? p.x : p.y
            let deltaWeight = Double(cur - startAxis) * weightPerPixel
            var newBefore = before0 + deltaWeight
            var newAfter = after0 - deltaWeight
            if newBefore < minWeight { newBefore = minWeight; newAfter = pairSum - minWeight }
            if newAfter < minWeight { newAfter = minWeight; newBefore = pairSum - minWeight }
            onResize?([
                ResizeOperation(nodeId: beforeId, size: newBefore),
                ResizeOperation(nodeId: afterId, size: newAfter),
            ])
        }
    }
}

/// Builds a `BlockEnv` for a given block (the tab/window context stays constant
/// while a tab is mounted). Lets `LayoutTreeView` stay decoupled from coordinator
/// internals.
public struct BlockEnvFactory: Sendable {
    let transport: WaveTransport
    let store: ObjectStoreProtocol
    let tabId: String
    let windowId: String
    let workspaceId: String
    let onNavigate: (@Sendable (String, String, String?) -> Void)?
    let onSplit: (@Sendable (String, String) -> Void)?
    let onMagnify: (@Sendable (String) -> Void)?
    let onClose: (@Sendable (String) -> Void)?
    let onPickConnection: (@Sendable (String) -> Void)?
    let onOpenWebURL: (@Sendable (String, String) -> Void)?
    let onRequestFocus: (@Sendable (String) -> Void)?
    let onBell: (@Sendable (String, String) -> Void)?
    let onNotification: (@Sendable (String, String, String?, String) -> Void)?
    let onClipboardCopy: (@Sendable (Data) -> Void)?
    let connections: ConnectionStore?
    let termThemes: [TermThemeMenuItem]
    let defaultTermThemeName: String

    init(
        transport: WaveTransport, store: ObjectStoreProtocol, tabId: String, windowId: String,
        workspaceId: String = "",
        onNavigate: (@Sendable (String, String, String?) -> Void)? = nil,
        onSplit: (@Sendable (String, String) -> Void)? = nil,
        onMagnify: (@Sendable (String) -> Void)? = nil,
        onClose: (@Sendable (String) -> Void)? = nil,
        onPickConnection: (@Sendable (String) -> Void)? = nil,
        onOpenWebURL: (@Sendable (String, String) -> Void)? = nil,
        onRequestFocus: (@Sendable (String) -> Void)? = nil,
        onBell: (@Sendable (String, String) -> Void)? = nil,
        onNotification: (@Sendable (String, String, String?, String) -> Void)? = nil,
        onClipboardCopy: (@Sendable (Data) -> Void)? = nil,
        connections: ConnectionStore? = nil,
        termThemes: [TermThemeMenuItem] = [],
        defaultTermThemeName: String = "default-dark"
    ) {
        self.transport = transport
        self.store = store
        self.tabId = tabId
        self.windowId = windowId
        self.workspaceId = workspaceId
        self.onNavigate = onNavigate
        self.onSplit = onSplit
        self.onMagnify = onMagnify
        self.onClose = onClose
        self.onPickConnection = onPickConnection
        self.onOpenWebURL = onOpenWebURL
        self.onRequestFocus = onRequestFocus
        self.onBell = onBell
        self.onNotification = onNotification
        self.onClipboardCopy = onClipboardCopy
        self.connections = connections
        self.termThemes = termThemes
        self.defaultTermThemeName = defaultTermThemeName
    }

    func makeEnv(blockRef: ORef) -> BlockEnv {
        BlockEnv(
            transport: transport, store: store, blockRef: blockRef,
            tabId: tabId, windowId: windowId,
            workspaceId: workspaceId, onNavigate: onNavigate,
            onSplit: onSplit, onMagnify: onMagnify, onClose: onClose,
            onPickConnection: onPickConnection, onOpenWebURL: onOpenWebURL, onRequestFocus: onRequestFocus,
            onBell: onBell, onNotification: onNotification, onClipboardCopy: onClipboardCopy,
            connections: connections, termThemes: termThemes, defaultTermThemeName: defaultTermThemeName)
    }
}
