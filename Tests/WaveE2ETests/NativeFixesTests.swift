// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI regression tests for seven hands-on bugs (multi-window + chrome batch):
//   1) Cmd-N opens a new WINDOW (not a new block).
//   2) A freshly-created workspace opens with exactly ONE tab.
//   3) The top-bar workspace dropdown routes a selection to the focus-or-open seam.
//   4) A tab flag set/clear updates the pill's rendered state synchronously.
//   5) A workspace:update event refreshes EVERY coordinator's cached workspace list.
//   6) Each block header exposes magnify + settings + close actions.
//   7) Rename issues the correct UpdateTabName call and restores pane focus on commit.
//
// All logic-level (no GUI): they exercise routing/state, not pixels. The fakes
// (`FakeTransport`, `FakeStore`) live in WaveUITests.swift (same test target).

import XCTest
import AppKit
@testable import WaveCore
@testable import WaveLayout
@testable import WaveUI

@MainActor
final class NativeFixesTests: XCTestCase {

    // MARK: World

    /// A backend world whose single workspace has `tabCount` tabs — models a
    /// freshly-created workspace (1 tab) vs. a restored one.
    private func makeWorld(tabCount: Int) -> (FakeTransport, FakeStore) {
        let t = FakeTransport()
        let s = FakeStore()
        let tabIds = (1...tabCount).map { "tab-\($0)" }
        s.preload(.window(Window(oid: "win-1", version: 1, workspaceid: "ws-1",
                                 pos: Point(x: 0, y: 0), winsize: WinSize(width: 1, height: 1),
                                 lastfocusts: 0, meta: [:])))
        s.preload(.workspace(Workspace(oid: "ws-1", version: 1, name: "Default",
                                       tabids: tabIds, activetabid: tabIds[0], meta: [:])))
        for (i, id) in tabIds.enumerated() {
            s.preload(.tab(Tab(oid: id, version: 1, name: "Tab \(i + 1)",
                               layoutstate: "layout:lay-\(i + 1)", blockids: ["blk-\(i + 1)"], meta: [:])))
            s.preload(.layout(LayoutState(oid: "lay-\(i + 1)", version: 1)))
            s.preload(.block(Block(oid: "blk-\(i + 1)", version: 1, meta: ["view": .string("term")])))
        }
        return (t, s)
    }

    // MARK: - Bug 1: Cmd-N → new window

    func testCmdNRoutesToNewWindow() {
        XCTAssertEqual(WaveWindowController.letterAction(lower: "n", shift: false), .newWindow,
                       "Cmd-N must open a new window, not a new block/tab")
        // Cmd-T must remain new-tab (not regressed by the Cmd-N change).
        XCTAssertEqual(WaveWindowController.letterAction(lower: "t", shift: false), .newTab)
        // Cmd-Shift-N is not a shortcut (only plain Cmd-N maps).
        XCTAssertNil(WaveWindowController.letterAction(lower: "n", shift: true))
    }

    // MARK: - First-run bootstrap: a client with no windows creates one

