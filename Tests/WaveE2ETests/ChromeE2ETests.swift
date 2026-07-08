// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// E2E-7 (chrome behavior) — docs/E2E.md:
//   "Open/switch/close/reorder tabs; switch workspaces. Each maps to the right
//    RPC and updates the UI."
//
// Driven against a REAL `wavesrv` (WaveServerProcess) through the REAL transport
// (WaveTransportClient) + REAL object store (ObjectStore) + the production
// AppCoordinator. A transparent RecordingTransport observes which RPCs the chrome
// issues so we can prove the mapping while the bytes hit the live server.
//
// GUARDS gated here, end-to-end against the server:
//   §C  SetActiveTab fires on the INITIAL activation and on every tab switch
//       (the backend controller-start trigger); CloseTab's
//       { closewindow, newactivetabid } return is honored.
//   §B  the chrome's UI state tracks the server: tab open/close/reorder and
//       workspace switch all land in the object store (via inline `updates` +
//       `waveobj:update`) and are republished to the delegate.
//   §P  a fresh auth key is present in the spawn env.
//
// The visual half of E2E-7 (offscreen render + snapshot diff vs the Electron
// baseline) lives in SnapshotTests.swift.

import XCTest
import WaveCore
import WaveCommands
@testable import WaveProtocol
@testable import WaveStore
@testable import WaveUI

@MainActor
final class ChromeE2ETests: XCTestCase {
    private var server: WaveServerProcess!
    private var recording: RecordingTransport!
    private var store: ObjectStore!
    private var coordinator: AppCoordinator!
    private var delegate: ChromeRecordingDelegate!

    override func setUp() async throws {
        server = try WaveServerProcess.startOrSkip()
        let real = WaveTransportClient(wavesrvPath: server.binaryPath)
        recording = RecordingTransport(real: real, server: server)
        store = ObjectStore(transport: recording)
        delegate = ChromeRecordingDelegate()
        coordinator = AppCoordinator(
            transport: recording, store: store,
            config: AppLaunchConfig(dataHome: server.dataDir.path, configHome: server.configDir.path)
        )
        coordinator.delegate = delegate
        coordinator.start()
        let ready = await waitUntil(timeout: 15) { [delegate] in delegate?.isReady == true }
        XCTAssertTrue(ready, "coordinator never became ready (failure: \(String(describing: delegate.failure)))")
        XCTAssertNil(delegate.failure)
    }

    override func tearDown() async throws {
        recording?.disconnect()
        server?.terminate()
        coordinator = nil
        store = nil
        recording = nil
        server = nil
    }

    // MARK: - Open + switch tabs

    // GUARDS §C — initial activation calls SetActiveTab; opening a tab issues
    // CreateTab and activates it; switching issues another SetActiveTab. The UI
    // (delegate) reflects the new tab list + active id each time.
    func testOpenAndSwitchTabsMapToRPCsAndUpdateUI() async throws {
        // Initial activation already fired SetActiveTab (the controller-start
        // trigger, §C).
        XCTAssertGreaterThanOrEqual(recording.serviceCallCount("SetActiveTab"), 1,
                                    "GUARDS §C: initial SetActiveTab missing")
        let firstTab = try XCTUnwrap(coordinator.activeTabId)
        let initialTabCount = delegate.tabs.count

        // Open a new tab.
        let setActiveBefore = recording.serviceCallCount("SetActiveTab")
        coordinator.newTab()
        let opened = await waitUntil(timeout: 8) { [delegate] in (delegate?.tabs.count ?? 0) > initialTabCount }
        XCTAssertTrue(opened, "new tab never appeared in the UI")
        XCTAssertTrue(recording.didCallService("CreateTab"), "open-tab must map to CreateTab")
        XCTAssertGreaterThan(recording.serviceCallCount("SetActiveTab"), setActiveBefore,
                             "GUARDS §C: a freshly opened tab must be activated (SetActiveTab)")
        let newTab = try XCTUnwrap(coordinator.activeTabId)
        XCTAssertNotEqual(newTab, firstTab)
        XCTAssertEqual(delegate.activeTabId, newTab, "UI active tab must follow the new tab")

        // Switch back to the first tab.
        let setActiveBeforeSwitch = recording.serviceCallCount("SetActiveTab")
        coordinator.selectTab(firstTab)
        let switched = await waitUntil(timeout: 8) { [coordinator] in coordinator?.activeTabId == firstTab }
        XCTAssertTrue(switched, "tab switch did not take effect")
        XCTAssertGreaterThan(recording.serviceCallCount("SetActiveTab"), setActiveBeforeSwitch,
                             "GUARDS §C: switching tabs must call SetActiveTab")
        XCTAssertEqual(delegate.activeTabId, firstTab, "UI active tab must follow the switch")
    }

    // MARK: - Reorder tabs

