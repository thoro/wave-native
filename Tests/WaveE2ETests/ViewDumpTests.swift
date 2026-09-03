// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// ViewDump: the live view-hierarchy report behind `DUMPVIEWS` (and the driver's
// `hit`). These pin the facts a field diagnosis of an invisible click-swallowing
// view relies on: hidden/alpha/z flags, collapsed hidden subtrees, the top-left
// hit-point convention, and the layout tree's tracked-pane annotation.

import AppKit
import XCTest
@testable import WaveCore
@testable import WaveUI

@MainActor
final class ViewDumpTests: XCTestCase {
    private final class Tagged: NSView, ViewDumpAnnotating {
        var dumpAnnotation: String { "tag=probe" }
    }

    func testDescribeFlagsDeviationsAndCollapsesHiddenSubtrees() {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        root.wantsLayer = true
        let floating = Tagged(frame: CGRect(x: 10, y: 20, width: 100, height: 50))
        floating.wantsLayer = true
        floating.layer?.zPosition = 1
        floating.alphaValue = 0.6
        root.addSubview(floating)
        let hidden = NSView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        hidden.isHidden = true
        hidden.addSubview(NSView(frame: .zero))
        hidden.addSubview(NSView(frame: .zero))
        root.addSubview(hidden)

        var lines: [String] = []
        ViewDump.describe(root, into: &lines)

        XCTAssertEqual(lines[0], "NSView frame=(0,0 300x200)")
        XCTAssertTrue(lines[1].hasPrefix("  Tagged frame=(10,20 100x50)"), lines[1])
        XCTAssertTrue(lines[1].contains("alpha=0.60"), lines[1])
        XCTAssertTrue(lines[1].contains("z=1.0"), lines[1])
        XCTAssertTrue(lines[1].hasSuffix("tag=probe"), lines[1])
        XCTAssertTrue(lines[2].contains("HIDDEN"), lines[2])
        XCTAssertEqual(lines[3], "    (hidden subtree: 2 descendants)")
        XCTAssertEqual(lines.count, 4, "hidden children must not be expanded")
    }

    func testHitChainTakesTopLeftContentCoordinatesAndWalksToTheRoot() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = container
        // AppKit (bottom-left) frame: the bottom-left 100x100 corner...
        let corner = Tagged(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        container.addSubview(corner)

        // ...which a screenshot-style top-left point near the BOTTOM of the window hits.
        let chain = ViewDump.hitChain(in: window, contentPoint: NSPoint(x: 50, y: 350))
        XCTAssertEqual(chain.count, 2, chain.joined(separator: " | "))
        XCTAssertTrue(chain[0].hasPrefix("Tagged frame=(0,0 100x100)"), chain[0])
        XCTAssertTrue(chain[0].hasSuffix("tag=probe"), chain[0])
        XCTAssertTrue(chain[1].hasPrefix("NSView frame=(0,0 600x400)"), chain[1])

        // The same x near the TOP misses the corner view.
        let miss = ViewDump.hitChain(in: window, contentPoint: NSPoint(x: 50, y: 50))
        XCTAssertEqual(miss.count, 1)
        XCTAssertTrue(miss[0].hasPrefix("NSView"), miss[0])
    }

    func testReportAnnotatesLayoutTreeAndPaneFrames() {
        let env = BlockEnvFactory(
            transport: FakeTransport(), store: FakeStore(), tabId: "tab-1", windowId: "w-1")
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let tree = LayoutTreeView(env: env, provider: DefaultBlockViewProvider())
        tree.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = tree
        let root = LayoutNode(id: "node-a", data: TabLayoutData(blockId: "block-A"), size: 10)
        tree.setLayout(root: root, focusedNodeId: "node-a", magnifiedNodeId: nil)

        let report = ViewDump.report(windows: [window], hit: (window, NSPoint(x: 300, y: 200)))

        XCTAssertTrue(report.hasPrefix("HIT window="), report)
        XCTAssertTrue(report.contains("tab=tab-1 leaves=1 tracked=[block-A@node-a] splitters=0 focused=node-a magnified=nil"), report)
        XCTAssertTrue(report.contains("node=node-a block=block-A"), report)
        XCTAssertTrue(report.contains("WINDOW NSWindow"), report)
    }
}
