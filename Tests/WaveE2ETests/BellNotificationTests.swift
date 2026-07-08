// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// Tests for terminal BELL + OSC desktop notifications:
//   - the pure visibility/suppression decision (notify unless the pane is visible),
//   - the `notification:enabled` gate,
//   - the tab-badge set-on-bell / clear-on-activate behavior (via the coordinator),
//   - the pill's unread-bell visibility mapping,
//   - the OSC 9 / OSC 777 notification scanner.
//
// The C bell-effect wiring (GHOSTTY_TERMINAL_OPT_BELL → GhosttySink.onBell) is
// integration-only — it requires a live libghostty terminal and a real BEL byte, so
// it is exercised by running the app, not here.

import XCTest
import AppKit
@testable import WaveCore
@testable import WaveLayout
@testable import WaveTerminal
@testable import WaveUI

@MainActor
final class BellNotificationTests: XCTestCase {

    // MARK: World (two tabs: tab-1 active, tab-2 background)

    private func makeWorld() -> (FakeTransport, FakeStore) {
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
        s.preload(.block(Block(oid: "blk-1", version: 1, meta: ["view": .string("term")])))
        s.preload(.block(Block(oid: "blk-2", version: 1, meta: ["view": .string("term")])))
        return (t, s)
    }

    // MARK: - Pure suppression decision

    func testSuppressedOnlyWhenPaneFullyVisible() {
        // Visible = active tab + key window + frontmost app → suppress the banner.
        XCTAssertFalse(AppCoordinator.shouldRaiseDesktopNotification(
            tabIsActive: true, windowIsKey: true, appIsActive: true, notificationsEnabled: true))
        // Any of those false ⇒ the user is not looking ⇒ notify.
        XCTAssertTrue(AppCoordinator.shouldRaiseDesktopNotification(
            tabIsActive: false, windowIsKey: true, appIsActive: true, notificationsEnabled: true))
        XCTAssertTrue(AppCoordinator.shouldRaiseDesktopNotification(
            tabIsActive: true, windowIsKey: false, appIsActive: true, notificationsEnabled: true))
        XCTAssertTrue(AppCoordinator.shouldRaiseDesktopNotification(
            tabIsActive: true, windowIsKey: true, appIsActive: false, notificationsEnabled: true))
    }

    func testDisabledSettingSuppressesEverything() {
        XCTAssertFalse(AppCoordinator.shouldRaiseDesktopNotification(
            tabIsActive: false, windowIsKey: false, appIsActive: false, notificationsEnabled: false),
            "notification:enabled=false must suppress even a clearly-backgrounded bell")
        XCTAssertFalse(AppCoordinator.notificationsEnabled(["notification:enabled": .bool(false)]))
        XCTAssertTrue(AppCoordinator.notificationsEnabled([:]), "default is enabled")
    }

    func testBadgeOnlyBackgroundTabs() {
        XCTAssertTrue(AppCoordinator.shouldBadgeTab(tabIsActive: false))
        XCTAssertFalse(AppCoordinator.shouldBadgeTab(tabIsActive: true))
    }

    // MARK: - Coordinator badge set on bell / clear on activate

    func testBellBadgesBackgroundTabAndClearsOnActivate() async throws {
        let (t, s) = makeWorld()
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        // A bell in the background tab (tab-2) badges it; the active tab is untouched.
        coordinator.handleBell(blockId: "blk-2", tabId: "tab-2")
        XCTAssertTrue(delegate.lastTabs.first { $0.tabId == "tab-2" }?.hasUnread ?? false,
                      "a background-tab bell must badge that tab")
        XCTAssertFalse(delegate.lastTabs.first { $0.tabId == "tab-1" }?.hasUnread ?? true,
                       "the active tab must not be badged")

        // A bell in the ACTIVE tab does not badge it.
        coordinator.handleBell(blockId: "blk-1", tabId: "tab-1")
        XCTAssertFalse(delegate.lastTabs.first { $0.tabId == "tab-1" }?.hasUnread ?? true,
                       "the active tab is never badged")

        // Activating the badged tab clears it.
        coordinator.selectTab("tab-2")
        let cleared = await waitUntil(timeout: 2) {
            delegate.lastTabs.first { $0.tabId == "tab-2" }?.hasUnread == false
        }
        XCTAssertTrue(cleared, "activating a badged tab must clear its unread badge")
    }

