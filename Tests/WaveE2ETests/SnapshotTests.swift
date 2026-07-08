// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// E2E-7 (visual half) — render the window + key chrome components offscreen and
// verify the default-dark look (docs/E2E.md "Snapshot tests", STYLE.md
// "Acceptance"):
//   window bg #222, 130px pill tabs with white-10% active fill + white active
//   label, terminal canvas on #000, 2px green (#58c142) focus border, 8px radius.
//
// Two layers of assertion:
//   * Deterministic pixel sampling against the literal Theme/STYLE values
//     (font-independent — runs anywhere with a GUI context).
//   * Optional PNG baseline diff vs the Electron app's screenshots in
//     `tests/snapshots/` (see that dir's README.md for capture steps). These run
//     only when a baseline exists or WAVE_NATIVE_RECORD_SNAPSHOTS=1 is set, so the
//     suite stays green before baselines are captured.
//
// Reuses `FakeStore` / `FakeTransport` from WaveUITests.swift for the BlockEnv —
// these are pure-Swift fakes for *view construction only*; no wavesrv behavior is
// mocked here (this is a rendering test, not a protocol test).

import XCTest
import AppKit
import WaveCore
@testable import WaveUI

@MainActor
final class SnapshotTests: XCTestCase {

    // MARK: - Window background (STYLE §6: solid #222 content area)

    func testWindowContentBackgroundIsDark() throws {
        try SnapshotTester.skipIfNoGUI()
        let size = CGSize(width: 900, height: 600)
        let root = RootContentView(tabBar: TabBarView(frame: .zero))
        let rep = try XCTUnwrap(SnapshotTester.renderComposited(root, size: size, background: Theme.windowBackground),
                                "offscreen render produced no bitmap")
        // Sample well inside the content area (below the 33px strip).
        let c = SnapshotTester.color(rep, atFraction: 0.5, 0.7)
        SnapshotTester.assertColor(c, Theme.windowBackground, "window content bg should be #222")

        if SnapshotTester.baselineExists("window-default") || SnapshotTester.isRecording {
            SnapshotTester.assertBaseline(rep, named: "window-default")
        }
    }

    // MARK: - Active pill fill (STYLE §4: white@10% over #222)

    func testActivePillFill() throws {
        try SnapshotTester.skipIfNoGUI()
        let size = CGSize(width: Theme.tabWidth, height: Theme.tabBarHeight)
        let pill = TabPillView(tabId: "t1", title: "Active")
        pill.isActive = true
        let rep = try XCTUnwrap(SnapshotTester.renderComposited(pill, size: size, background: Theme.windowBackground))
        // Center of the pill is the solid inner fill.
        let center = SnapshotTester.color(rep, atFraction: 0.5, 0.5)
        let expected = SnapshotTester.composite(Theme.tabActiveFill, on: Theme.windowBackground)
        SnapshotTester.assertColor(center, expected, tolerance: 5.0 / 255.0,
                                   "active pill fill should be white@10% over #222")

        if SnapshotTester.baselineExists("pill-active") || SnapshotTester.isRecording {
            SnapshotTester.assertBaseline(rep, named: "pill-active")
        }
    }

    // MARK: - Inactive pill (no fill -> background shows through)

    func testInactivePillHasNoFill() throws {
        try SnapshotTester.skipIfNoGUI()
        let size = CGSize(width: Theme.tabWidth, height: Theme.tabBarHeight)
        let pill = TabPillView(tabId: "t2", title: "Idle")
        pill.isActive = false
        let rep = try XCTUnwrap(SnapshotTester.renderComposited(pill, size: size, background: Theme.windowBackground))
        let center = SnapshotTester.color(rep, atFraction: 0.5, 0.5)
        SnapshotTester.assertColor(center, Theme.windowBackground, tolerance: 5.0 / 255.0,
                                   "inactive pill should not paint a fill")
    }

    // MARK: - Block frame: terminal canvas #000 + 2px green focus border

