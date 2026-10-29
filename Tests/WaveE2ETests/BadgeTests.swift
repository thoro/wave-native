// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Tests for `wsh badge` support: the BadgeStore merge rules (mirroring
// `pkg/wcore/badge.go`), tab aggregation, the auto-clear target selection, the pill's
// flag folding, and the coordinator routing a `badge` event into the tab strip.

import XCTest
import AppKit
@testable import WaveCore
@testable import WaveUI

@MainActor
final class BadgeTests: XCTestCase {

    private func badge(_ id: String, priority: Double = 10, icon: String = "circle-small",
                       pidlinked: Bool? = nil) -> Badge {
        Badge(badgeid: id, icon: icon, priority: priority, pidlinked: pidlinked)
    }

    private func set(_ store: BadgeStore, _ oref: String, _ b: Badge) {
        store.apply(BadgeEvent(oref: oref, badge: b))
    }

    // MARK: - Store merge rules

    func testHigherPriorityWinsAndLowerIsIgnored() {
        let store = BadgeStore()
        set(store, "block:b1", badge("0001", priority: 10))
        XCTAssertFalse(store.apply(BadgeEvent(oref: "block:b1", badge: badge("0002", priority: 5))))
        XCTAssertEqual(store.blockBadge("b1")?.badgeid, "0001")
        set(store, "block:b1", badge("0003", priority: 20))
        XCTAssertEqual(store.blockBadge("b1")?.badgeid, "0003")
    }

    func testEqualPriorityNewerIdWins() {
        let store = BadgeStore()
        set(store, "block:b1", badge("0001"))
        set(store, "block:b1", badge("0002"))
        XCTAssertEqual(store.blockBadge("b1")?.badgeid, "0002")
    }

    func testClearVariants() {
        let store = BadgeStore()
        set(store, "block:b1", badge("0001"))
        set(store, "block:b2", badge("0002"))
        XCTAssertFalse(store.apply(BadgeEvent(oref: "block:b1", clearbyid: "nope")),
                       "clearbyid only clears a matching badge")
        XCTAssertTrue(store.apply(BadgeEvent(oref: "block:b1", clearbyid: "0001")))
        XCTAssertNil(store.blockBadge("b1"))
        XCTAssertTrue(store.apply(BadgeEvent(oref: "block:b2", clear: true)))
        XCTAssertNil(store.blockBadge("b2"))
        set(store, "tab:t1", badge("0003"))
        XCTAssertTrue(store.apply(BadgeEvent(oref: "", clearall: true)))
        XCTAssertNil(store.badge(for: "tab:t1"))
    }

    func testSeedReplacesAndNotifies() {
        let store = BadgeStore()
        set(store, "block:old", badge("0001"))
        var notified = 0
        let token = store.subscribe { notified += 1 }
        defer { token.cancel() }
        store.seed([BadgeEvent(oref: "block:b1", badge: badge("0002"))])
        XCTAssertNil(store.blockBadge("old"))
        XCTAssertEqual(store.blockBadge("b1")?.badgeid, "0002")
        XCTAssertEqual(notified, 1)
    }

    func testDecodesWshPayload() throws {
        let json: JSONValue = .object([
            "oref": .string("block:7f9d"),
            "badge": .object([
                "badgeid": .string("0199"), "icon": .string("triangle-exclamation"),
                "color": .string("orange"), "priority": .int(10),
            ]),
        ])
        let ev = try json.decode(BadgeEvent.self)
        XCTAssertEqual(ev.badge?.icon, "triangle-exclamation")
        XCTAssertEqual(ev.badge?.color, "orange")
    }

    // MARK: - Tab aggregation

    func testTabBadgesCollectBlocksAndTabSortedByPriority() {
        let store = BadgeStore()
        set(store, "block:b1", badge("0001", priority: 5))
        set(store, "block:b2", badge("0002", priority: 20))
        set(store, "tab:t1", badge("0003", priority: 5))
        set(store, "block:other", badge("0004", priority: 99))
        let ids = store.tabBadges(tabId: "t1", blockIds: ["b1", "b2"]).map(\.badgeid)
        XCTAssertEqual(ids, ["0002", "0001", "0003"], "priority desc, then oldest id first")
    }

    // MARK: - Auto-clear targets

    func testAutoClearTargetsSkipPidLinkedAndUnfocused() {
        let store = BadgeStore()
        set(store, "block:focused", badge("0001"))
        set(store, "block:other", badge("0002"))
        set(store, "tab:t1", badge("0003", pidlinked: true))
        XCTAssertEqual(
            AppCoordinator.badgeAutoClearTargets(store: store, tabId: "t1", focusedBlockId: "focused"),
            ["block:focused"])
        set(store, "block:focused", badge("0009", priority: 50, pidlinked: true))
        XCTAssertEqual(
            AppCoordinator.badgeAutoClearTargets(store: store, tabId: "t1", focusedBlockId: "focused"), [])
    }