    func testNotificationRoutedToSinkWhenBackgrounded() async throws {
        let (t, s) = makeWorld()
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        var posted: [DesktopNotificationRequest] = []
        coordinator.onDesktopNotification = { posted.append($0) }
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        // Background tab (delegate reports window not key by default) ⇒ a desktop
        // notification is emitted, carrying the routing identity.
        coordinator.handleNotification(blockId: "blk-2", tabId: "tab-2", title: "Build", body: "done")
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted.first?.blockId, "blk-2")
        XCTAssertEqual(posted.first?.tabId, "tab-2")
        XCTAssertEqual(posted.first?.title, "Build")
        XCTAssertEqual(posted.first?.body, "done")
    }

    // MARK: - Pill unread indicator mapping

    func testPillUnreadVisibility() {
        let pill = TabPillView(tabId: "tab-1", title: "Tab")
        XCTAssertFalse(pill.isUnreadVisible, "a fresh pill has no unread bell")
        pill.hasUnread = true
        XCTAssertTrue(pill.isUnreadVisible, "an unread background pill shows the bell")
        // The active tab never shows the bell (it is visible).
        pill.isActive = true
        XCTAssertFalse(pill.isUnreadVisible, "the active tab hides the unread bell")
    }

    // MARK: - OSC notification scanner

    private func notifications(_ events: [OSCEvent]) -> [TerminalNotification] {
        events.compactMap { event -> TerminalNotification? in
            if case .notification(let n) = event { return n }
            return nil
        }
    }

    private func clipboards(_ events: [OSCEvent]) -> [Data] {
        events.compactMap { event -> Data? in
            if case .clipboardCopy(let d) = event { return d }
            return nil
        }
    }

    private func scan(_ s: String) -> [TerminalNotification] {
        var scanner = OSCNotificationScanner()
        return notifications(scanner.scan(Data(s.utf8)))
    }

    private func scanClipboard(_ s: String) -> [Data] {
        var scanner = OSCNotificationScanner()
        return clipboards(scanner.scan(Data(s.utf8)))
    }

    func testOSC9NotificationBELTerminated() {
        let out = scan("\u{1b}]9;Hello there\u{07}")
        XCTAssertEqual(out, [TerminalNotification(title: nil, body: "Hello there")])
    }

    func testOSC9NotificationSTTerminated() {
        let out = scan("\u{1b}]9;Build complete\u{1b}\\")
        XCTAssertEqual(out, [TerminalNotification(title: nil, body: "Build complete")])
    }

    func testOSC9ConEmuProgressIgnored() {
        // ConEmu progress (`9;4;50`) and ghostty pwd (`9;9;/path`) must NOT notify.
        XCTAssertTrue(scan("\u{1b}]9;4;50\u{07}").isEmpty)
        XCTAssertTrue(scan("\u{1b}]9;9;/home/me\u{07}").isEmpty)
    }

    func testOSC777TitleAndBody() {
        let out = scan("\u{1b}]777;notify;Title;Body text\u{07}")
        XCTAssertEqual(out, [TerminalNotification(title: "Title", body: "Body text")])
    }

    func testNotificationStraddlingChunks() {
        var scanner = OSCNotificationScanner()
        XCTAssertTrue(scanner.scan(Data("\u{1b}]9;Split ".utf8)).isEmpty)
        let out = notifications(scanner.scan(Data("message\u{07}".utf8)))
        XCTAssertEqual(out, [TerminalNotification(title: nil, body: "Split message")])
    }

    func testPlainBytesDoNotNotify() {
        XCTAssertTrue(scan("just some normal output\nwith a \u{07} bell\n").isEmpty,
                      "a bare BEL is a bell, not an OSC notification")
    }

    // MARK: - OSC 52 clipboard scanner

    func testOSC52ClipboardWriteBEL() {
        let b64 = Data("hello osc52".utf8).base64EncodedString()
        XCTAssertEqual(scanClipboard("\u{1b}]52;c;\(b64)\u{07}"), [Data("hello osc52".utf8)])
    }

    func testOSC52ClipboardWriteSTTerminated() {
        let b64 = Data("via ST".utf8).base64EncodedString()
        let out = scanClipboard("\u{1b}]52;c;\(b64)\u{1b}\\")
        XCTAssertEqual(out.map { String(decoding: $0, as: UTF8.self) }, ["via ST"])
    }

    func testOSC52EmptyTargetDefaultsToClipboard() {
        let b64 = Data("no target".utf8).base64EncodedString()
        XCTAssertEqual(scanClipboard("\u{1b}]52;;\(b64)\u{07}"), [Data("no target".utf8)])
    }

    func testOSC52MultibyteUTF8RoundTrips() {
        let text = "café — 日本語 🎉"
        let b64 = Data(text.utf8).base64EncodedString()
        let out = scanClipboard("\u{1b}]52;c;\(b64)\u{07}")
        XCTAssertEqual(out.map { String(decoding: $0, as: UTF8.self) }, [text])
    }

    func testOSC52ReadQueryIgnored() {
        // A read request (`52;c;?`) must NOT surface an event — honoring it would let a
        // program running in the terminal exfiltrate the host clipboard.
        var scanner = OSCNotificationScanner()
        XCTAssertTrue(scanner.scan(Data("\u{1b}]52;c;?\u{07}".utf8)).isEmpty)
    }

    func testOSC52StraddlingChunks() {
        let b64 = Data("straddle".utf8).base64EncodedString()
        var scanner = OSCNotificationScanner()
        let mid = b64.index(b64.startIndex, offsetBy: 2)
        XCTAssertTrue(scanner.scan(Data("\u{1b}]52;c;\(b64[..<mid])".utf8)).isEmpty)
        let out = clipboards(scanner.scan(Data("\(b64[mid...])\u{07}".utf8)))
        XCTAssertEqual(out, [Data("straddle".utf8)])
    }

    func testOSC52OversizedPayloadAbandoned() {
        // A never-terminated OSC 52 beyond the payload cap must not crash or emit.
        var scanner = OSCNotificationScanner()
        let huge = String(repeating: "A", count: (1 << 20) + 10)
        XCTAssertTrue(scanner.scan(Data("\u{1b}]52;c;\(huge)".utf8)).isEmpty)
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