    func testFocusedBlockBorderAndCanvas() throws {
        try SnapshotTester.skipIfNoGUI()
        let (env, _) = makeBlockEnv(view: "term")
        let size = CGSize(width: 300, height: 220)

        let focused = BlockFrameView(nodeId: "n1", env: env, provider: DefaultBlockViewProvider())
        focused.isFocused = true
        let rep = try XCTUnwrap(SnapshotTester.renderComposited(focused, size: size, background: Theme.windowBackground))

        // Content canvas (below the 30px header) is the terminal black (#000).
        let canvas = SnapshotTester.color(rep, atPoint: CGPoint(x: size.width / 2, y: size.height * 0.75), viewSize: size)
        SnapshotTester.assertColor(canvas, TerminalTheme.background, tolerance: 4.0 / 255.0,
                                   "terminal canvas should be #000 (STYLE §3)")

        // The 2px accent border sits ~1-3pt in from the edge; sample at x=2pt.
        let border = SnapshotTester.color(rep, atPoint: CGPoint(x: 2, y: size.height / 2), viewSize: size)
        SnapshotTester.assertColor(border, Theme.accent, tolerance: 6.0 / 255.0,
                                   "focused block must show the 2px #58c142 border (STYLE §5)")

        if SnapshotTester.baselineExists("block-focused") || SnapshotTester.isRecording {
            SnapshotTester.assertBaseline(rep, named: "block-focused")
        }
    }

    func testUnfocusedBlockHasNoAccentBorder() throws {
        try SnapshotTester.skipIfNoGUI()
        let (env, _) = makeBlockEnv(view: "term")
        let size = CGSize(width: 300, height: 220)
        let unfocused = BlockFrameView(nodeId: "n2", env: env, provider: DefaultBlockViewProvider())
        unfocused.isFocused = false
        let rep = try XCTUnwrap(SnapshotTester.renderComposited(unfocused, size: size, background: Theme.windowBackground))
        let border = SnapshotTester.color(rep, atPoint: CGPoint(x: 2, y: size.height / 2), viewSize: size)
        // Border is clear when unfocused; the content canvas (#000) shows through.
        XCTAssertNotNil(border)
        SnapshotTester.assertColor(border, TerminalTheme.background, tolerance: 6.0 / 255.0,
                                   "unfocused block must NOT paint the accent border")
    }

    // MARK: - Full tab strip (baseline diff vs Electron, when available)

    func testTabBarSnapshot() throws {
        try SnapshotTester.skipIfNoGUI()
        let bar = TabBarView(frame: .zero)
        bar.setWorkspace(name: "Default", icon: nil, color: "#58c142", workspaceId: "ws-1")
        bar.setTabs([
            TabBarItem(tabId: "t1", name: "One"),
            TabBarItem(tabId: "t2", name: "Two"),
            TabBarItem(tabId: "t3", name: "Three"),
        ], activeTabId: "t1")
        let size = CGSize(width: 900, height: Theme.tabBarHeight)
        let rep = try XCTUnwrap(SnapshotTester.renderComposited(bar, size: size, background: Theme.windowBackground))

        guard SnapshotTester.baselineExists("tabbar-default") || SnapshotTester.isRecording else {
            throw XCTSkip("no tabbar-default.png baseline yet — capture per tests/snapshots/README.md " +
                          "or run with WAVE_NATIVE_RECORD_SNAPSHOTS=1.")
        }
        SnapshotTester.assertBaseline(rep, named: "tabbar-default")
    }

    // MARK: - Helpers

    private func makeBlockEnv(view: String) -> (BlockEnv, FakeStore) {
        let store = FakeStore()
        store.preload(.block(Block(oid: "blk-1", version: 1, meta: ["view": .string(view)])))
        let env = BlockEnv(
            transport: FakeTransport(), store: store,
            blockRef: ORef.block("blk-1"), tabId: "tab-1", windowId: "win-1")
        return (env, store)
    }
}
