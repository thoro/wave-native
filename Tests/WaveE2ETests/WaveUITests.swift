// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI unit tests — encode the chrome-facing GUARDS:
//   §C  SetActiveTab is called on EVERY tab activation (incl. initial); CloseTab's
//       { closewindow, newactivetabid } return is honored.
//   §B  WebReturnType.updates are applied into the store after every service call.
//   §L  layout tiling math (flexDirection row|column, size weights, default 10,
//       3px gap).
//   §P  a fresh, std-base64 auth key per launch.
// These run without a live wavesrv (fake transport + store).

import XCTest
import AppKit
@testable import WaveCore
@testable import WaveUI

// MARK: - Fakes

final class FakeStore: ObjectStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [String: AnyWaveObj] = [:]
    private var handlers: [String: [(String, @Sendable (AnyWaveObj?) -> Void)]] = [:]
    private(set) var appliedUpdateBatches: [[WaveObjUpdate]] = []

    func preload(_ obj: AnyWaveObj) {
        lock.lock(); defer { lock.unlock() }
        objects[obj.oref.string] = obj
    }

    func get(_ oref: ORef) -> AnyWaveObj? {
        lock.lock(); defer { lock.unlock() }
        return objects[oref.string]
    }

    func load(_ oref: ORef) async throws -> AnyWaveObj {
        if let o = get(oref) { return o }
        throw WaveError.rpc("not found: \(oref.string)")
    }

    func loadMany(_ orefs: [ORef]) async throws -> [AnyWaveObj] {
        orefs.compactMap { get($0) }
    }

    @discardableResult
    func merge(_ obj: AnyWaveObj) -> Bool {
        lock.lock()
        if let cur = objects[obj.oref.string], cur.version >= obj.version {
            lock.unlock(); return false
        }
        objects[obj.oref.string] = obj
        let hs = handlers[obj.oref.string] ?? []
        lock.unlock()
        hs.forEach { $0.1(obj) }
        return true
    }

    func applyUpdates(_ updates: [WaveObjUpdate]) {
        lock.lock(); appliedUpdateBatches.append(updates); lock.unlock()
        for u in updates {
            if u.isDelete {
                lock.lock(); objects.removeValue(forKey: u.oref.string)
                let hs = handlers[u.oref.string] ?? []; lock.unlock()
                hs.forEach { $0.1(nil) }
            } else if let obj = try? u.decodedObj() {
                merge(obj)
            }
        }
    }

    func subscribe(_ oref: ORef, handler: @escaping @Sendable (AnyWaveObj?) -> Void) -> SubscriptionToken {
        let id = UUID().uuidString
        lock.lock()
        handlers[oref.string, default: []].append((id, handler))
        lock.unlock()
        return SubscriptionToken(id: id) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.handlers[oref.string]?.removeAll { $0.0 == id }
            self.lock.unlock()
        }
    }
}

class FakeTransport: WaveTransport, @unchecked Sendable {
    private let lock = NSLock()
    var addrs: ServerAddrs? = ServerAddrs(wsAddr: "127.0.0.1:1", webAddr: "127.0.0.1:2")
    var routeId: String?
    var isConnected: Bool = false
    var onReconnect: (@Sendable () -> Void)?

    private(set) var serviceCalls: [(service: String, method: String)] = []
    private(set) var serviceArgCalls: [(method: String, args: [JSONValue])] = []
    private(set) var voidCalls: [(command: String, data: JSONValue?)] = []
    private(set) var genericCalls: [(command: String, data: JSONValue?)] = []
    private var eventHandlers: [(SubscriptionRequest, @Sendable (WaveEvent) -> Void)] = []

    /// Canned client returned by GetClientData.
    var clientData = Client(oid: "client-1", version: 1, windowids: ["win-1"], meta: [:])

    /// Canned `ListWorkspaces` payload (a `[WorkspaceListEntry]` JSON array).
    var workspaceListResponse: JSONValue = .array([])

    /// Canned `getfullconfig` payload (the full config blob; settings live under
    /// "settings"). Tunable so config-reload tests can change it between fetches.
    var fullConfigResponse: JSONValue = .object([:])

    /// Canned `jobcontrollerlist` payload (a `[JobInfo]` JSON array) for the
    /// "Quit and Close All Shells" teardown.
    var jobListResponse: JSONValue = .array([])

    func recorded() -> [(service: String, method: String)] {
        lock.lock(); defer { lock.unlock() }
        return serviceCalls
    }

    func recordedVoid() -> [(command: String, data: JSONValue?)] {
        lock.lock(); defer { lock.unlock() }
        return voidCalls
    }

    func recordedServiceArgs() -> [(method: String, args: [JSONValue])] {
        lock.lock(); defer { lock.unlock() }
        return serviceArgCalls
    }

    /// Typed-RPC (`transport.call`) commands issued, e.g. the `createblock` wsh command.
    func recordedGeneric() -> [(command: String, data: JSONValue?)] {
        lock.lock(); defer { lock.unlock() }
        return genericCalls
    }

    func spawn(env: [String: String]) async throws -> ServerAddrs {
        XCTAssertNotNil(env[WaveProtocolConst.authKeyEnv], "GUARDS §P: auth key must be in spawn env")
        return addrs!
    }

    func connect(routeId: String) async throws {
        self.routeId = routeId
        isConnected = true
    }

    func reconnect() async throws { isConnected = true }
    func disconnect() { isConnected = false }

    func call<Req: Encodable & Sendable, Res: Decodable & Sendable>(
        command: String, data: Req?, route: String?, timeoutMs: Int64?
    ) async throws -> Res {
        let encoded = data.flatMap { try? JSONValue.encode($0) }
        lock.lock(); genericCalls.append((command, encoded)); lock.unlock()
        // CreateBlockCommand returns the new block's ORef (encoded as a single string).
        if command == "createblock" {
            return try JSONValue.string("block:blk-new").decode(Res.self)
        }
        if command == "getfullconfig" {
            lock.lock(); let cfg = fullConfigResponse; lock.unlock()
            return try cfg.decode(Res.self)
        }
        if command == "jobcontrollerlist" {
            lock.lock(); let jobs = jobListResponse; lock.unlock()
            return try jobs.decode(Res.self)
        }
        // setconfig and friends — return an empty object (no payload).
        return try JSONValue.object([:]).decode(Res.self)
    }

