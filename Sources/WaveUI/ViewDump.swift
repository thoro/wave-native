// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — live view-hierarchy dump for field diagnosis. Invisible views that swallow
// clicks (an orphaned pane frame parked at a stale magnify frame, a transparent overlay
// left behind by a drag) have shown up repeatedly in the field, and each time the
// only way to see them was a relaunch with the test driver, which destroys the state
// under investigation. `AppInstanceOp.dumpViews` on the always-on control socket
// writes this dump for the RUNNING app instead, so the phantom can be inspected in
// place: every window's view tree with the geometry/visibility facts hit-testing
// depends on, plus (optionally) the exact hit-test chain for one point.

import AppKit

/// Views that own layout state hit-testing cannot see (tracked pane ids, magnify
/// state, in-flight animations) append it to their dump line via this seam.
protocol ViewDumpAnnotating {
    var dumpAnnotation: String { get }
}

enum ViewDump {
    /// One line per view, depth-indented: class, frame, then only the facts that
    /// deviate from the hit-testable default (hidden, translucent, floated, animating)
    /// and the view's own annotation. A hidden subtree is collapsed to a count —
    /// hidden views never hit-test, so their contents are noise for this purpose.
    static func describe(_ view: NSView, depth: Int = 0, into lines: inout [String]) {
        var line = String(repeating: "  ", count: depth) + "\(type(of: view)) frame=\(fmt(view.frame))"
        if view.isHidden { line += " HIDDEN" }
        if view.alphaValue < 0.999 { line += " alpha=\(String(format: "%.2f", view.alphaValue)) " }
        if let layer = view.layer {
            if layer.zPosition != 0 { line += " z=\(layer.zPosition)" }
            if let keys = layer.animationKeys(), !keys.isEmpty { line += " anim=\(keys.joined(separator: ","))" }
            if layer.opacity < 0.999 { line += " layerOpacity=\(layer.opacity)" }
        }
        if let annotated = view as? ViewDumpAnnotating { line += " " + annotated.dumpAnnotation }
        lines.append(line)
        if view.isHidden {
            let n = descendantCount(view)
            if n > 0 { lines.append(String(repeating: "  ", count: depth + 1) + "(hidden subtree: \(n) descendants)") }
            return
        }
        for sub in view.subviews { describe(sub, depth: depth + 1, into: &lines) }
    }

    /// The view AppKit would deliver a click at `contentPoint` to, followed by its
    /// superview chain up to the content view. `contentPoint` uses a TOP-LEFT origin in
    /// the content view (the coordinate system of a window screenshot), matching the
    /// test driver's click/hit convention.
    static func hitChain(in window: NSWindow, contentPoint: NSPoint) -> [String] {
        guard let content = window.contentView else { return ["(no content view)"] }
        let y = content.isFlipped ? contentPoint.y : content.bounds.height - contentPoint.y
        let local = NSPoint(x: contentPoint.x, y: y)
        // hitTest takes SUPERVIEW coordinates; the content view's superview is the
        // window's frame view.
        let probe = content.superview.map { content.convert(local, to: $0) } ?? local
        var chain: [String] = []
        var v: NSView? = content.hitTest(probe)
        while let cur = v {
            var line = "\(type(of: cur)) frame=\(fmt(cur.frame))"
            if let annotated = cur as? ViewDumpAnnotating { line += " " + annotated.dumpAnnotation }
            chain.append(line)
            v = (cur === content) ? nil : cur.superview
        }
        if chain.isEmpty { chain.append("(hitTest returned nil)") }
        return chain
    }

    /// Full report: every window with its key/main/visible state and content tree,
    /// and — when `hit` names a point — the hit chain in that window, first.
    static func report(windows: [NSWindow], hit: (window: NSWindow, contentPoint: NSPoint)? = nil) -> String {
        var lines: [String] = []
        if let hit {
            lines.append("HIT window=\(hit.window.windowNumber) point(top-left)=\(fmt(hit.contentPoint)) title=\(hit.window.title)")
            for (i, entry) in hitChain(in: hit.window, contentPoint: hit.contentPoint).enumerated() {
                lines.append("  [\(i)] " + entry)
            }
            lines.append("")
        }
        for w in windows {
            lines.append("WINDOW \(type(of: w)) number=\(w.windowNumber) visible=\(w.isVisible) key=\(w.isKeyWindow) "
                + "main=\(w.isMainWindow) frame=\(fmt(w.frame)) title=\(w.title) "
                + "firstResponder=\(w.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
            if let content = w.contentView { describe(content, depth: 1, into: &lines) }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func descendantCount(_ view: NSView) -> Int {
        view.subviews.reduce(0) { $0 + 1 + descendantCount($1) }
    }

    private static func fmt(_ r: NSRect) -> String {
        "(\(fmt(r.minX)),\(fmt(r.minY)) \(fmt(r.width))x\(fmt(r.height)))"
    }

    private static func fmt(_ p: NSPoint) -> String { "(\(fmt(p.x)),\(fmt(p.y)))" }

    private static func fmt(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