    func testFirstRunBootstrapCreatesWindowWhenClientHasNoWindows() async throws {
        // All-windows-closed: GetClientData returns windowids:[]. The coordinator must
        // CreateWindow to bootstrap, not throw "client has no windows".
        let (t, s) = makeWorld(tabCount: 1) // preloads win-1 + ws-1 + tab + layout + block
        t.clientData = Client(oid: "client-1", version: 1, windowids: [], meta: [:])
        t.createWindowResponse = try JSONValue.encode(
            Window(oid: "win-1", version: 1, workspaceid: "ws-1",
                   pos: Point(x: 0, y: 0), winsize: WinSize(width: 1, height: 1),
                   lastfocusts: 0, meta: [:]))
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2) // binds successfully → ready
        XCTAssertTrue(t.recorded().contains { $0.method == "CreateWindow" },
                      "a client with no windows must bootstrap one via CreateWindow")
    }

    // MARK: - Bug 8: workspace popover renders items set before the view loads

    @MainActor
    func testWorkspaceMenuRendersItemsSetBeforeViewLoads() {
        // Reproduces "popover shows but no content": setItems runs BEFORE the view
        // loads (the controller is configured, then assigned to the popover), so the
        // rows must still render once viewDidLoad fires.
        let controller = WorkspaceMenuController()
        controller.setItems([
            WorkspaceMenuItem(workspaceId: "w1", name: "Alpha", icon: nil, color: nil),
            WorkspaceMenuItem(workspaceId: "w2", name: "Beta", icon: nil, color: nil),
        ], active: "w1")
        _ = controller.view // force the lazy load -> viewDidLoad -> rebuild
        // Two workspaces + the trailing "New workspace" row.
        XCTAssertEqual(controller.clickableRows.count, 3)
    }

    // MARK: - Bug 2: created/restored workspace opens with one tab (no extra tab)

    func testCreatedWorkspaceWindowDoesNotAddExtraTab() async throws {
        // A window whose active tab already has a block must NOT open a second tab nor
        // seed a redundant block — it opens with exactly one tab.
        let (t, s) = makeWorld(tabCount: 1) // tab-1 has blockids ["blk-1"]
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(t.recorded().contains { $0.method == "CreateTab" },
                       "a window must not open a second tab on startup")
        XCTAssertEqual(delegate.lastTabs.count, 1, "the window must open with one tab")
    }

    // MARK: - Issue 1: an empty starter tab gets a default terminal block in-place

    /// A world whose single workspace has one active tab with ZERO blocks (the
    /// first-run starter tab the backend leaves empty pre-onboarding).
    private func makeEmptyTabWorld() -> (FakeTransport, FakeStore) {
        let t = FakeTransport()
        let s = FakeStore()
        s.preload(.window(Window(oid: "win-1", version: 1, workspaceid: "ws-1",
                                 pos: Point(x: 0, y: 0), winsize: WinSize(width: 1, height: 1),
                                 lastfocusts: 0, meta: [:])))
        s.preload(.workspace(Workspace(oid: "ws-1", version: 1, name: "Default",
                                       tabids: ["tab-1"], activetabid: "tab-1", meta: [:])))
        s.preload(.tab(Tab(oid: "tab-1", version: 1, name: "One",
                           layoutstate: "layout:lay-1", blockids: [], meta: [:])))
        s.preload(.layout(LayoutState(oid: "lay-1", version: 1)))
        return (t, s)
    }

    func testEmptyActiveTabGetsDefaultTerminalBlock() async throws {
        let (t, s) = makeEmptyTabWorld()
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)
        let created = await waitUntil(timeout: 2) {
            t.recordedGeneric().contains { $0.command == "createblock" }
        }
        XCTAssertTrue(created, "an empty active tab must get a default terminal block (createblock)")
        XCTAssertFalse(t.recorded().contains { $0.method == "CreateTab" },
                       "the empty tab is seeded in-place — no second tab is opened")
    }

    func testNonEmptyActiveTabDoesNotAddBlock() async throws {
        let (t, s) = makeWorld(tabCount: 1) // tab-1 already has blockids ["blk-1"]
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(t.recordedGeneric().contains { $0.command == "createblock" },
                       "a tab that already has a block must not be double-seeded")
    }

    // MARK: - Issue 2: bootstrapped workspace stays EPHEMERAL (unnamed by default)

    func testFirstRunBootstrapLeavesWorkspaceUnnamed() async throws {
        let (t, s) = makeWorld(tabCount: 1)
        t.clientData = Client(oid: "client-1", version: 1, windowids: [], meta: [:])
        t.createWindowResponse = try JSONValue.encode(
            Window(oid: "win-1", version: 1, workspaceid: "ws-1",
                   pos: Point(x: 0, y: 0), winsize: WinSize(width: 1, height: 1),
                   lastfocusts: 0, meta: [:]))
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)
        // Bootstrap must NOT auto-name the workspace: an unnamed workspace is scratch
        // (hidden from the switcher, GC'd on close) until the user explicitly saves it.
        let promoted = t.recordedServiceArgs().contains {
            $0.method == "UpdateWorkspace"
                && $0.args == [.string("ws-1"), .string(""), .string(""), .string(""), .bool(true)]
        }
        XCTAssertFalse(promoted,
                       "bootstrap must leave the workspace ephemeral, not promote it via UpdateWorkspace(applyDefaults:true)")
    }

    // MARK: - Issue 3: workspace popover sizes to its rows (no empty space)

    func testWorkspaceMenuPopoverSizesToRows() {
        let controller = WorkspaceMenuController()
        _ = controller.view
        controller.setItems([
            WorkspaceMenuItem(workspaceId: "w1", name: "A", icon: nil, color: nil),
            WorkspaceMenuItem(workspaceId: "w2", name: "B", icon: nil, color: nil),
        ], active: "w1")
        XCTAssertEqual(controller.clickableRows.count, 3, "two workspaces + the create row")
        let twoHeight = controller.preferredContentSize.height

        controller.setItems([
            WorkspaceMenuItem(workspaceId: "w1", name: "A", icon: nil, color: nil),
        ], active: "w1")
        XCTAssertEqual(controller.clickableRows.count, 2, "one workspace + the create row")
        let oneHeight = controller.preferredContentSize.height

        XCTAssertLessThan(oneHeight, twoHeight, "the popover must shrink with fewer rows")
        // List area: 8 top + rows*28 + 2 spacing between + 4 bottom; footer: 28 row + 8 bottom.
        let listRows = CGFloat(controller.clickableRows.count - 1)
        let expected = 8 + listRows * 28 + Swift.max(listRows - 1, 0) * 2 + 4 + 28 + 8
        XCTAssertEqual(oneHeight, expected, accuracy: 1.5,
                       "popover height must track the row count + insets")
    }

    // MARK: - Dropdown caps its height (long list scrolls instead of overflowing)

    func testWorkspaceMenuCapsHeightToMaxContentHeight() {
        let controller = WorkspaceMenuController()
        controller.maxContentHeight = 300
        _ = controller.view
        controller.setItems((1...40).map {
            WorkspaceMenuItem(workspaceId: "w\($0)", name: "WS \($0)", icon: nil, color: nil)
        }, active: "w1")
        XCTAssertEqual(controller.clickableRows.count, 41, "40 workspaces + the create row")
        XCTAssertEqual(controller.preferredContentSize.height, 300,
                       "an over-tall list must cap at maxContentHeight and scroll")

        controller.maxContentHeight = .greatestFiniteMagnitude
        controller.setItems([WorkspaceMenuItem(workspaceId: "w1", name: "A", icon: nil, color: nil)],
                            active: "w1")
        XCTAssertLessThan(controller.preferredContentSize.height, 300,
                          "a short list must NOT be padded up to the cap")
    }

    // MARK: - New workspace is composed (name + Save) and only created on save

    func testWorkspaceMenuComposerCreatesOnlyOnSave() {
        let controller = WorkspaceMenuController()
        _ = controller.view
        controller.setItems([WorkspaceMenuItem(workspaceId: "w1", name: "A", icon: nil, color: nil)],
                            active: "w1")
        var created: String?
        controller.onCreate = { created = $0 }

        // Clicking "+ New workspace" expands the footer composer — nothing is created.
        controller.clickableRows.last?.performClick()
        XCTAssertTrue(controller.creatingNew, "the composer must expand")
        XCTAssertNotNil(controller.createNameField, "the composer carries a name field")
        XCTAssertNil(created, "no workspace may be created before Save")

        // Saving with a blank name is a no-op (never create an unnamed workspace).
        controller.createNameField?.stringValue = "   "
        controller.commitCreate()
        XCTAssertNil(created)
        XCTAssertTrue(controller.creatingNew)

        // Saving a real name fires onCreate with the trimmed name.
        controller.createNameField?.stringValue = "  Prod  "
        controller.commitCreate()
        XCTAssertEqual(created, "Prod")
        XCTAssertFalse(controller.creatingNew)
    }

    func testWorkspaceMenuComposerCancelDiscards() {
        let controller = WorkspaceMenuController()
        _ = controller.view
        controller.setItems([WorkspaceMenuItem(workspaceId: "w1", name: "A", icon: nil, color: nil)],
                            active: "w1")
        var created: String?
        controller.onCreate = { created = $0 }
        controller.beginCreate()
        controller.createNameField?.stringValue = "Draft"
        controller.cancelCreate()
        XCTAssertFalse(controller.creatingNew, "Escape collapses the composer")
        XCTAssertNil(created, "cancel must not create anything")
        let last = controller.clickableRows.last
        XCTAssertNotNil(last, "the '+ New workspace' action row must come back after cancel")
    }

    // MARK: - Issue 4: Cmd-R reloads, Cmd-W closes the focused (web) block

    func testReloadAndCloseLetterActions() {
        XCTAssertEqual(WaveWindowController.letterAction(lower: "r", shift: false), .reload,
                       "Cmd-R must reload the focused (web) block")
        XCTAssertEqual(WaveWindowController.letterAction(lower: "r", shift: true), .reload,
                       "Cmd-Shift-R must also reload the focused (web) block")
        XCTAssertEqual(WaveWindowController.letterAction(lower: "w", shift: false), .closeBlock,
                       "Cmd-W must close the focused block (terminal or web)")
    }

    // MARK: - Web pane ⌘ preemption: history keys stay with the page

    func testWebHistoryKeysExcludedFromPreempt() {
        XCTAssertTrue(WaveWindowController.isWebHistoryKey(scalar: UInt32(NSLeftArrowFunctionKey)),
                      "⌘← must stay with a focused web page (history back), not switch tabs")
        XCTAssertTrue(WaveWindowController.isWebHistoryKey(scalar: UInt32(NSRightArrowFunctionKey)),
                      "⌘→ must stay with a focused web page (history forward), not switch tabs")
        XCTAssertFalse(WaveWindowController.isWebHistoryKey(scalar: UInt32(UnicodeScalar("d").value)),
                       "⌘D is an app-global (split) — preempted from a web pane")
        XCTAssertFalse(WaveWindowController.isWebHistoryKey(scalar: UInt32(UnicodeScalar("[").value)),
                       "⌘[ stays tab switching, matching non-web panes")
        XCTAssertFalse(WaveWindowController.isWebHistoryKey(scalar: nil))
    }

    // MARK: - Bug 3: workspace dropdown selection fires the focus-or-open seam

    func testWorkspaceDropdownSelectionFiresOnSelect() {
        let controller = WorkspaceMenuController()
        _ = controller.view // force loadView so the rows build
        controller.setItems([
            WorkspaceMenuItem(workspaceId: "ws-a", name: "A", icon: nil, color: nil),
            WorkspaceMenuItem(workspaceId: "ws-b", name: "B", icon: nil, color: nil),
        ], active: "ws-a")

        var selected: String?
        controller.onSelect = { selected = $0 }
        let rows = controller.clickableRows
        XCTAssertEqual(rows.count, 3, "two workspace rows + the create row")
        rows[1].performClick() // workspace B

        XCTAssertEqual(selected, "ws-b",
                       "selecting a workspace must fire onSelect (→ WaveWindowController.focusOrOpen)")
    }

    // MARK: - Bug 4: flag state → display mapping is synchronous

    func testTabPillFlagStateUpdatesImmediately() {
        let pill = TabPillView(tabId: "tab-1", title: "Tab")
        XCTAssertFalse(pill.isFlagVisible, "a fresh pill has no flag")

        pill.flagColor = "#58C142"
        XCTAssertTrue(pill.isFlagVisible, "setting a flag color must show the flag at once")

        pill.flagColor = nil
        XCTAssertFalse(pill.isFlagVisible, "clearing the flag must hide it at once")
    }

    // MARK: - Bug 5: workspace:update refreshes every coordinator's list

    func testWorkspaceUpdateEventRefreshesWorkspaceList() async throws {
        let (t, s) = makeWorld(tabCount: 1)
        t.workspaceListResponse = try JSONValue.encode([
            WorkspaceListEntry(workspaceid: "ws-1", windowid: "win-1"),
        ])
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = WorkspaceListDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)
        XCTAssertEqual(delegate.lastList.count, 1, "startup list has one workspace")

        // Another window created ws-2: the backend fires workspace:update (no payload).
        t.workspaceListResponse = try JSONValue.encode([
            WorkspaceListEntry(workspaceid: "ws-1", windowid: "win-1"),
            WorkspaceListEntry(workspaceid: "ws-2", windowid: "win-2"),
        ])
        t.emit(WaveEvent(event: WaveEventName.workspaceUpdate))

        let propagated = await waitUntil(timeout: 2) {
            delegate.lastList.contains { $0.workspaceId == "ws-2" }
        }
        XCTAssertTrue(propagated, "workspace:update must re-pull the list so other windows see ws-2")
    }

    // MARK: - Bug 6: per-pane header button set

    func testBlockHeaderButtonSet() {
        // A term pane in a multi-pane tab exposes magnify + settings + close.
        XCTAssertEqual(BlockFrameView.headerButtons(canMagnify: true),
                       [.magnify, .settings, .close])
        // A single-pane tab has nothing to magnify, but still has settings + close.
        XCTAssertEqual(BlockFrameView.headerButtons(canMagnify: false),
                       [.settings, .close])
    }

    // MARK: - Header double-click toggles magnify (before the drag tracking loop)

    func testHeaderDoubleClickTogglesMagnify() throws {
        let store = FakeStore()
        store.preload(.block(Block(oid: "blk-hdr", version: 1, meta: ["view": .string("term")])))
        let env = BlockEnv(transport: FakeTransport(), store: store,
                           blockRef: ORef.block("blk-hdr"), tabId: "tab-1", windowId: "win-1")
        let view = BlockFrameView(nodeId: "n1", env: env, provider: DefaultBlockViewProvider())
        view.frame = CGRect(x: 0, y: 0, width: 300, height: 220)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()

        var magnified: [String] = []
        var dragStarts = 0
        view.canMagnify = true
        view.onToggleMagnify = { magnified.append($0) }
        view.onHeaderDrag = { _, _ in dragStarts += 1 }

        func headerClick(_ clickCount: Int) throws -> NSEvent {
            // Compute the location FROM the header so flippedness can't misplace it.
            let inWindow = view.headerViewForTesting.convert(NSPoint(x: 40, y: 10), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: inWindow, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: clickCount, pressure: 1))
        }

        view.mouseDown(with: try headerClick(2))
        XCTAssertEqual(magnified, ["n1"], "header double-click must toggle magnify")
        XCTAssertEqual(dragStarts, 0, "double-click must not enter the drag tracking loop")

        view.mouseDown(with: try headerClick(1))
        XCTAssertEqual(dragStarts, 1, "single click still starts the header drag")

        view.canMagnify = false
        view.mouseDown(with: try headerClick(2))
        XCTAssertEqual(magnified.count, 1, "single-pane tab: double-click stays a no-op")
    }

    // MARK: - Bug 7a: rename issues the correct UpdateTabName call

    func testRenameTabIssuesUpdateTabNameCall() async throws {
        let (t, s) = makeWorld(tabCount: 1)
        let coordinator = AppCoordinator(transport: t, store: s)
        coordinator.renameTab(tabId: "tab-1", name: "Renamed")
        let issued = await waitUntil(timeout: 2) {
            t.recordedVoid().contains { $0.command == "updatetabname" }
        }
        XCTAssertTrue(issued, "rename must issue the updatetabname wsh command")
        let call = try XCTUnwrap(t.recordedVoid().first { $0.command == "updatetabname" })
        // MultiArg encodes positionally as { args: [tabId, newName] }.
        XCTAssertEqual(call.data, .object(["args": .array([.string("tab-1"), .string("Renamed")])]),
                       "updatetabname must carry [tabId, newName]")
    }

    // MARK: - Bug 7b: rename commit restores pane focus

    func testRenameCommitRequestsFocusRestoration() {
        let pill = TabPillView(tabId: "tab-1", title: "Tab")
        var restored = 0
        pill.onRenameSessionEnd = { restored += 1 }

        pill.startRename()
        pill.commitRename()
        XCTAssertEqual(restored, 1, "committing a rename must request focus restoration")

        pill.startRename()
        pill.cancelRename()
        XCTAssertEqual(restored, 2, "cancelling a rename must also restore focus")
    }

    // MARK: - Feature 1: open-in-window / current badge

    func testWorkspaceBadgeMapping() {
        // Current workspace → checkmark (wins even if also open).
        XCTAssertEqual(WorkspaceMenuController.badgeSymbol(isCurrent: true, isOpen: true), "checkmark")
        XCTAssertEqual(WorkspaceMenuController.badgeSymbol(isCurrent: true, isOpen: false), "checkmark")
        // Open elsewhere (not current) → window glyph.
        XCTAssertEqual(WorkspaceMenuController.badgeSymbol(isCurrent: false, isOpen: true), "macwindow")
        // Neither → no badge.
        XCTAssertNil(WorkspaceMenuController.badgeSymbol(isCurrent: false, isOpen: false))
    }

    func testRefreshWorkspaceListMarksOpenAndCurrent() async throws {
        let (t, s) = makeWorld(tabCount: 1)
        t.workspaceListResponse = try JSONValue.encode([
            WorkspaceListEntry(workspaceid: "ws-1", windowid: "win-1"),
            WorkspaceListEntry(workspaceid: "ws-2", windowid: ""),
        ])
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = WorkspaceListDelegate()
        // ws-1 is shown in a live window; ws-2's backend windowid is stale (its NSWindow
        // closed) — isOpen must follow the live set, not the lingering windowid.
        delegate.openWorkspaceIds = ["ws-1"]
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        let current = try XCTUnwrap(delegate.lastList.first { $0.workspaceId == "ws-1" })
        let other = try XCTUnwrap(delegate.lastList.first { $0.workspaceId == "ws-2" })
        XCTAssertTrue(current.isOpen, "ws-1 is in a live window → open")
        XCTAssertTrue(current.isCurrent, "ws-1 is this window's active workspace → current")
        XCTAssertFalse(other.isOpen, "ws-2 has a stale windowid but no live window → not open")
        XCTAssertFalse(other.isCurrent, "ws-2 is not this window's workspace")
    }

    // MARK: - Feature 2: rename

    func testRenameWorkspaceIssuesUpdateWorkspaceCall() async throws {
        let (t, s) = makeWorld(tabCount: 1)
        let coordinator = AppCoordinator(transport: t, store: s)
        coordinator.renameWorkspace("ws-1", name: "Renamed")
        let issued = await waitUntil(timeout: 2) {
            t.recordedServiceArgs().contains { $0.method == "UpdateWorkspace" }
        }
        XCTAssertTrue(issued, "rename must issue UpdateWorkspace")
        let call = try XCTUnwrap(t.recordedServiceArgs().first { $0.method == "UpdateWorkspace" })
        // [workspaceId, name, icon, color, applyDefaults] — rename sets only the name.
        XCTAssertEqual(call.args, [.string("ws-1"), .string("Renamed"), .string(""), .string(""), .bool(false)])
    }

    func testDeleteWorkspaceIssuesDeleteWorkspaceCall() async throws {
        let (t, s) = makeWorld(tabCount: 1)
        let coordinator = AppCoordinator(transport: t, store: s)
        coordinator.deleteWorkspace("ws-1")
        let issued = await waitUntil(timeout: 2) {
            t.recordedServiceArgs().contains { $0.method == "DeleteWorkspace" }
        }
        XCTAssertTrue(issued, "delete must issue DeleteWorkspace")
        let call = try XCTUnwrap(t.recordedServiceArgs().first { $0.method == "DeleteWorkspace" })
        XCTAssertEqual(call.args, [.string("ws-1")])
    }

    // MARK: - Feature: workspace layout save / restore
    // (left-click switcher button opens the viewer; right-click opens Save/Reset for the
    //  ACTIVE workspace)

    func testLayoutMenuBuildsBothItemsResetDisabledWithoutSnapshot() {
        let menu = WorkspaceSwitcherView.makeLayoutMenu(hasSavedLayout: false, onSave: {}, onReset: {})
        XCTAssertEqual(menu.items.map(\.title), ["Save Layout", "Reset to Saved Layout"])
        XCTAssertTrue(menu.items[0].isEnabled, "Save Layout is always available")
        XCTAssertFalse(menu.items[1].isEnabled, "Reset must be disabled without a snapshot")
    }

    func testLayoutMenuResetEnabledWithSnapshot() {
        let menu = WorkspaceSwitcherView.makeLayoutMenu(hasSavedLayout: true, onSave: {}, onReset: {})
        XCTAssertTrue(menu.items[1].isEnabled, "Reset must be enabled when a snapshot exists")
    }

    func testLayoutMenuActionsFireCallbacks() throws {
        var saved = false
        var reset = false
        let menu = WorkspaceSwitcherView.makeLayoutMenu(
            hasSavedLayout: true, onSave: { saved = true }, onReset: { reset = true })
        try XCTUnwrap(menu.items[0] as? ClosureMenuItem).performAction()
        try XCTUnwrap(menu.items[1] as? ClosureMenuItem).performAction()
        XCTAssertTrue(saved)
        XCTAssertTrue(reset)
    }

    @MainActor
    func testSwitcherRightClickMenuTargetsActiveWorkspace() throws {
        let switcher = WorkspaceSwitcherView(frame: .zero)
        var savedId: String?
        var resetId: String?
        switcher.onSaveWorkspaceLayout = { savedId = $0 }
        switcher.onResetWorkspaceLayout = { resetId = $0 }
        switcher.setActive(name: "Alpha", icon: "star", color: nil, workspaceId: "w7")
        switcher.setItems([
            WorkspaceMenuItem(workspaceId: "w7", name: "Alpha", icon: "star", color: nil,
                              isCurrent: true, hasSavedLayout: true),
        ])
        let menu = try XCTUnwrap(switcher.layoutMenuForActiveWorkspace())
        XCTAssertTrue(menu.items[1].isEnabled, "active workspace has a snapshot → Reset enabled")
        try XCTUnwrap(menu.items[0] as? ClosureMenuItem).performAction()
        try XCTUnwrap(menu.items[1] as? ClosureMenuItem).performAction()
        XCTAssertEqual(savedId, "w7", "Save must target the active workspace")
        XCTAssertEqual(resetId, "w7", "Reset must target the active workspace")
    }

    @MainActor
    func testSwitcherRightClickMenuNilWithoutActiveWorkspace() {
        let switcher = WorkspaceSwitcherView(frame: .zero)
        XCTAssertNil(switcher.layoutMenuForActiveWorkspace(),
                     "no active workspace → no layout menu (right-click falls through)")
    }

    func testSaveWorkspaceLayoutIssuesServiceCall() async throws {
        let (t, s) = makeWorld(tabCount: 1)
        let coordinator = AppCoordinator(transport: t, store: s)
        coordinator.saveWorkspaceLayout("ws-1")
        let issued = await waitUntil(timeout: 2) {
            t.recordedServiceArgs().contains { $0.method == "SaveWorkspaceLayout" }
        }
        XCTAssertTrue(issued, "save layout must issue SaveWorkspaceLayout")
        let call = try XCTUnwrap(t.recordedServiceArgs().first { $0.method == "SaveWorkspaceLayout" })
        XCTAssertEqual(call.args, [.string("ws-1")])
    }

    func testRestoreWorkspaceLayoutIssuesServiceCall() async throws {
        let (t, s) = makeWorld(tabCount: 1)
        let coordinator = AppCoordinator(transport: t, store: s)
        coordinator.restoreWorkspaceLayout("ws-1")
        let issued = await waitUntil(timeout: 2) {
            t.recordedServiceArgs().contains { $0.method == "RestoreWorkspaceLayout" }
        }
        XCTAssertTrue(issued, "reset layout must issue RestoreWorkspaceLayout")
        let call = try XCTUnwrap(t.recordedServiceArgs().first { $0.method == "RestoreWorkspaceLayout" })
        XCTAssertEqual(call.args, [.string("ws-1")])
    }

    func testRefreshWorkspaceListSetsHasSavedLayoutFromMeta() async throws {
        let (t, s) = makeWorld(tabCount: 1)
        // ws-1 carries a saved-layout snapshot; ws-2 does not.
        s.preload(.workspace(Workspace(oid: "ws-1", version: 1, name: "Default",
                                       tabids: ["tab-1"], activetabid: "tab-1",
                                       meta: [WorkspaceMenuItem.savedLayoutMetaKey: .bool(true)])))
        s.preload(.workspace(Workspace(oid: "ws-2", version: 1, name: "Other",
                                       tabids: [], activetabid: "", meta: [:])))
        t.workspaceListResponse = try JSONValue.encode([
            WorkspaceListEntry(workspaceid: "ws-1", windowid: "win-1"),
            WorkspaceListEntry(workspaceid: "ws-2", windowid: ""),
        ])
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = WorkspaceListDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        let withSnapshot = try XCTUnwrap(delegate.lastList.first { $0.workspaceId == "ws-1" })
        let without = try XCTUnwrap(delegate.lastList.first { $0.workspaceId == "ws-2" })
        XCTAssertTrue(withSnapshot.hasSavedLayout, "ws-1 has a saved-layout meta key")
        XCTAssertFalse(without.hasSavedLayout, "ws-2 has no saved-layout meta key")
    }

    // MARK: - Feature 3: color + icon picker

    func testIconMapCoversAllGetIconsNames() {
        // The backend's `WorkspaceService.GetIcons` set (wcore.WorkspaceIcons). Every
        // selectable icon must map to a distinct, non-default SF Symbol.
        let getIcons = ["custom@wave-logo-solid", "triangle", "star", "heart", "bolt",
                        "solid@cloud", "moon", "layer-group", "rocket", "flask",
                        "paperclip", "chart-line", "graduation-cap", "mug-hot"]
        var symbols = Set<String>()
        for name in getIcons {
            let symbol = WorkspaceSwitcherView.symbolName(forWaveIcon: name)
            XCTAssertNotEqual(symbol, WorkspaceSwitcherView.defaultIconSymbol,
                              "\(name) must map to a non-default symbol")
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
                            "\(name) → \(symbol) must be a valid SF Symbol")
            symbols.insert(symbol)
        }
        XCTAssertEqual(symbols.count, getIcons.count, "every GetIcons name maps to a distinct symbol")
    }

    func testSetWorkspaceColorAndIconIssueUpdateWorkspace() async throws {
        let (t, s) = makeWorld(tabCount: 1)
        let coordinator = AppCoordinator(transport: t, store: s)

        coordinator.setWorkspaceColor(id: "ws-1", color: "#429DFF")
        let colorIssued = await waitUntil(timeout: 2) {
            t.recordedServiceArgs().contains { $0.args.contains(.string("#429DFF")) }
        }
        XCTAssertTrue(colorIssued)
        let colorCall = try XCTUnwrap(t.recordedServiceArgs().first { $0.args.contains(.string("#429DFF")) })
        XCTAssertEqual(colorCall.method, "UpdateWorkspace")
        // Only the color field is set.
        XCTAssertEqual(colorCall.args, [.string("ws-1"), .string(""), .string(""), .string("#429DFF"), .bool(false)])

        coordinator.setWorkspaceIcon(id: "ws-1", icon: "rocket")
        let iconIssued = await waitUntil(timeout: 2) {
            t.recordedServiceArgs().contains { $0.args.contains(.string("rocket")) }
        }
        XCTAssertTrue(iconIssued)
        let iconCall = try XCTUnwrap(t.recordedServiceArgs().first { $0.args.contains(.string("rocket")) })
        // Only the icon field is set.
        XCTAssertEqual(iconCall.args, [.string("ws-1"), .string(""), .string("rocket"), .string(""), .bool(false)])
    }

    // MARK: - Feature 4: ephemeral / save

    func testSavedVsEphemeralDerivation() {
        // Saved requires BOTH a name and an icon.
        XCTAssertTrue(WorkspaceSwitcherView.isSaved(name: "Work", icon: "star"))
        XCTAssertFalse(WorkspaceSwitcherView.isSaved(name: "", icon: "star"))
        XCTAssertFalse(WorkspaceSwitcherView.isSaved(name: "Work", icon: ""))
        XCTAssertFalse(WorkspaceSwitcherView.isSaved(name: nil, icon: nil))
    }

    func testSaveWorkspaceAppliesDefaults() async throws {
        let (t, s) = makeWorld(tabCount: 1)
        let coordinator = AppCoordinator(transport: t, store: s)
        coordinator.saveWorkspace("ws-1")
        let issued = await waitUntil(timeout: 2) {
            t.recordedServiceArgs().contains { $0.method == "UpdateWorkspace" }
        }
        XCTAssertTrue(issued, "Save must issue UpdateWorkspace")
        let call = try XCTUnwrap(t.recordedServiceArgs().first { $0.method == "UpdateWorkspace" })
        // applyDefaults = true promotes the ephemeral workspace to saved.
        XCTAssertEqual(call.args, [.string("ws-1"), .string(""), .string(""), .string(""), .bool(true)])
    }

    // MARK: - Widget bar: config parse (sort / hidden filter / missing-meta skip)

    func testParseWidgetsSortsAndFilters() {
        let config: JSONValue = .object([
            "widgets": .object([
                // Hidden → excluded even though it has a valid blockdef.meta.
                "w-hidden": .object([
                    "display:order": .int(1),
                    "display:hidden": .bool(true),
                    "icon": .string("eye-slash"),
                    "blockdef": .object(["meta": .object(["view": .string("term")])]),
                ]),
                // Highest order → must sort LAST; carries magnified.
                "w-web": .object([
                    "display:order": .double(5.0),
                    "icon": .string("globe"),
                    "label": .string("web"),
                    "magnified": .bool(true),
                    "blockdef": .object(["meta": .object(["view": .string("web")])]),
                ]),
                // Lowest order → must sort FIRST.
                "w-term": .object([
                    "display:order": .int(-2),
                    "icon": .string("square-terminal"),
                    "blockdef": .object([
                        "meta": .object(["view": .string("term"), "controller": .string("shell")]),
                    ]),
                ]),
                // Missing blockdef.meta → skipped (cannot create a block).
                "w-broken": .object([
                    "display:order": .int(0),
                    "icon": .string("ghost"),
                    "blockdef": .object([:]),
                ]),
            ]),
        ])

        let items = AppCoordinator.parseWidgets(config)

        XCTAssertEqual(items.count, 2, "hidden and missing-meta widgets must be dropped")
        XCTAssertEqual(items.map(\.icon), ["square-terminal", "globe"], "sorted by display:order asc")
        XCTAssertEqual(items[0].blockDefMeta["view"], .string("term"))
        XCTAssertEqual(items[0].blockDefMeta["controller"], .string("shell"))
        XCTAssertFalse(items[0].magnified)
        XCTAssertTrue(items[1].magnified, "magnified flag must be parsed")
        XCTAssertEqual(items[1].label, "web")
    }

    func testParseWidgetsEmptyConfig() {
        XCTAssertTrue(AppCoordinator.parseWidgets(nil).isEmpty)
        XCTAssertTrue(AppCoordinator.parseWidgets(.object([:])).isEmpty)
    }

    // MARK: - Settings: setconfig RPC + config reload

    // The typed config-write wrapper must issue the `setconfig` command with the FLAT
    // meta (the bare dict, NOT nested under "settings").
    func testSetConfigIssuesSetconfigCommandWithFlatMeta() async throws {
        let t = FakeTransport()
        let s = FakeStore()
        let service = ServiceClient(transport: t, store: s)
        try await service.setConfig(["web:defaulturl": .string("https://wave.dev")])
        let call = try XCTUnwrap(t.recordedGeneric().first { $0.command == "setconfig" },
                                 "setConfig must issue the setconfig command")
        XCTAssertEqual(call.data, .object(["web:defaulturl": .string("https://wave.dev")]),
                       "setconfig payload must be the flat meta, not nested under settings")
    }

    // setConfigValue must send numbers as JSON numbers and a nil value as the JSON-null
    // delete sentinel.
    func testSetConfigValueSendsNumberAndDeleteSentinel() async throws {
        let (t, s) = makeWorld(tabCount: 1)
        let coordinator = AppCoordinator(transport: t, store: s)
        coordinator.setConfigValue("term:fontsize", .double(14))
        coordinator.setConfigValue("term:fontfamily", nil)
        let issued = await waitUntil(timeout: 2) {
            t.recordedGeneric().filter { $0.command == "setconfig" }.count >= 2
        }
        XCTAssertTrue(issued, "both setConfigValue calls must issue setconfig")
        let calls = t.recordedGeneric().filter { $0.command == "setconfig" }
        // A float is sent as a JSON number (it round-trips through JSON as int/double,
        // both of which the backend's float64 accepts) — never as a string.
        let fontCall = try XCTUnwrap(calls.first { $0.data?["term:fontsize"] != nil })
        XCTAssertEqual(fontCall.data?["term:fontsize"]?.doubleValue, 14)
        XCTAssertNil(fontCall.data?["term:fontsize"]?.stringValue, "a number must not be a string")
        XCTAssertTrue(calls.contains { $0.data == .object(["term:fontfamily": .null]) },
                      "a nil value must delete the key (JSON null)")
    }

    // MARK: - Config file editor (raw settings.json read/write)

    // writeConfigFile must issue the `filewrite` command addressing
    // <configHome>/settings.json with the whole file as std-base64 `data64`.
    func testWriteConfigFileIssuesFilewriteWithPathAndBase64() async throws {
        let t = FakeTransport()
        let s = FakeStore()
        let service = ServiceClient(transport: t, store: s)
        let text = "{\n  \"web:defaulturl\": \"https://wave.dev\"\n}"
        try await service.writeConfigFile(configHome: "/cfg/home", text: text)
        let call = try XCTUnwrap(t.recordedVoid().first { $0.command == "filewrite" },
                                 "writeConfigFile must issue the filewrite command")
        XCTAssertEqual(call.data?["info"]?["path"]?.stringValue, "/cfg/home/settings.json",
                       "filewrite must address <configHome>/settings.json")
        let d64 = try XCTUnwrap(call.data?["data64"]?.stringValue)
        XCTAssertEqual(WaveBase64.decode(d64).map { String(decoding: $0, as: UTF8.self) }, text,
                       "data64 must be the std-base64 of the WHOLE file text")
    }

    // readConfigFile must issue the `fileread` command addressing the settings path.
    func testReadConfigFileIssuesFilereadWithPath() async throws {
        let t = FakeTransport()
        let s = FakeStore()
        let service = ServiceClient(transport: t, store: s)
        _ = try await service.readConfigFile(configHome: "/cfg/home")
        let call = try XCTUnwrap(t.recordedGeneric().first { $0.command == "fileread" },
                                 "readConfigFile must issue the fileread command")
        XCTAssertEqual(call.data?["info"]?["path"]?.stringValue, "/cfg/home/settings.json")
    }

    // The config editor's JSON validation must reject non-object / malformed input BEFORE
    // any write, and accept a valid object (or empty file).
    func testConfigEditorJSONValidation() {
        XCTAssertNil(ConfigEditorWindowController.configJSONError("{\"a\": 1}"), "valid object passes")
        XCTAssertNil(ConfigEditorWindowController.configJSONError("   "), "empty/blank clears settings")
        XCTAssertNotNil(ConfigEditorWindowController.configJSONError("{ not json"), "malformed JSON rejected")
        XCTAssertNotNil(ConfigEditorWindowController.configJSONError("[1, 2, 3]"), "array rejected (must be object)")
        XCTAssertNotNil(ConfigEditorWindowController.configJSONError("42"), "primitive rejected")
    }

    // currentSettings() must surface the values under fullConfig["settings"].
    func testCurrentSettingsParsesSettingsKey() async throws {
        let (t, s) = makeWorld(tabCount: 1)
        t.fullConfigResponse = .object([
            "settings": .object([
                "web:defaulturl": .string("https://example.com"),
                "term:fontsize": .double(13),
            ]),
        ])
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)
        let settings = coordinator.currentSettings()
        XCTAssertEqual(settings["web:defaulturl"]?.stringValue, "https://example.com")
        XCTAssertEqual(settings["term:fontsize"]?.doubleValue, 13)
    }

    // A `config` event must re-pull fullConfig (so an open Settings window refreshes its
    // controls). Polled rather than observed: a NotificationCenter observer capturing an
    // XCTestExpectation across the async reload Tasks races with teardown (heap corruption).
    func testConfigEventReloadsFullConfig() async throws {
        let (t, s) = makeWorld(tabCount: 1)
        t.fullConfigResponse = .object(["settings": .object(["web:defaulturl": .string("https://a.com")])])
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)
        XCTAssertEqual(coordinator.currentSettings()["web:defaulturl"]?.stringValue, "https://a.com")

        // Another window changed the config: the backend fires `config` (no usable payload).
        t.fullConfigResponse = .object(["settings": .object(["web:defaulturl": .string("https://b.com")])])
        t.emit(WaveEvent(event: WaveEventName.config))

        let reloaded = await waitUntil(timeout: 2) {
            coordinator.currentSettings()["web:defaulturl"]?.stringValue == "https://b.com"
        }
        XCTAssertTrue(reloaded, "a config event must re-pull fullConfig so currentSettings reflects the change")
    }

    // MARK: - Tab bar position (app:tabbar)

    func testDeriveTabBarPositionFromSettings() {
        XCTAssertEqual(AppCoordinator.deriveTabBarPosition(["app:tabbar": .string("left")]), "left")
        XCTAssertEqual(AppCoordinator.deriveTabBarPosition(["app:tabbar": .string("top")]), "top")
        // Missing key -> default top.
        XCTAssertEqual(AppCoordinator.deriveTabBarPosition([:]), "top")
        // Unknown value -> default top.
        XCTAssertEqual(AppCoordinator.deriveTabBarPosition(["app:tabbar": .string("bogus")]), "top")
    }

    func testConfigDrivesTabBarPositionDelegate() async throws {
        let (t, s) = makeWorld(tabCount: 1)
        t.fullConfigResponse = .object(["settings": .object(["app:tabbar": .string("left")])])
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)
        XCTAssertEqual(delegate.lastTabBarPosition, "left",
                       "the app:tabbar setting must be pushed to the chrome on bind")
    }

    // The position property must re-arrange the pills: horizontal (x grows, y fixed) for
    // "top", vertical (y grows, x fixed) for "left". A pure layout assertion — no HID.
    func testTabBarPositionDrivesVerticalVsHorizontalArrangement() {
        let items = [
            TabBarItem(tabId: "t1", name: "One"),
            TabBarItem(tabId: "t2", name: "Two"),
            TabBarItem(tabId: "t3", name: "Three"),
        ]

        let top = TabBarView()
        top.frame = NSRect(x: 0, y: 0, width: 900, height: Theme.tabBarHeight)
        top.position = "top"
        top.setTabs(items, activeTabId: "t1")
        top.layoutSubtreeIfNeeded()
        let topFrames = top.pillFrames
        XCTAssertEqual(topFrames.count, 3)
        XCTAssertEqual(topFrames[0].minY, topFrames[1].minY, "top: rows share a Y")
        XCTAssertEqual(topFrames[1].minY, topFrames[2].minY, "top: rows share a Y")
        XCTAssertLessThan(topFrames[0].minX, topFrames[1].minX, "top: pills advance in X")
        XCTAssertLessThan(topFrames[1].minX, topFrames[2].minX, "top: pills advance in X")

        let left = TabBarView()
        left.frame = NSRect(x: 0, y: 0, width: Theme.tabBarLeftWidth, height: 600)
        left.position = "left"
        left.setTabs(items, activeTabId: "t1")
        left.layoutSubtreeIfNeeded()
        let leftFrames = left.pillFrames
        XCTAssertEqual(leftFrames.count, 3)
        XCTAssertEqual(leftFrames[0].minX, leftFrames[1].minX, "left: pills share an X")
        XCTAssertEqual(leftFrames[1].minX, leftFrames[2].minX, "left: pills share an X")
        XCTAssertLessThan(leftFrames[0].minY, leftFrames[1].minY, "left: pills stack down in Y")
        XCTAssertLessThan(leftFrames[1].minY, leftFrames[2].minY, "left: pills stack down in Y")
        XCTAssertGreaterThan(leftFrames[0].width, Theme.tabWidth,
                             "left: a pill is a full-width row, wider than a horizontal pill")
    }

    // MARK: - Tab drag & drop

    // Dropping a tab at an insertion index yields the right new order. `dropIndex` is an
    // insertion point in the ORIGINAL list (0...count).
    func testReorderTabIdsIndexMath() {
        let ids = ["a", "b", "c"]
        // Move first to the end.
        XCTAssertEqual(TabBarView.reorderedTabIds(ids, moving: "a", toIndex: 3), ["b", "c", "a"])
        // Move last to the front.
        XCTAssertEqual(TabBarView.reorderedTabIds(ids, moving: "c", toIndex: 0), ["c", "a", "b"])
        // Move middle to the front.
        XCTAssertEqual(TabBarView.reorderedTabIds(ids, moving: "b", toIndex: 0), ["b", "a", "c"])
        // Drop right after itself is a no-op (the gap on either side of the moving tab).
        XCTAssertEqual(TabBarView.reorderedTabIds(ids, moving: "a", toIndex: 1), ids)
        XCTAssertEqual(TabBarView.reorderedTabIds(ids, moving: "a", toIndex: 0), ids)
        // Unknown tab leaves the list untouched.
        XCTAssertEqual(TabBarView.reorderedTabIds(ids, moving: "z", toIndex: 2), ids)
    }

    func testDropReorderVsMoveDecision() {
        // Same workspace -> reorder.
        XCTAssertTrue(TabBarView.dropIsReorder(sourceWorkspaceId: "ws-1", destWorkspaceId: "ws-1"))
        // Different workspace -> move.
        XCTAssertFalse(TabBarView.dropIsReorder(sourceWorkspaceId: "ws-1", destWorkspaceId: "ws-2"))
        // Missing source (drag from outside / unknown) -> not a reorder.
        XCTAssertFalse(TabBarView.dropIsReorder(sourceWorkspaceId: "", destWorkspaceId: "ws-1"))
    }

    // The drag image is a rendered snapshot of the pill (smoke test: non-nil, sized). The
    // gesture itself needs real HID, so only the image generation is exercised here.
    func testTabPillDragSnapshotIsRendered() {
        let pill = TabPillView(tabId: "tab-1", title: "Tab One")
        pill.frame = NSRect(x: 0, y: 0, width: Theme.tabWidth, height: Theme.tabBarHeight)
        pill.layoutSubtreeIfNeeded()
        let image = pill.snapshotImage()
        XCTAssertGreaterThan(image.size.width, 0, "drag snapshot must have a non-empty size")
        XCTAssertGreaterThan(image.size.height, 0, "drag snapshot must have a non-empty size")
        XCTAssertFalse(image.representations.isEmpty, "drag snapshot must carry a bitmap rep")
    }

    func testReorderTabsIssuesUpdateWorkspaceTabIdsCommand() async throws {
        let (t, s) = makeWorld(tabCount: 2)
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        coordinator.reorderTabs(tabIds: ["tab-2", "tab-1"])
        let issued = await waitUntil(timeout: 2) {
            t.recordedVoid().contains { $0.command == "updateworkspacetabids" }
        }
        XCTAssertTrue(issued, "reorder must issue the updateworkspacetabids wsh command")
        let call = try XCTUnwrap(t.recordedVoid().first { $0.command == "updateworkspacetabids" })
        // MultiArg encodes positionally as { args: [workspaceId, [tabIds...]] }.
        XCTAssertEqual(call.data,
                       .object(["args": .array([.string("ws-1"),
                                                .array([.string("tab-2"), .string("tab-1")])])]),
                       "updateworkspacetabids must carry [workspaceId, tabIds]")
    }

    func testReceiveTabDropIssuesMoveTabFromExplicitSource() async throws {
        let (t, s) = makeWorld(tabCount: 1)
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        // A tab from ws-2 (another window) is dropped onto this window (ws-1).
        coordinator.receiveTabDrop(tabId: "tab-x", fromWorkspaceId: "ws-2")
        let issued = await waitUntil(timeout: 2) {
            t.recordedVoid().contains { $0.command == "movetab" }
        }
        XCTAssertTrue(issued, "a cross-workspace drop must issue the movetab wsh command")
        // Source is the pasteboard origin (ws-2), destination is this window's workspace (ws-1).
        let call = try XCTUnwrap(t.recordedVoid().first { $0.command == "movetab" })
        XCTAssertEqual(call.data,
                       .object(["sourceworkspaceid": .string("ws-2"),
                                "destworkspaceid": .string("ws-1"),
                                "tabid": .string("tab-x")]),
                       "movetab must move from the drag source into this window's workspace")
    }

    // MARK: - Click-to-focus persists into the layout model (Cmd-W/split/magnify target)

    func testFocusNodeDispatchUpdatesCurrentFocusedBlockId() async throws {
        // A tab with TWO tiled panes, focus initially on A. A click dispatches
        // .focusNode(B); the window-level Cmd-W / split / magnify all read
        // currentFocusedBlockId (the model's focusednodeid), so it must follow the click.
        let t = FakeTransport()
        let s = FakeStore()
        let leafA = LayoutTree.newLeaf(blockId: "blk-A")
        let leafB = LayoutTree.newLeaf(blockId: "blk-B")
        var layout = LayoutState(oid: "lay-1", version: 1)
        try layout.setRootLayoutNode(LayoutTree.newNode(children: [leafA, leafB]))
        layout.focusednodeid = leafA.id

        s.preload(.window(Window(oid: "win-1", version: 1, workspaceid: "ws-1",
                                 pos: Point(x: 0, y: 0), winsize: WinSize(width: 1, height: 1),
                                 lastfocusts: 0, meta: [:])))
        s.preload(.workspace(Workspace(oid: "ws-1", version: 1, name: "Default",
                                       tabids: ["tab-1"], activetabid: "tab-1", meta: [:])))
        s.preload(.tab(Tab(oid: "tab-1", version: 1, name: "One",
                           layoutstate: "layout:lay-1", blockids: ["blk-A", "blk-B"], meta: [:])))
        s.preload(.layout(layout))
        s.preload(.block(Block(oid: "blk-A", version: 1, meta: ["view": .string("term")])))
        s.preload(.block(Block(oid: "blk-B", version: 1, meta: ["view": .string("term")])))

        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        // The layout model loads asynchronously; wait until focus resolves to A.
        let loaded = await waitUntil(timeout: 2) { coordinator.currentFocusedBlockId() == "blk-A" }
        XCTAssertTrue(loaded, "initial focus must resolve to the focused leaf (A)")

        coordinator.dispatchLayout(.focusNode(nodeId: leafB.id))
        XCTAssertEqual(coordinator.currentFocusedBlockId(), "blk-B",
                       "a focusNode dispatch must move the model's focused block to the clicked pane")
    }

    // MARK: - Quit and Close All Shells: terminate every durable job-manager

    func testTerminateAllShellsIssuesListThenExitPerJob() async throws {
        let t = FakeTransport()
        let s = FakeStore()
        t.jobListResponse = try JSONValue.encode([JobInfo(oid: "job-1"), JobInfo(oid: "job-2")])
        let service = ServiceClient(transport: t, store: s)

        let count = try await service.terminateAllShells()
        XCTAssertEqual(count, 2, "must report the number of shells terminated")

        XCTAssertTrue(t.recordedGeneric().contains { $0.command == "jobcontrollerlist" },
                      "must enumerate job-managers via jobcontrollerlist")
        let exits = t.recordedVoid().filter { $0.command == "jobcontrollerexitjob" }
        XCTAssertEqual(exits.count, 2, "must terminate every listed job-manager")
        // jobId is sent positionally as a bare string payload.
        XCTAssertEqual(exits.map { $0.data }, [.string("job-1"), .string("job-2")],
                       "each jobcontrollerexitjob must carry its jobId")
    }

    func testTerminateAllShellsWithNoJobsIssuesNoExit() async throws {
        let t = FakeTransport()
        let s = FakeStore()
        // Default jobListResponse is an empty array.
        let service = ServiceClient(transport: t, store: s)
        let count = try await service.terminateAllShells()
        XCTAssertEqual(count, 0)
        XCTAssertFalse(t.recordedVoid().contains { $0.command == "jobcontrollerexitjob" },
                       "no shells → no exit commands")
    }

    // MARK: - Dead/orphaned block: a single bad block must not brick the bootstrap

    func testInitialSetActiveTabFailureDoesNotBrickBootstrap() async throws {
        // A dead/orphaned block makes the backend SetActiveTab fail. The INITIAL
        // activation must treat that as recoverable (log + continue), still reaching
        // ready, instead of failing the whole bootstrap.
        let (_, s) = makeWorld(tabCount: 1)
        let t = FailingSetActiveTabTransport()
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)
        XCTAssertNil(delegate.failure, "a failing initial SetActiveTab must not surface as a bootstrap failure")
    }

    // MARK: - Layout pruning: a leaf whose block can't be resolved is dropped

    func testPrunedLayoutRootDropsUnresolvableLeafAndCollapses() {
        let root = LayoutNode(id: "r", children: [
            LayoutNode(id: "a", data: TabLayoutData(blockId: "A"), size: 10),
            LayoutNode(id: "b", data: TabLayoutData(blockId: "B-dead"), size: 10),
        ], flexDirection: .row)
        let valid: Set<String> = ["A"]
        let pruned = AppCoordinator.prunedLayoutRoot(root) { valid.contains($0) }
        // B-dead removed → single child A collapses up to the root slot.
        XCTAssertEqual(pruned?.data?.blockId, "A")
        XCTAssertNil(pruned?.children)
    }

    func testPrunedLayoutRootKeepsAllResolvableLeaves() {
        let root = LayoutNode(id: "r", children: [
            LayoutNode(id: "a", data: TabLayoutData(blockId: "A"), size: 10),
            LayoutNode(id: "b", data: TabLayoutData(blockId: "B"), size: 10),
        ], flexDirection: .row)
        let valid: Set<String> = ["A", "B"]
        let pruned = AppCoordinator.prunedLayoutRoot(root) { valid.contains($0) }
        XCTAssertEqual(pruned?.children?.count, 2, "no unresolvable leaves → tree unchanged")
    }

    func testPrunedLayoutRootAllUnresolvableReturnsNil() {
        let root = LayoutNode(id: "r", children: [
            LayoutNode(id: "a", data: TabLayoutData(blockId: "A-dead"), size: 10),
        ], flexDirection: .row)
        let pruned = AppCoordinator.prunedLayoutRoot(root) { _ in false }
        XCTAssertNil(pruned, "a fully-dead subtree resolves away to nil")
    }

    // MARK: - Tab background CSS parsing (pure)

    private func assertColor(
        _ c: RGBAColor?, _ r: Double, _ g: Double, _ b: Double, _ a: Double = 1,
        accuracy: Double = 0.01, line: UInt = #line
    ) {
        guard let c else { return XCTFail("expected a color", line: line) }
        XCTAssertEqual(c.r, r, accuracy: accuracy, line: line)
        XCTAssertEqual(c.g, g, accuracy: accuracy, line: line)
        XCTAssertEqual(c.b, b, accuracy: accuracy, line: line)
        XCTAssertEqual(c.a, a, accuracy: accuracy, line: line)
    }

    func testParseHexColors() {
        assertColor(BackgroundCSS.parseColor("#ff0000"), 1, 0, 0)
        assertColor(BackgroundCSS.parseColor("#00ff00"), 0, 1, 0)
        assertColor(BackgroundCSS.parseColor("#0000ff80"), 0, 0, 1, 0.502)
        assertColor(BackgroundCSS.parseColor("#f00"), 1, 0, 0)
        assertColor(BackgroundCSS.parseColor("#0f08"), 0, 1, 0, 0.533)
    }

    func testParseRGBAndHSLAndNamed() {
        assertColor(BackgroundCSS.parseColor("rgb(255, 0, 0)"), 1, 0, 0)
        assertColor(BackgroundCSS.parseColor("rgba(0, 0, 255, 0.5)"), 0, 0, 1, 0.5)
        assertColor(BackgroundCSS.parseColor("green"), 0, 128.0 / 255, 0)
        assertColor(BackgroundCSS.parseColor("transparent"), 0, 0, 0, 0)
        // hsl(0,100%,50%) is pure red.
        assertColor(BackgroundCSS.parseColor("hsl(0, 100%, 50%)"), 1, 0, 0)
        // hsl(120,100%,50%) is pure green.
        assertColor(BackgroundCSS.parseColor("hsl(120, 100%, 50%)"), 0, 1, 0)
        XCTAssertNil(BackgroundCSS.parseColor("not-a-color"))
    }

    func testClassifyColorVsGradientVsURL() {
        XCTAssertEqual(BackgroundCSS.classify("blue"), .color(RGBAColor(r: 0, g: 0, b: 1, a: 1)))
        if case .linearGradient = BackgroundCSS.classify("linear-gradient(90deg, red, blue)") {} else {
            XCTFail("expected linearGradient")
        }
        if case .radialGradient = BackgroundCSS.classify("radial-gradient(circle, red, blue)") {} else {
            XCTFail("expected radialGradient")
        }
        XCTAssertEqual(BackgroundCSS.classify("url('/tmp/x.png')"), .image(url: "/tmp/x.png"))
        XCTAssertEqual(BackgroundCSS.classify("url(file:///a/b.jpg)"), .image(url: "file:///a/b.jpg"))
    }

    func testParseLinearGradientAngleAndStops() {
        let g = BackgroundCSS.parseLinearGradient(
            "linear-gradient(226.4deg, rgba(255,26,1,1) 28.9%, rgba(0,141,254,1) 80.6%)")
        XCTAssertNotNil(g)
        XCTAssertEqual(g?.angleDegrees ?? -1, 226.4, accuracy: 0.01)
        XCTAssertEqual(g?.stops.count, 2)
        XCTAssertEqual(g?.stops.first?.location ?? -1, 0.289, accuracy: 0.001)
        assertColor(g?.stops.first?.color, 1, 26.0 / 255, 1.0 / 255)
    }

    func testLinearGradientDirectionKeywordsAndDefault() {
        // "to right" == 90deg; missing angle defaults to 180 (to bottom).
        XCTAssertEqual(BackgroundCSS.parseAngle("to right"), 90)
        XCTAssertEqual(BackgroundCSS.parseAngle("to top"), 0)
        XCTAssertEqual(BackgroundCSS.parseAngle("to bottom left"), 225)
        XCTAssertNil(BackgroundCSS.parseAngle("red"))
        let g = BackgroundCSS.parseLinearGradient("linear-gradient(purple, blue, teal)")
        XCTAssertEqual(g?.angleDegrees, 180)
        XCTAssertEqual(g?.stops.count, 3)
    }

    func testSplitTopLevelKeepsLayersIntact() {
        // A multi-layer background: commas inside the gradients must NOT split.
        let layers = BackgroundCSS.parseLayers(
            "linear-gradient(135deg, purple, blue), radial-gradient(circle at 70% 70%, white, transparent)")
        XCTAssertEqual(layers.count, 2)
        if case .linearGradient = layers[0] {} else { XCTFail("layer 0 should be linear") }
        if case .radialGradient = layers[1] {} else { XCTFail("layer 1 should be radial") }
    }

    func testResolveTabBackgroundPresetWinsOverInline() {
        let backgrounds: [String: JSONValue] = [
            "bg@blue": .object(["bg": .string("blue"), "bg:opacity": .double(0.3)]),
        ]
        let meta: MetaMapType = [
            "tab:background": .string("bg@blue"),
            "bg": .string("red"),
        ]
        let cfg = AppCoordinator.resolveTabBackground(meta: meta, backgrounds: backgrounds)
        XCTAssertEqual(cfg?.bg, "blue", "named preset wins over inline bg")
        XCTAssertEqual(cfg?.opacity, 0.3)
    }

    func testResolveTabBackgroundInlineAndEmpty() {
        let inline: MetaMapType = ["bg": .string("green"), "bg:blendmode": .string("overlay")]
        let cfg = AppCoordinator.resolveTabBackground(meta: inline, backgrounds: nil)
        XCTAssertEqual(cfg?.bg, "green")
        XCTAssertEqual(cfg?.blendMode, "overlay")
        XCTAssertNil(cfg?.opacity)
        XCTAssertNil(AppCoordinator.resolveTabBackground(meta: [:], backgrounds: nil))
        XCTAssertNil(AppCoordinator.resolveTabBackground(meta: ["bg": .string("  ")], backgrounds: nil))
    }

    // MARK: - Tab "Background" submenu patches + preset parsing

    func testTabBackgroundPresetPatchSetsKeyAndClearsInline() {
        let patch = TabBackgroundMenu.presetPatch("bg@blue")
        XCTAssertEqual(patch["tab:background"], .string("bg@blue"))
        // Inline bg keys are cleared so the named preset is the unambiguous source.
        XCTAssertEqual(patch["bg"], .null)
        XCTAssertEqual(patch["bg:opacity"], .null)
        XCTAssertEqual(patch["bg:blendmode"], .null)
    }

    func testTabBackgroundColorPatchSetsBgAndDefaultsOpacity() {
        let patch = TabBackgroundMenu.colorPatch(hex: "#429DFF")
        XCTAssertEqual(patch["bg"], .string("#429DFF"))
        XCTAssertEqual(patch["bg:opacity"], .double(0.5), "defaults to the renderer's 0.5")
        XCTAssertEqual(patch["tab:background"], .null, "a solid color clears any named preset")
    }

    func testTabBackgroundClearPatchNullsEveryKey() {
        let patch = TabBackgroundMenu.clearPatch()
        for key in ["tab:background", "bg", "bg:opacity", "bg:blendmode"] {
            XCTAssertEqual(patch[key], .null, "\(key) must be deleted")
        }
    }

    func testParseBackgroundPresetsOrdersByDisplayOrder() {
        let config: JSONValue = .object([
            "backgrounds": .object([
                "bg@red": .object(["display:name": .string("Red"), "display:order": .double(1.3)]),
                "bg@blue": .object(["display:name": .string("Blue"), "display:order": .double(1.1)]),
                "bg@nokey": .object(["display:order": .double(1.2)]),
            ]),
        ])
        let presets = AppCoordinator.parseBackgroundPresets(config)
        XCTAssertEqual(presets.map { $0.key }, ["bg@blue", "bg@nokey", "bg@red"])
        XCTAssertEqual(presets[0].displayName, "Blue")
        XCTAssertEqual(presets[1].displayName, "bg@nokey", "missing display:name falls back to the key")
        XCTAssertTrue(AppCoordinator.parseBackgroundPresets(nil).isEmpty)
    }

    func testGradientLocationAutoSpacing() {
        let stops = [
            GradientStop(color: RGBAColor(r: 1, g: 0, b: 0), location: nil),
            GradientStop(color: RGBAColor(r: 0, g: 1, b: 0), location: nil),
            GradientStop(color: RGBAColor(r: 0, g: 0, b: 1), location: nil),
        ]
        let locs = TabBackgroundView.resolveLocations(stops)
        XCTAssertEqual(locs, [0, 0.5, 1])
    }

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return condition()
    }
}