    func callVoid<Req: Encodable & Sendable>(command: String, data: Req?, route: String?, timeoutMs: Int64?) async throws {
        let encoded = data.flatMap { try? JSONValue.encode($0) }
        lock.lock(); voidCalls.append((command, encoded)); lock.unlock()
    }
    func notify<Req: Encodable & Sendable>(command: String, data: Req?, route: String?) throws {}

    func stream<Req: Encodable & Sendable>(
        command: String, data: Req?, route: String?,
        onChunk: @escaping @Sendable (Result<RpcMessage, WaveError>) -> Void
    ) throws -> SubscriptionToken {
        SubscriptionToken {}
    }

    func callService(_ call: WebCallType) async throws -> WebReturnType {
        lock.lock()
        serviceCalls.append((call.service, call.method))
        serviceArgCalls.append((call.method, call.args))
        lock.unlock()
        switch call.method {
        case "GetClientData":
            return WebReturnType(success: true, data: try JSONValue.encode(clientData))
        case "ListWorkspaces":
            return WebReturnType(success: true, data: workspaceListResponse)
        case "GetColors":
            return WebReturnType(success: true, data: .array([.string("#58C142"), .string("#429DFF")]))
        case "GetIcons":
            return WebReturnType(success: true, data: .array([.string("star"), .string("heart")]))
        case "SetActiveTab":
            return WebReturnType(success: true)
        case "CreateTab":
            return WebReturnType(success: true, data: .string("tab-new"))
        case "CreateWindow":
            return WebReturnType(success: true, data: createWindowResponse)
        case "CloseTab":
            return WebReturnType(success: true, data: closeTabResponse)
        default:
            return WebReturnType(success: true)
        }
    }

    /// Tunable canned CloseTab response.
    var closeTabResponse: JSONValue = .object(["closewindow": .bool(true)])

    /// Tunable canned CreateWindow response (a Window JSON, or .null).
    var createWindowResponse: JSONValue = .null

    func fetchFile(zoneId: String, name: String, offset: Int64) async throws -> (data: Data, info: WaveFile) {
        throw WaveError.notConnected
    }

    func subscribe(_ request: SubscriptionRequest, handler: @escaping @Sendable (WaveEvent) -> Void) -> SubscriptionToken {
        lock.lock(); eventHandlers.append((request, handler)); lock.unlock()
        return SubscriptionToken {}
    }

    /// Push an event to all subscribers (test helper).
    func emit(_ event: WaveEvent) {
        lock.lock(); let hs = eventHandlers.map { $0.1 }; lock.unlock()
        hs.forEach { $0(event) }
    }
}

@MainActor
final class RecordingDelegate: AppCoordinatorDelegate {
    var ready = XCTestExpectation(description: "ready")
    var closeRequested = XCTestExpectation(description: "closeWindow")
    var lastTabs: [TabBarItem] = []
    var lastActiveTabId: String?
    var lastTabBarPosition: String?
    var failure: Error?

    func coordinatorDidUpdateWorkspace(name: String?, icon: String?, color: String?, workspaceId: String?) {}
    func coordinatorDidUpdateWorkspaceList(_ items: [WorkspaceMenuItem]) {}
    func coordinatorDidUpdateTabs(_ tabs: [TabBarItem], activeTabId: String?) {
        lastTabs = tabs; lastActiveTabId = activeTabId
    }
    func coordinatorDidUpdateTabBarPosition(_ position: String) { lastTabBarPosition = position }
    func coordinatorDidUpdateLayout(env: BlockEnvFactory, root: LayoutNode?, focusedNodeId: String?, magnifiedNodeId: String?) {}
    func coordinatorRequestFocusBlock(_ blockId: String) {}
    func coordinatorDidBecomeReady() { ready.fulfill() }
    func coordinatorRequestCloseWindow() { closeRequested.fulfill() }
    func coordinatorDidFail(_ error: Error) { failure = error }
}

// MARK: - Helpers

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
    s.preload(.block(Block(oid: "blk-2", version: 1, meta: ["view": .string("web")])))
    return (t, s)
}

// MARK: - Tests

@MainActor
final class WaveUITests: XCTestCase {

    func testPointerTransparentOverlayCannotShieldPaneContent() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let pane = NSView(frame: container.bounds)
        let decoration = PointerTransparentView(frame: container.bounds)
        container.addSubview(pane)
        container.addSubview(decoration, positioned: .above, relativeTo: pane)