    // MARK: - Rendering helpers

    func testIconAndColorMapping() {
        XCTAssertEqual(WorkspaceSwitcherView.symbolName(forWaveIcon: "triangle-exclamation"),
                       "exclamationmark.triangle.fill")
        XCTAssertEqual(WorkspaceSwitcherView.symbolName(forWaveIcon: "circle-check"), "checkmark.circle.fill")
        XCTAssertEqual(WorkspaceSwitcherView.symbolName(forWaveIcon: "power-off"), "power")
        // Unlisted names resolve heuristically: verbatim SF names, circle-x, a-b → a.b.fill.
        XCTAssertEqual(WorkspaceSwitcherView.symbolName(forWaveIcon: "bolt.horizontal.circle"), "bolt.horizontal.circle")
        XCTAssertEqual(WorkspaceSwitcherView.symbolName(forWaveIcon: "circle-pause"), "pause.circle.fill")
        XCTAssertEqual(WorkspaceSwitcherView.symbolName(forWaveIcon: "circle-plus"), "plus.circle.fill")
        XCTAssertEqual(WorkspaceSwitcherView.symbolName(forWaveIcon: "person-circle"), "person.circle.fill")
        XCTAssertEqual(WorkspaceSwitcherView.symbolName(forWaveIcon: "definitely-not-an-icon"),
                       WorkspaceSwitcherView.defaultIconSymbol)
        let orange = BadgeIndicatorView.color(for: Badge(badgeid: "1", icon: "x", color: "orange", priority: 1))
        XCTAssertNotEqual(orange, BadgeIndicatorView.defaultColor, "CSS colour names resolve")
        XCTAssertEqual(BadgeIndicatorView.color(for: badge("1")), BadgeIndicatorView.defaultColor)
    }

    func testPillFoldsFlagIntoBadges() {
        let pill = TabPillView(tabId: "t1", title: "T")
        pill.flagColor = "#ff0000"
        XCTAssertTrue(pill.displayedBadges.isEmpty, "no wsh badges → plain flag path")
        pill.badges = [badge("0001")]
        XCTAssertEqual(pill.displayedBadges.map(\.icon), ["circle-small", "flag"])
    }

    // MARK: - Coordinator routing

    func testBadgeEventReachesTabStrip() async throws {
        let t = FakeTransport()
        let s = FakeStore()
        s.preload(.window(Window(oid: "win-1", version: 1, workspaceid: "ws-1",
                                 pos: Point(x: 0, y: 0), winsize: WinSize(width: 1, height: 1),
                                 lastfocusts: 0, meta: [:])))
        s.preload(.workspace(Workspace(oid: "ws-1", version: 1, name: "Default",
                                       tabids: ["tab-1", "tab-2"], activetabid: "tab-1", meta: [:])))
        s.preload(.tab(Tab(oid: "tab-1", version: 1, name: "One", layoutstate: "layout:lay-1",
                           blockids: ["blk-1"], meta: [:])))
        s.preload(.tab(Tab(oid: "tab-2", version: 1, name: "Two", layoutstate: "layout:lay-2",
                           blockids: ["blk-2"], meta: [:])))
        s.preload(.layout(LayoutState(oid: "lay-1", version: 1)))
        s.preload(.layout(LayoutState(oid: "lay-2", version: 1)))
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        let payload = BadgeEvent(oref: "block:blk-2", badge: Badge(
            badgeid: "0199", icon: "triangle-exclamation", color: "orange", priority: 10))
        t.emit(WaveEvent(event: WaveEventName.badge, scopes: ["block:blk-2"], data: try JSONValue.encode(payload)))
        let shown = await waitUntil(timeout: 2) {
            delegate.lastTabs.first { $0.tabId == "tab-2" }?.badges.first?.icon == "triangle-exclamation"
        }
        XCTAssertTrue(shown, "a block badge must surface on its tab's pill")
        XCTAssertEqual(delegate.lastTabs.first { $0.tabId == "tab-1" }?.badges, [])

        t.emit(WaveEvent(event: WaveEventName.badge, scopes: ["block:blk-2"],
                         data: try JSONValue.encode(BadgeEvent(oref: "block:blk-2", clear: true))))
        let cleared = await waitUntil(timeout: 2) {
            delegate.lastTabs.first { $0.tabId == "tab-2" }?.badges.isEmpty == true
        }
        XCTAssertTrue(cleared)
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return condition()
    }
}