/// A transport whose backend `SetActiveTab` always fails (models a dead/orphaned
/// block the controller-start trigger cannot resolve), so the bootstrap-resilience
/// path can be exercised.
final class FailingSetActiveTabTransport: FakeTransport, @unchecked Sendable {
    override func callService(_ call: WebCallType) async throws -> WebReturnType {
        if call.method == "SetActiveTab" {
            throw WaveError.rpc("error finding tab for block: bad block parent oref")
        }
        return try await super.callService(call)
    }
}

/// Captures the workspace list pushed to the delegate (bug 5).
@MainActor
final class WorkspaceListDelegate: AppCoordinatorDelegate {
    let ready = XCTestExpectation(description: "ready")
    private(set) var lastList: [WorkspaceMenuItem] = []
    /// Injectable stand-in for the WindowManager's live-open set (what drives `isOpen`).
    var openWorkspaceIds: Set<String> = []

    func coordinatorDidUpdateWorkspace(name: String?, icon: String?, color: String?, workspaceId: String?) {}
    func coordinatorDidUpdateWorkspaceList(_ items: [WorkspaceMenuItem]) { lastList = items }
    func coordinatorOpenWorkspaceIds() -> Set<String> { openWorkspaceIds }
    func coordinatorDidUpdateTabs(_ tabs: [TabBarItem], activeTabId: String?) {}
    func coordinatorDidUpdateLayout(env: BlockEnvFactory, root: LayoutNode?, focusedNodeId: String?, magnifiedNodeId: String?) {}
    func coordinatorRequestFocusBlock(_ blockId: String) {}
    func coordinatorDidBecomeReady() { ready.fulfill() }
    func coordinatorRequestCloseWindow() {}
    func coordinatorDidFail(_ error: Error) {}
}