        XCTAssertNil(decoration.hitTest(NSPoint(x: 50, y: 50)))
        XCTAssertTrue(
            container.hitTest(NSPoint(x: 50, y: 50)) === pane,
            "a stale drop/focus overlay must never consume pane mouse gestures")
    }

    // GUARDS §C — SetActiveTab is the controller-start trigger; it must fire on the
    // initial activation and on every user tab switch.
    func testSetActiveTabCalledOnInitAndSwitch() async throws {
        let (t, s) = makeWorld()
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        XCTAssertNil(delegate.failure)
        // Initial activation issued SetActiveTab for tab-1.
        XCTAssertTrue(t.recorded().contains { $0.method == "SetActiveTab" }, "initial SetActiveTab missing")

        let beforeCount = t.recorded().filter { $0.method == "SetActiveTab" }.count
        coordinator.selectTab("tab-2")
        // Let the async activation run.
        try await Task.sleep(nanoseconds: 200_000_000)
        let afterCount = t.recorded().filter { $0.method == "SetActiveTab" }.count
        XCTAssertGreaterThan(afterCount, beforeCount, "GUARDS §C: switching tabs must call SetActiveTab")
    }

    // GUARDS §C — CloseTab return: closewindow=true closes the window.
    func testCloseTabClosesWindow() async throws {
        let (t, s) = makeWorld()
        t.closeTabResponse = .object(["closewindow": .bool(true)])
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        coordinator.closeTab("tab-1")
        await fulfillment(of: [delegate.closeRequested], timeout: 2)
    }

    // GUARDS §C — CloseTab return: newactivetabid switches to that tab.
    func testCloseTabSwitchesToNewActive() async throws {
        let (t, s) = makeWorld()
        t.closeTabResponse = .object(["newactivetabid": .string("tab-2")])
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        coordinator.closeTab("tab-1")
        try await Task.sleep(nanoseconds: 200_000_000)
        // Switching to tab-2 issues SetActiveTab for it.
        XCTAssertTrue(t.recorded().contains { $0.method == "SetActiveTab" })
        XCTAssertEqual(coordinator.activeTabId, "tab-2")
    }

    // GUARDS §B — service responses' inline updates are applied into the store.
    func testServiceUpdatesApplied() async throws {
        let s = FakeStore()
        let upd = WaveObjUpdate(updatetype: updateTypeUpdate, otype: OType.tab, oid: "tab-9",
                                obj: try JSONValue.encode(Tab(oid: "tab-9", version: 5, name: "X",
                                                              layoutstate: "", blockids: [], meta: [:])))
        let updTransport = UpdatingTransport(updates: [upd])
        let service = ServiceClient(transport: updTransport, store: s)
        try await service.setActiveTab(workspaceId: "ws-1", tabId: "tab-9")
        XCTAssertEqual(s.appliedUpdateBatches.count, 1, "GUARDS §B: updates must be applied")
        XCTAssertEqual(s.get(ORef.tab("tab-9"))?.version, 5)
    }

    // GUARDS §L — tiling: a row of two equal-weight leaves splits width with a gap.
    func testTilerRowSplit() {
        let root = LayoutNode(id: "r", children: [
            LayoutNode(id: "a", data: TabLayoutData(blockId: "A"), size: 10),
            LayoutNode(id: "b", data: TabLayoutData(blockId: "B"), size: 10),
        ], flexDirection: .row)
        let frames = LayoutTiler.computeFrames(root: root, in: CGRect(x: 0, y: 0, width: 203, height: 100), gap: 3)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].frame.width, 100)
        XCTAssertEqual(frames[1].frame.minX, 103)  // 100 + 3 gap
        XCTAssertEqual(frames[0].frame.height, 100)
    }

    // A resize (same panes, different sizes) keeps the structure signature identical, so
    // setLayout snaps instead of animating; a split / magnify changes it (animates).
    func testStructureSignatureIgnoresSizesButTracksStructure() {
        func tree(_ aSize: Double, _ bSize: Double) -> LayoutNode {
            LayoutNode(id: "r", children: [
                LayoutNode(id: "a", data: TabLayoutData(blockId: "A"), size: aSize),
                LayoutNode(id: "b", data: TabLayoutData(blockId: "B"), size: bSize),
            ], flexDirection: .row)
        }
        let sig = { LayoutTreeView.structureSignature(root: $0, magnifiedNodeId: $1) }
        // Resize: weights changed, arrangement identical -> same signature (snap).
        XCTAssertEqual(sig(tree(10, 10), nil), sig(tree(30, 5), nil))
        // Magnify toggled -> different (animate).
        XCTAssertNotEqual(sig(tree(10, 10), nil), sig(tree(10, 10), "a"))
        // A third pane added -> different (animate).
        let three = LayoutNode(id: "r", children: [
            LayoutNode(id: "a", data: TabLayoutData(blockId: "A"), size: 10),
            LayoutNode(id: "b", data: TabLayoutData(blockId: "B"), size: 10),
            LayoutNode(id: "c", data: TabLayoutData(blockId: "C"), size: 10),
        ], flexDirection: .row)
        XCTAssertNotEqual(sig(tree(10, 10), nil), sig(three, nil))
        // Re-parenting with identical leaf traversal order (drag C below B:
        // row[A,B,C] -> row[A,col[B,C]]) MUST read as structural — treating it as a
        // geometry pass leaked the old A|B splitter as a phantom divider.
        let flat = LayoutNode(id: "r", children: [
            LayoutNode(id: "a", data: TabLayoutData(blockId: "A"), size: 10),
            LayoutNode(id: "b", data: TabLayoutData(blockId: "B"), size: 10),
            LayoutNode(id: "c", data: TabLayoutData(blockId: "C"), size: 10),
        ], flexDirection: .row)
        let nested = LayoutNode(id: "r", children: [
            LayoutNode(id: "a", data: TabLayoutData(blockId: "A"), size: 10),
            LayoutNode(id: "w", children: [
                LayoutNode(id: "b", data: TabLayoutData(blockId: "B"), size: 10),
                LayoutNode(id: "c", data: TabLayoutData(blockId: "C"), size: 10),
            ], flexDirection: .column, size: 10),
        ], flexDirection: .row)
        XCTAssertNotEqual(sig(flat, nil), sig(nested, nil))
    }

    // Field bug (Wordpress/T1): dragging pane C below B re-parents row[A,B,C] into
    // row[A,col[B,C]] while keeping the leaf traversal order — the old A|B divider
    // leaked as a second vertical bar that still resized the left/right panes. After
    // the re-parent exactly one vertical + one horizontal splitter may remain.
    func testReparentSweepsStaleSplitter() {
        let env = BlockEnvFactory(
            transport: FakeTransport(), store: FakeStore(), tabId: "tab-1", windowId: "w-1")
        let view = LayoutTreeView(env: env, provider: DefaultBlockViewProvider())
        view.frame = CGRect(x: 0, y: 0, width: 900, height: 400)
        func leaf(_ id: String, _ block: String) -> LayoutNode {
            LayoutNode(id: id, data: TabLayoutData(blockId: block), size: 10)
        }
        let flat = LayoutNode(id: "r", children: [
            leaf("a", "A"), leaf("b", "B"), leaf("c", "C"),
        ], flexDirection: .row)
        view.setLayout(root: flat, focusedNodeId: nil, magnifiedNodeId: nil)
        func splitterCount() -> Int {
            view.subviews.filter { NSStringFromClass(type(of: $0)).contains("SplitterView") }.count
        }
        XCTAssertEqual(splitterCount(), 2)

        let nested = LayoutNode(id: "r", children: [
            leaf("a", "A"),
            LayoutNode(id: "w", children: [leaf("b", "B"), leaf("c", "C")],
                       flexDirection: .column, size: 10),
        ], flexDirection: .row)
        view.setLayout(root: nested, focusedNodeId: nil, magnifiedNodeId: nil)
        XCTAssertEqual(splitterCount(), 2, "the stale A|B splitter must be swept")
    }

    // Self-heal: a mounted BlockFrameView that is not tracked in blockViews is
    // unreachable by every layout path — it floats frozen above live panes and
    // swallows their clicks (field bug: per-tab selection/chrome dead zones).
    // Any rebuild pass, including a non-structural re-publish, must sweep it.
    func testRebuildSweepsUntrackedBlockFrameView() {
        let env = BlockEnvFactory(
            transport: FakeTransport(), store: FakeStore(), tabId: "tab-1", windowId: "w-1")
        let provider = DefaultBlockViewProvider()
        let view = LayoutTreeView(env: env, provider: provider)
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        let root = LayoutNode(id: "a", data: TabLayoutData(blockId: "A"), size: 10)
        view.setLayout(root: root, focusedNodeId: nil, magnifiedNodeId: nil)

        let orphan = BlockFrameView(
            nodeId: "ghost", env: env.makeEnv(blockRef: .block("GHOST")), provider: provider)
        orphan.frame = CGRect(x: 0, y: 0, width: 500, height: 300)
        view.addSubview(orphan)
        XCTAssertNotNil(orphan.superview)

        view.setLayout(root: root, focusedNodeId: nil, magnifiedNodeId: nil)
        XCTAssertNil(orphan.superview, "untracked BlockFrameView must be swept by rebuild")
        XCTAssertNotNil(
            view.subviews.first { $0 is BlockFrameView },
            "the tracked pane must survive the sweep")
    }

    // AppKit re-routes a mouseDown that bubbles up unhandled to a view visually
    // BEHIND the hit view. Panes only overlap while one is magnified (it floats by
    // zPosition), so a click on the magnified pane's chrome was re-delivered to the
    // dimmed sibling underneath, whose terminal stole focus from the zoomed pane.
    // The frame must swallow its unhandled clicks.
    func testPaneChromeClickDoesNotReachPaneBehind() throws {
        final class MouseProbeView: NSView {
            var downCount = 0
            override func mouseDown(with event: NSEvent) { downCount += 1 }
        }

        let env = BlockEnvFactory(
            transport: FakeTransport(), store: FakeStore(), tabId: "tab-1", windowId: "w-1")
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        window.contentView = container

        let behind = MouseProbeView(frame: container.bounds)
        container.addSubview(behind)
        let frameView = BlockFrameView(
            nodeId: "mag", env: env.makeEnv(blockRef: .block("MAG")),
            provider: DefaultBlockViewProvider())
        frameView.frame = CGRect(x: 20, y: 20, width: 560, height: 360)
        container.addSubview(frameView)

        var focusRequests: [String] = []
        frameView.onRequestFocus = { focusRequests.append($0) }

        // A body point (away from the header), like a click on the pane's padding.
        let center = NSPoint(x: frameView.bounds.midX, y: frameView.bounds.midY)
        let inWindow = frameView.convert(center, to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: inWindow, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        frameView.mouseDown(with: event)

        XCTAssertEqual(focusRequests, ["mag"], "the clicked pane itself must be focused")
        XCTAssertEqual(behind.downCount, 0,
                       "the bubbled mouseDown must not be re-routed to the pane behind")
    }

    // GUARDS §L — column split distributes height by weight.
    func testTilerColumnWeights() {
        let root = LayoutNode(id: "r", children: [
            LayoutNode(id: "a", data: TabLayoutData(blockId: "A"), size: 30),
            LayoutNode(id: "b", data: TabLayoutData(blockId: "B"), size: 10),
        ], flexDirection: .column)
        let frames = LayoutTiler.computeFrames(root: root, in: CGRect(x: 0, y: 0, width: 100, height: 203), gap: 3)
        // usable height 200, split 3:1 -> 150 / 50.
        XCTAssertEqual(frames[0].frame.height, 150)
        XCTAssertEqual(frames[1].frame.height, 50)
        XCTAssertEqual(frames[1].frame.minY, 153)
    }

    // GUARDS §L — a single leaf root fills the bounds.
    func testTilerSingleLeaf() {
        let root = LayoutNode(id: "r", data: TabLayoutData(blockId: "A"))
        let frames = LayoutTiler.computeFrames(root: root, in: CGRect(x: 0, y: 0, width: 50, height: 60))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].frame, CGRect(x: 0, y: 0, width: 50, height: 60))
        XCTAssertEqual(frames[0].blockId, "A")
    }

    // Split animation — a newly split-in pane keeps its full perpendicular size and scrolls
    // out only along the split axis (full height + grow width on a horizontal split; full
    // width + grow height on a vertical split), anchored at the slot's outer edge.
    func testGrowStartFrameSingleAxis() {
        let target = NSRect(x: 100, y: 40, width: 200, height: 100)
        // Horizontal split (row): FULL HEIGHT preserved, ZERO width, anchored at the outer edge.
        let h1 = LayoutTreeView.growStartFrame(for: target, horizontal: true, atStart: false)
        XCTAssertEqual(h1.height, target.height)   // full height — no vertical motion
        XCTAssertEqual(h1.minY, target.minY)
        XCTAssertEqual(h1.width, 0)                // zero width at start
        XCTAssertEqual(h1.minX, target.maxX)       // right child: sliver at the right edge
        let h0 = LayoutTreeView.growStartFrame(for: target, horizontal: true, atStart: true)
        XCTAssertEqual(h0.height, target.height)
        XCTAssertEqual(h0.width, 0)
        XCTAssertEqual(h0.minX, target.minX)       // first child: sliver at the left edge
        // Vertical split (column): FULL WIDTH preserved, ZERO height, anchored at the outer edge.
        let v1 = LayoutTreeView.growStartFrame(for: target, horizontal: false, atStart: false)
        XCTAssertEqual(v1.width, target.width)     // full width — no horizontal motion
        XCTAssertEqual(v1.minX, target.minX)
        XCTAssertEqual(v1.height, 0)               // zero height at start
        XCTAssertEqual(v1.minY, target.maxY)       // bottom child: sliver at the bottom edge
    }

    // Split animation as key-frames (t = 0 / 0.5 / 1). Horizontal split of a full pane A into
    // A (left) + B (right): A shrinks left keeping full height; the NEW pane B grows FROM THE
    // RIGHT — right edge pinned to the container, full height throughout, left edge scrolling in.
    func testSplitKeyframesHorizontalGrowsFromRight() {
        let before = LayoutNode(id: "na", data: TabLayoutData(blockId: "A"))
        let after = LayoutNode(id: "r", children: [
            LayoutNode(id: "na", data: TabLayoutData(blockId: "A"), size: 10),
            LayoutNode(id: "nb", data: TabLayoutData(blockId: "B"), size: 10),
        ], flexDirection: .row)
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let old = LayoutTiler.computeFrames(root: before, in: bounds, gap: 0)
        let new = LayoutTiler.computeFrames(root: after, in: bounds, gap: 0)
        let plan = LayoutTreeView.splitKeyframes(from: old, to: new, rootNode: after)
        let a = plan.first { $0.blockId == "A" }!
        let b = plan.first { $0.blockId == "B" }!

        // Existing pane: full width → half, ALWAYS full height, left edge fixed.
        XCTAssertEqual(a.frame(at: 0), CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(a.frame(at: 0.5), CGRect(x: 0, y: 0, width: 150, height: 100))
        XCTAssertEqual(a.frame(at: 1), CGRect(x: 0, y: 0, width: 100, height: 100))

        // New pane: grows from the RIGHT — right edge pinned at 200, height always 100
        // (horizontal-only), width 20 → 100, left edge scrolling inward to the divider.
        for t in [CGFloat(0), 0.5, 1] {
            XCTAssertEqual(b.frame(at: t).height, 100, "full height at t=\(t)")
            XCTAssertEqual(b.frame(at: t).maxX, 200, "right edge pinned at t=\(t)")
        }
        XCTAssertEqual(b.frame(at: 0).width, 0)    // starts at ZERO width (A and B each scale 100px)
        XCTAssertEqual(b.frame(at: 1), CGRect(x: 100, y: 0, width: 100, height: 100))
        XCTAssertGreaterThan(b.frame(at: 0).minX, b.frame(at: 1).minX)  // left edge scrolls in
        // Perfectly adjacent throughout: A's right edge == B's left edge at every t — a clean
        // divider sweeping in from the right, no overlap.
        for t in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
            XCTAssertEqual(a.frame(at: t).maxX, b.frame(at: t).minX, accuracy: 0.001, "adjacent at t=\(t)")
        }
    }

    // Vertical split analogue: A shrinks up keeping full WIDTH; the NEW pane B grows FROM THE
    // BOTTOM — bottom edge pinned, full width throughout, top edge scrolling up.
    func testSplitKeyframesVerticalGrowsFromBottom() {
        let before = LayoutNode(id: "na", data: TabLayoutData(blockId: "A"))
        let after = LayoutNode(id: "c", children: [
            LayoutNode(id: "na", data: TabLayoutData(blockId: "A"), size: 10),
            LayoutNode(id: "nb", data: TabLayoutData(blockId: "B"), size: 10),
        ], flexDirection: .column)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 200)
        let old = LayoutTiler.computeFrames(root: before, in: bounds, gap: 0)
        let new = LayoutTiler.computeFrames(root: after, in: bounds, gap: 0)
        let plan = LayoutTreeView.splitKeyframes(from: old, to: new, rootNode: after)
        let a = plan.first { $0.blockId == "A" }!
        let b = plan.first { $0.blockId == "B" }!

        // Existing pane: full height → half, ALWAYS full width, top edge fixed.
        XCTAssertEqual(a.frame(at: 0), CGRect(x: 0, y: 0, width: 100, height: 200))
        XCTAssertEqual(a.frame(at: 1), CGRect(x: 0, y: 0, width: 100, height: 100))

        // New pane: grows from the BOTTOM — bottom edge pinned at 200, width always 100
        // (vertical-only), height 20 → 100, top edge scrolling up to the divider.
        for t in [CGFloat(0), 0.5, 1] {
            XCTAssertEqual(b.frame(at: t).width, 100, "full width at t=\(t)")
            XCTAssertEqual(b.frame(at: t).maxY, 200, "bottom edge pinned at t=\(t)")
        }
        XCTAssertEqual(b.frame(at: 0).height, 0)   // starts at ZERO height
        XCTAssertEqual(b.frame(at: 1), CGRect(x: 0, y: 100, width: 100, height: 100))
        XCTAssertGreaterThan(b.frame(at: 0).minY, b.frame(at: 1).minY)  // top edge scrolls up
    }

    // ⌘⌥ pane navigation — directional neighbor resolution over a 2×2 grid (Row of two
    // Columns: A/C on the left, B/D on the right).
    func testNeighbor2x2Grid() {
        let col1 = LayoutNode(id: "c1", children: [
            LayoutNode(id: "a", data: TabLayoutData(blockId: "A"), size: 10),
            LayoutNode(id: "c", data: TabLayoutData(blockId: "C"), size: 10),
        ], flexDirection: .column)
        let col2 = LayoutNode(id: "c2", children: [
            LayoutNode(id: "b", data: TabLayoutData(blockId: "B"), size: 10),
            LayoutNode(id: "d", data: TabLayoutData(blockId: "D"), size: 10),
        ], flexDirection: .column)
        let root = LayoutNode(id: "r", children: [col1, col2], flexDirection: .row)
        let frames = LayoutTiler.computeFrames(root: root, in: CGRect(x: 0, y: 0, width: 100, height: 100), gap: 0)
        func rect(_ id: String) -> CGRect { frames.first { $0.blockId == id }!.frame }
        func nb(_ id: String, _ dir: PaneDirection, _ perp: CGFloat) -> String? {
            LayoutTiler.neighbor(from: rect(id), among: frames, direction: dir, perp: perp)?.blockId
        }
        // From the top-left pane.
        XCTAssertEqual(nb("A", .right, rect("A").midY), "B")
        XCTAssertEqual(nb("A", .down, rect("A").midX), "C")
        XCTAssertNil(nb("A", .up, rect("A").midX))    // outer edge
        XCTAssertNil(nb("A", .left, rect("A").midY))  // outer edge
        // From the bottom-right pane.
        XCTAssertEqual(nb("D", .left, rect("D").midY), "C")
        XCTAssertEqual(nb("D", .up, rect("D").midX), "B")
    }

    // ⌘⌥ pane navigation — the sticky perpendicular coordinate makes left↔right round-trips
    // land on the same pane. Layout: one tall left pane L + a right column of R1/R2/R3.
    func testNeighborStickyPerpendicular() {
        let rightCol = LayoutNode(id: "rc", children: [
            LayoutNode(id: "r1", data: TabLayoutData(blockId: "R1"), size: 10),
            LayoutNode(id: "r2", data: TabLayoutData(blockId: "R2"), size: 10),
            LayoutNode(id: "r3", data: TabLayoutData(blockId: "R3"), size: 10),
        ], flexDirection: .column)
        let root = LayoutNode(id: "r", children: [
            LayoutNode(id: "l", data: TabLayoutData(blockId: "L"), size: 10),
            rightCol,
        ], flexDirection: .row)
        let frames = LayoutTiler.computeFrames(root: root, in: CGRect(x: 0, y: 0, width: 100, height: 100), gap: 0)
        func rect(_ id: String) -> CGRect { frames.first { $0.blockId == id }!.frame }
        func nb(_ id: String, _ dir: PaneDirection, _ perp: CGFloat) -> String? {
            LayoutTiler.neighbor(from: rect(id), among: frames, direction: dir, perp: perp)?.blockId
        }
        // Entering the right column at L's own height lands on the middle pane.
        XCTAssertEqual(nb("L", .right, rect("L").midY), "R2")
        // Keeping R3's height (the sticky goal) makes L→right land on R3, and R3→left → L,
        // so the round-trip is reversible.
        XCTAssertEqual(nb("L", .right, rect("R3").midY), "R3")
        XCTAssertEqual(nb("R3", .left, rect("R3").midY), "L")
    }

    // ⌘⌥ pane navigation — modifier mapping must tolerate the .function/.numericPad flags
    // macOS sets on arrow-key events (regression: an `== [.command, .option]` check silently
    // never matched a real ⌘⌥arrow).
    func testPaneNavDirectionMapping() {
        // A real arrow event carries .function AND .numericPad on top of the chord.
        let arrow: NSEvent.ModifierFlags = [.command, .option, .function, .numericPad]
        XCTAssertEqual(WaveWindowController.paneNavDirection(flags: arrow, scalar: UInt32(NSLeftArrowFunctionKey)), .left)
        XCTAssertEqual(WaveWindowController.paneNavDirection(flags: arrow, scalar: UInt32(NSRightArrowFunctionKey)), .right)
        XCTAssertEqual(WaveWindowController.paneNavDirection(flags: arrow, scalar: UInt32(NSUpArrowFunctionKey)), .up)
        XCTAssertEqual(WaveWindowController.paneNavDirection(flags: arrow, scalar: UInt32(NSDownArrowFunctionKey)), .down)
        // Also resolves without the extra flags.
        XCTAssertEqual(WaveWindowController.paneNavDirection(flags: [.command, .option], scalar: UInt32(NSUpArrowFunctionKey)), .up)
        // Wrong / missing modifiers → nil (no option is the tab-switch chord; shift/control excluded).
        XCTAssertNil(WaveWindowController.paneNavDirection(flags: [.command, .function, .numericPad], scalar: UInt32(NSLeftArrowFunctionKey)))
        XCTAssertNil(WaveWindowController.paneNavDirection(flags: [.command, .option, .shift], scalar: UInt32(NSLeftArrowFunctionKey)))
        XCTAssertNil(WaveWindowController.paneNavDirection(flags: [.command, .option, .control], scalar: UInt32(NSLeftArrowFunctionKey)))
        XCTAssertNil(WaveWindowController.paneNavDirection(flags: arrow, scalar: nil))
        XCTAssertNil(WaveWindowController.paneNavDirection(flags: arrow, scalar: UInt32(UnicodeScalar("a").value)))
    }

    // GUARDS §P — fresh, std-base64 (not url-safe) auth key per launch.
    func testAuthKeyFreshAndStd() {
        let a = AppCoordinator.generateAuthKey()
        let b = AppCoordinator.generateAuthKey()
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.contains("-"))
        XCTAssertFalse(a.contains("_"))
        XCTAssertNotNil(WaveBase64.decode(a))
    }

    // MARK: - Web nav chrome + OSC-8 link open

    // The block header picks its content chrome from `meta.view`: a web block shows
    // the address bar, a terminal shows its connection label, everything else a title.
    func testHeaderModeSelection() {
        XCTAssertEqual(BlockFrameView.headerMode(forView: "web"), .web)
        XCTAssertEqual(BlockFrameView.headerMode(forView: "term"), .terminal)
        XCTAssertEqual(BlockFrameView.headerMode(forView: "preview"), .generic)
        XCTAssertEqual(BlockFrameView.headerMode(forView: nil), .generic)
    }

    // The OSC-8 "open link" path maps a (tab, source block, URI) to a web-pane create
    // request: view:"web" + url, NO controller (a web block has no pty), split to the
    // right of the source pane, focused.
    func testWebLinkCreateBlockDataMapping() {
        let data = AppCoordinator.makeWebLinkCreateBlockData(
            tabId: "tab-7", targetBlockId: "blk-src", url: "https://example.com")
        XCTAssertEqual(data.tabid, "tab-7")
        XCTAssertEqual(data.targetblockid, "blk-src")
        XCTAssertEqual(data.targetaction, "splitright")
        XCTAssertEqual(data.focused, true)
        let meta = data.blockdef?.meta
        XCTAssertEqual(meta?["view"]?.stringValue, "web")
        XCTAssertEqual(meta?["url"]?.stringValue, "https://example.com")
        XCTAssertNil(meta?["controller"], "a web block must not carry a shell controller")
    }

    // MARK: - Per-pane settings menu (pure item-set logic)

    typealias MenuID = BlockFrameView.BlockMenuItemID

    // Generic blocks: Electron parity is magnify, split, Copy BlockId, Close — no
    // view-specific section.
    func testGenericMenuItems() {
        let items = BlockFrameView.blockMenuItems(
            view: .generic, canMagnify: false, isMagnified: false, isNavHidden: false)
        XCTAssertEqual(items, [.splitRight, .splitDown, .separator, .renamePane, .copyBlockId, .copyLink, .separator, .close])
        // Copy BlockId is present for every view type (the P0 generic-parity addition).
        XCTAssertTrue(items.contains(.copyBlockId))
        // No terminal/web-only items leak into the generic menu.
        XCTAssertFalse(items.contains(.forceRestart))
        XCTAssertFalse(items.contains(.zoom))
    }

    // Magnify is offered only with >1 pane, and flips to Minimize when magnified.
    func testMagnifyPrefixReflectsState() {
        let none = BlockFrameView.blockMenuItems(
            view: .generic, canMagnify: false, isMagnified: false, isNavHidden: false)
        XCTAssertFalse(none.contains(.magnify))
        XCTAssertFalse(none.contains(.minimize))

        let magnify = BlockFrameView.blockMenuItems(
            view: .generic, canMagnify: true, isMagnified: false, isNavHidden: false)
        XCTAssertEqual(Array(magnify.prefix(2)), [.magnify, .separator])

        let minimize = BlockFrameView.blockMenuItems(
            view: .generic, canMagnify: true, isMagnified: true, isNavHidden: false)
        XCTAssertEqual(Array(minimize.prefix(2)), [.minimize, .separator])
    }

    // Terminal blocks add Copy/Paste/Select All + the backend-honored advanced toggles,
    // and keep the common Copy-BlockId/Close suffix.
    func testTerminalMenuItems() {
        let items = BlockFrameView.blockMenuItems(
            view: .terminal, canMagnify: true, isMagnified: false, isNavHidden: false)
        XCTAssertEqual(items, [
            .magnify, .separator,
            .splitRight, .splitDown,
            .separator, .themes,
            .separator, .copy, .paste, .selectAll,
            .separator, .forceRestart, .termClearBuffer, .resetTerminal, .clearOnRestart, .runOnStartup, .debugConnection,
            .separator, .renamePane, .copyBlockId, .copyLink, .separator, .close,
        ])
        // The per-pane Themes submenu is now live (term:theme → palette re-render).
        XCTAssertTrue(items.contains(.themes))
        // Deferred terminal items must NOT appear (no live re-render plumbing).
        XCTAssertFalse(items.contains(.zoom))
        XCTAssertFalse(items.contains(.userAgentType))
    }

    // Web blocks add the URL + zoom/UA/nav section; the nav toggle label flips with the
    // current `web:hidenav` state.
    func testWebMenuItems() {
        let shown = BlockFrameView.blockMenuItems(
            view: .web, canMagnify: false, isMagnified: false, isNavHidden: false)
        XCTAssertEqual(shown, [
            .splitRight, .splitDown,
            .separator, .reload, .copyURL, .openExternal, .setBlockHomepage,
            .separator, .hideNav, .userAgentType, .zoom,
            .separator, .renamePane, .copyBlockId, .copyLink, .separator, .close,
        ])
        // When nav is hidden, the toggle reads "Un-Hide" (unhideNav) instead.
        let hidden = BlockFrameView.blockMenuItems(
            view: .web, canMagnify: false, isMagnified: false, isNavHidden: true)
        XCTAssertTrue(hidden.contains(.unhideNav))
        XCTAssertFalse(hidden.contains(.hideNav))
        // Terminal-only items must NOT appear in the web menu.
        XCTAssertFalse(shown.contains(.forceRestart))
        XCTAssertFalse(shown.contains(.copy))
    }

    // MARK: - Honest-settings wiring (telemetry / window / web / term themes)

    // Telemetry decision: disable unless ALREADY explicitly false (idempotent).
    func testTelemetryDisableDecision() {
        XCTAssertTrue(AppCoordinator.shouldDisableTelemetry([:]), "missing → disable")
        XCTAssertTrue(AppCoordinator.shouldDisableTelemetry(["telemetry:enabled": .bool(true)]))
        XCTAssertFalse(AppCoordinator.shouldDisableTelemetry(["telemetry:enabled": .bool(false)]))
    }

    // Bootstrap forces telemetry off via a `setconfig` when it isn't already false.
    func testTelemetryEnforcedAtBootstrapWhenUnset() async throws {
        let (t, s) = makeWorld()
        t.fullConfigResponse = .object(["settings": .object([:])])
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        let setconfigs = t.recordedGeneric().filter { $0.command == "setconfig" }
        XCTAssertTrue(
            setconfigs.contains { $0.data?["telemetry:enabled"]?.boolValue == false },
            "bootstrap must issue setconfig telemetry:enabled=false when unset")
    }

    // …and does NOT write when telemetry is already disabled (no event loop).
    func testTelemetryNotWrittenWhenAlreadyFalse() async throws {
        let (t, s) = makeWorld()
        t.fullConfigResponse = .object(["settings": .object(["telemetry:enabled": .bool(false)])])
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        let setconfigs = t.recordedGeneric().filter { $0.command == "setconfig" }
        XCTAssertFalse(
            setconfigs.contains { $0.data?["telemetry:enabled"] != nil },
            "telemetry already false must not be re-written")
    }

    // Per-window appearance mapping. Opacity ALWAYS maps to the whole-window alphaValue
    // (the fix: a uniform fade that works over opaque panes); transparent/blur make the
    // window non-opaque and drop the CONTENT background alpha so the blur/desktop shows.
    func testWindowAppearanceMapping() {
        let opaque = WindowAppearance.from([:])
        XCTAssertTrue(opaque.isOpaque)
        XCTAssertEqual(opaque.windowAlpha, 1, accuracy: 0.001)
        XCTAssertEqual(opaque.contentBackgroundAlpha, 1, accuracy: 0.001)

        // Opacity drives alphaValue EVEN when the window is opaque (the whole-window fade).
        let opacityOnly = WindowAppearance.from(["window:opacity": .double(0.7)])
        XCTAssertTrue(opacityOnly.isOpaque)
        XCTAssertEqual(opacityOnly.windowAlpha, 0.7, accuracy: 0.001)
        XCTAssertEqual(opacityOnly.contentBackgroundAlpha, 1, accuracy: 0.001,
                       "opaque window keeps a solid content bg")

        // Transparent → non-opaque + see-through content; opacity still maps to alphaValue.
        let transparent = WindowAppearance.from([
            "window:transparent": .bool(true), "window:opacity": .double(0.7)])
        XCTAssertFalse(transparent.isOpaque)
        XCTAssertEqual(transparent.windowAlpha, 0.7, accuracy: 0.001)
        XCTAssertEqual(transparent.contentBackgroundAlpha,
                       WindowAppearance.translucentContentAlpha, accuracy: 0.001)

        // Blur alone makes the window translucent; opacity clamps to the 0.3 floor.
        let blur = WindowAppearance.from(["window:blur": .bool(true), "window:opacity": .double(0.1)])
        XCTAssertFalse(blur.isOpaque)
        XCTAssertEqual(blur.windowAlpha, WindowAppearance.minOpacity, accuracy: 0.001,
                       "opacity clamps to the floor")
        XCTAssertEqual(blur.contentBackgroundAlpha,
                       WindowAppearance.translucentContentAlpha, accuracy: 0.001)
    }

    // web:defaulturl is injected into a urlless web block; web:openlinksinternally default false.
    func testWebDefaultsAndOpenLinks() {
        XCTAssertFalse(AppCoordinator.shouldOpenLinksInternally([:]))
        XCTAssertTrue(AppCoordinator.shouldOpenLinksInternally(["web:openlinksinternally": .bool(true)]))

        // A urlless web widget meta gets the default homepage.
        let injected = AppCoordinator.applyWebDefaults(
            toMeta: ["view": .string("web")],
            settings: ["web:defaulturl": .string("https://example.com")])
        XCTAssertEqual(injected["url"]?.stringValue, "https://example.com")
        // A web block that already has a url is untouched.
        let kept = AppCoordinator.applyWebDefaults(
            toMeta: ["view": .string("web"), "url": .string("https://a.com")], settings: [:])
        XCTAssertEqual(kept["url"]?.stringValue, "https://a.com")
        // Non-web metas pass through unchanged (no url injected).
        let term = AppCoordinator.applyWebDefaults(toMeta: ["view": .string("term")], settings: [:])
        XCTAssertNil(term["url"])
        // Default fallback when the setting is unset.
        XCTAssertEqual(
            AppCoordinator.webDefaultURL(from: [:]), "https://github.com/wavetermdev/waveterm")
    }

    // term:theme parse from a fullConfig blob + resolution (block-meta → global → default).
    func testTermThemeParseAndResolution() {
        let config = JSONValue.object([
            "termthemes": .object([
                "onedark": .object([
                    "display:name": .string("One Dark"),
                    "display:order": .double(2),
                    "background": .string("#21252B"),
                    "foreground": .string("#ABB2BF"),
                    "red": .string("#E06C75"),
                    "selectionBackground": .string(""),
                ]),
            ]),
        ])
        let themes = AppCoordinator.parseTermThemes(config)
        let one = themes["onedark"]
        XCTAssertEqual(one?.displayName, "One Dark")
        XCTAssertEqual(one?.background, "#21252B")
        XCTAssertEqual(one?.foreground, "#ABB2BF")
        XCTAssertEqual(one?.ansi[1], "#E06C75", "red is ANSI index 1")
        XCTAssertNil(one?.ansi[0], "unset black stays nil (keeps libghostty default)")
        XCTAssertNil(one?.selection, "empty selectionBackground → nil")

        // Resolution precedence.
        XCTAssertEqual(
            AppCoordinator.resolveTermThemeName(
                blockMeta: ["term:theme": .string("onedark")],
                settings: ["term:theme": .string("global")]),
            "onedark", "block meta wins")
        XCTAssertEqual(
            AppCoordinator.resolveTermThemeName(blockMeta: [:], settings: ["term:theme": .string("global")]),
            "global", "global setting is next")
        XCTAssertEqual(
            AppCoordinator.resolveTermThemeName(blockMeta: nil, settings: [:]),
            "default-dark", "default fallback")
    }

    // The web nav bridge caches the live URL and notifies the header on change, so the
    // address bar reflects the page even if it mounts after the first push.
    func testWebNavBridgeURLObservation() {
        let bridge = WebNavBridge()
        var observed: [String?] = []
        bridge.onURLChange = { observed.append($0) }
        bridge.updateURL("https://a.com")
        XCTAssertEqual(bridge.currentURL, "https://a.com")
        bridge.updateURL("https://b.com")
        XCTAssertEqual(observed, ["https://a.com", "https://b.com"])

        var backCalled = false
        bridge.goBack = { backCalled = true }
        bridge.goBack?()
        XCTAssertTrue(backCalled, "the header's back button must reach the bridge action")
    }
}

/// A transport whose callService always returns the given updates (for §B test).
final class UpdatingTransport: FakeTransport {
    private let cannedUpdates: [WaveObjUpdate]
    init(updates: [WaveObjUpdate]) {
        self.cannedUpdates = updates
        super.init()
    }
    override func callService(_ call: WebCallType) async throws -> WebReturnType {
        WebReturnType(success: true, updates: cannedUpdates)
    }
}