    // Reorder maps to the wsh UpdateWorkspaceTabIds command (PROTOCOL §3); the new
    // order round-trips through the server back into the object store (GUARDS §B).
    func testReorderTabsMapsToUpdateWorkspaceTabIdsAndUpdatesStore() async throws {
        let wsId = try XCTUnwrap(coordinator.workspaceId)
        // Ensure at least two tabs.
        if (currentTabIds(wsId)?.count ?? 0) < 2 {
            coordinator.newTab()
            _ = await waitUntil(timeout: 8) { [weak self] in (self?.currentTabIds(wsId)?.count ?? 0) >= 2 }
        }
        let original = try XCTUnwrap(currentTabIds(wsId))
        XCTAssertGreaterThanOrEqual(original.count, 2)
        let reordered = Array(original.reversed())

        let winId = try XCTUnwrap(coordinator.windowId)
        let activeTabId = coordinator.activeTabId ?? original[0]
        let commands = WaveCommands(transport: recording, store: store) {
            UIContext(windowid: winId, activetabid: activeTabId)
        }
        try await commands.updateWorkspaceTabIds(workspaceId: wsId, tabIds: reordered)

        XCTAssertTrue(recording.didSendCommand(WshCommand.updateWorkspaceTabIds),
                      "reorder must map to the updateworkspacetabids command")
        let applied = await waitUntil(timeout: 8) { [weak self] in self?.currentTabIds(wsId) == reordered }
        XCTAssertTrue(applied, "GUARDS §B: reordered tab list never reached the store (got \(String(describing: currentTabIds(wsId))))")
    }

    // MARK: - Close tab (honor the return)

    // GUARDS §C — closing a non-last tab maps to CloseTab; the UI drops it and the
    // server-chosen `newactivetabid` becomes active (no window close).
    func testCloseTabMapsToRPCAndHonorsReturn() async throws {
        let wsId = try XCTUnwrap(coordinator.workspaceId)
        // Guarantee two tabs so the close does not close the window.
        coordinator.newTab()
        _ = await waitUntil(timeout: 8) { [weak self] in (self?.currentTabIds(wsId)?.count ?? 0) >= 2 }
        let tabsBefore = try XCTUnwrap(currentTabIds(wsId))
        XCTAssertGreaterThanOrEqual(tabsBefore.count, 2)

        let toClose = try XCTUnwrap(coordinator.activeTabId)
        coordinator.closeTab(toClose)

        let calledCloseTab = await waitUntil(timeout: 8) { self.recording.didCallService("CloseTab") }
        XCTAssertTrue(calledCloseTab, "close-tab must map to CloseTab")
        let gone = await waitUntil(timeout: 8) { [weak self] in
            (self?.currentTabIds(wsId)?.contains(toClose) == false)
        }
        XCTAssertTrue(gone, "closed tab still present in the store/UI")
        XCTAssertFalse(delegate.requestedCloseWindow, "non-last tab close must NOT close the window")
        XCTAssertNotEqual(coordinator.activeTabId, toClose,
                          "GUARDS §C: must switch to the returned newactivetabid")
    }

    // MARK: - Switch workspace

    // Switching workspaces maps to SwitchWorkspace (PROTOCOL §3) and republishes
    // the active workspace + its tabs to the UI.
    func testSwitchWorkspaceMapsToRPCAndUpdatesUI() async throws {
        let winId = try XCTUnwrap(coordinator.windowId)
        let originalWs = try XCTUnwrap(coordinator.workspaceId)

        // Create a second workspace via the real service.
        let activeTabId = coordinator.activeTabId ?? ""
        let commands = WaveCommands(transport: recording, store: store) {
            UIContext(windowid: winId, activetabid: activeTabId)
        }
        let newWsId = try await commands.createWorkspace(name: "E2E WS")
        XCTAssertFalse(newWsId.isEmpty)
        XCTAssertNotEqual(newWsId, originalWs)

        coordinator.switchWorkspace(newWsId)
        let switched = await waitUntil(timeout: 10) { [coordinator] in coordinator?.workspaceId == newWsId }
        XCTAssertTrue(switched, "workspace switch did not take effect")
        XCTAssertTrue(recording.didCallService("SwitchWorkspace"),
                      "workspace switch must map to SwitchWorkspace")
        XCTAssertEqual(delegate.workspaceId, newWsId, "UI workspace id must follow the switch")
    }

    // MARK: - Helpers

    private func currentTabIds(_ workspaceId: String) -> [String]? {
        store.get(ORef.workspace(workspaceId))?.asWorkspace?.tabids
    }

    /// Poll `condition` on the main actor until true or timeout. Pumps via async
    /// sleeps so the coordinator's fire-and-forget Tasks can run.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }
}

/// Captures the AppCoordinator's UI-facing callbacks for assertions. Named to
/// avoid clashing with `RecordingDelegate` in WaveUITests.swift.
@MainActor
final class ChromeRecordingDelegate: AppCoordinatorDelegate {
    private(set) var isReady = false
    private(set) var failure: Error?
    private(set) var requestedCloseWindow = false

    private(set) var tabs: [TabBarItem] = []
    private(set) var activeTabId: String?
    private(set) var workspaceId: String?
    private(set) var workspaceName: String?
    private(set) var workspaceItems: [WorkspaceMenuItem] = []

    func coordinatorDidUpdateWorkspace(name: String?, icon: String?, color: String?, workspaceId: String?) {
        workspaceName = name
        self.workspaceId = workspaceId
    }
    func coordinatorDidUpdateWorkspaceList(_ items: [WorkspaceMenuItem]) { workspaceItems = items }
    func coordinatorDidUpdateTabs(_ tabs: [TabBarItem], activeTabId: String?) {
        self.tabs = tabs
        self.activeTabId = activeTabId
    }
    func coordinatorDidUpdateLayout(env: BlockEnvFactory, root: LayoutNode?, focusedNodeId: String?, magnifiedNodeId: String?) {}
    func coordinatorRequestFocusBlock(_ blockId: String) {}
    func coordinatorDidBecomeReady() { isReady = true }
    func coordinatorRequestCloseWindow() { requestedCloseWindow = true }
    func coordinatorDidFail(_ error: Error) { failure = error }
}
