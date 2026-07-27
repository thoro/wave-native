// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI connection tests — the testable logic of the native connection UI:
//   - ConnStatus decode (lenient: ignores wire fields the chrome doesn't model).
//   - ConnectionLabel derivation (local machine vs. remote user@host).
//   - ConnectionStore seed/upsert + colour-number mapping.
//   - The connect flow: setBlockConnection issues setmeta THEN connensure (remote);
//     local clears the meta and skips connensure.
//   - connchange routing: AppCoordinator upserts the event into its ConnectionStore.
//   - Split inherits the source block's remote connection (ensure-connect first).
//
// These run without a live wavesrv (the FakeTransport / FakeStore from WaveUITests).

import XCTest
import AppKit
@testable import WaveCore
@testable import WaveUI

/// Local world builder (the WaveUITests `makeWorld` is file-private). Mirrors it.
private func makeConnWorld() -> (FakeTransport, FakeStore) {
    let t = FakeTransport()
    let s = FakeStore()
    s.preload(.window(Window(oid: "win-1", version: 1, workspaceid: "ws-1",
                             pos: Point(x: 0, y: 0), winsize: WinSize(width: 1, height: 1),
                             lastfocusts: 0, meta: [:])))
    s.preload(.workspace(Workspace(oid: "ws-1", version: 1, name: "Default",
                                   tabids: ["tab-1"], activetabid: "tab-1", meta: [:])))
    s.preload(.tab(Tab(oid: "tab-1", version: 1, name: "One", layoutstate: "layout:lay-1",
                       blockids: ["blk-1"], meta: [:])))
    s.preload(.layout(LayoutState(oid: "lay-1", version: 1)))
    s.preload(.block(Block(oid: "blk-1", version: 1, meta: ["view": .string("term")])))
    return (t, s)
}

@MainActor
final class ConnectionTests: XCTestCase {

    // MARK: - ConnStatus decode

    func testConnStatusDecodeLenient() throws {
        // A connchange-shaped payload with extra fields the chrome does not model.
        let payload = JSONValue.object([
            "status": .string("connected"),
            "connection": .string("user@host"),
            "connected": .bool(true),
            "hasconnected": .bool(true),
            "activeconnnum": .int(3),
            "wshenabled": .bool(true),
            "connhealthstatus": .string("connected"),
            "nowshreason": .string("ignored"),
            "wshversion": .string("v0.1"),
        ])
        let status = try payload.decode(ConnStatus.self)
        XCTAssertEqual(status.status, ConnStatusValue.connected)
        XCTAssertEqual(status.connection, "user@host")
        XCTAssertTrue(status.connected)
        XCTAssertEqual(status.activeconnnum, 3)
        XCTAssertEqual(status.wshenabled, true)
    }

    func testConnStatusDecodeOmittedOptionals() throws {
        // omitempty error/wsherror absent → optionals decode to nil.
        let payload = JSONValue.object([
            "status": .string("connecting"),
            "connection": .string("box"),
            "connected": .bool(false),
            "hasconnected": .bool(false),
            "activeconnnum": .int(0),
        ])
        let status = try payload.decode(ConnStatus.self)
        XCTAssertEqual(status.status, ConnStatusValue.connecting)
        XCTAssertNil(status.error)
        XCTAssertNil(status.wsherror)
    }

    // MARK: - ConnectionLabel derivation

    func testLabelLocalVariants() {
        let local = ConnectionLabel.derive(connection: nil, localDisplayName: "me@mac")
        XCTAssertTrue(local.isLocal)
        XCTAssertEqual(local.title, "me@mac")
        XCTAssertEqual(local.icon, ConnectionLabel.localIcon)

        XCTAssertTrue(ConnectionLabel.derive(connection: "", localDisplayName: "me@mac").isLocal)
        XCTAssertTrue(ConnectionLabel.derive(connection: "local", localDisplayName: "me@mac").isLocal)
        XCTAssertTrue(ConnectionLabel.derive(connection: "local:gitbash", localDisplayName: "me@mac").isLocal)
    }

    func testLabelRemote() {
        let remote = ConnectionLabel.derive(connection: "root@server", localDisplayName: "me@mac")
        XCTAssertFalse(remote.isLocal)
        XCTAssertEqual(remote.title, "root@server")
        XCTAssertEqual(remote.icon, ConnectionLabel.remoteIcon)
    }

    // MARK: - ConnectionStore

    func testStoreSeedUpsertAndColorNum() {
        let store = ConnectionStore(localDisplayName: "me@mac")
        store.seed([
            ConnStatus(status: ConnStatusValue.connected, connection: "a", connected: true, activeconnnum: 1),
            ConnStatus(status: ConnStatusValue.connecting, connection: "b", activeconnnum: 8),
        ])
        XCTAssertEqual(store.status(for: "a")?.status, ConnStatusValue.connected)
        XCTAssertEqual(store.colorNum(for: "a"), 1)
        // activeconnnum 8 % 8 == 0 → wraps to N (8).
        XCTAssertEqual(store.colorNum(for: "b"), 8)

        store.upsert(ConnStatus(status: ConnStatusValue.error, connection: "a", error: "boom"))
        XCTAssertEqual(store.status(for: "a")?.status, ConnStatusValue.error)
        XCTAssertEqual(store.status(for: "a")?.error, "boom")
    }

    func testStoreNotifiesSubscribers() {
        let store = ConnectionStore(localDisplayName: "me@mac")
        var fired = 0
        let token = store.subscribe { fired += 1 }
        store.upsert(ConnStatus(status: ConnStatusValue.connected, connection: "a"))
        store.setLocalDisplayName("you@box")
        XCTAssertEqual(fired, 2)
        token.cancel()
        store.upsert(ConnStatus(status: ConnStatusValue.error, connection: "a"))
        XCTAssertEqual(fired, 2, "cancelled subscriber must not fire")
    }

    // MARK: - Connect flow (setmeta + connensure)

    func testSetBlockConnectionRemoteIssuesSetMetaThenEnsure() async throws {
        let (t, s) = makeConnWorld()
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        coordinator.setBlockConnection(blockId: "blk-1", connName: "root@server")
        try await Task.sleep(nanoseconds: 250_000_000)

        let voids = t.recordedVoid()
        let setMetaIdx = voids.firstIndex { $0.command == "setmeta" }
        let ensureIdx = voids.firstIndex { $0.command == "connensure" }
        XCTAssertNotNil(setMetaIdx, "remote connect must setmeta(connection)")
        XCTAssertNotNil(ensureIdx, "remote connect must connensure")
        XCTAssertLessThan(setMetaIdx!, ensureIdx!, "setmeta must precede connensure")

        // The connensure carries the picked connection name.
        let ensure = try voids[ensureIdx!].data!.decode(ConnExtData.self)
        XCTAssertEqual(ensure.connname, "root@server")
    }

    func testSetBlockConnectionLocalSkipsEnsure() async throws {
        let (t, s) = makeConnWorld()
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        coordinator.setBlockConnection(blockId: "blk-1", connName: "local")
        try await Task.sleep(nanoseconds: 250_000_000)

        let voids = t.recordedVoid()
        XCTAssertTrue(voids.contains { $0.command == "setmeta" }, "local still clears the meta via setmeta")
        XCTAssertFalse(voids.contains { $0.command == "connensure" }, "local must not connensure")
    }

    // MARK: - connchange routing

    func testConnChangeEventUpsertsStore() async throws {
        let (t, s) = makeConnWorld()
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        let status = ConnStatus(status: ConnStatusValue.connecting, connection: "root@server",
                                activeconnnum: 2)
        t.emit(WaveEvent(event: WaveEventName.connChange, data: try JSONValue.encode(status)))
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(coordinator.connectionStore.status(for: "root@server")?.status,
                       ConnStatusValue.connecting)
    }

    // MARK: - Split inherits connection

    func testSplitInheritsRemoteConnectionEnsuresFirst() async throws {
        let (t, s) = makeConnWorld()
        s.preload(.block(Block(oid: "blk-r", version: 1,
                               meta: ["view": .string("term"), "connection": .string("root@server")])))
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = RecordingDelegate()
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        coordinator.splitFocusedBlock(blockId: "blk-r", direction: "horizontal")
        try await Task.sleep(nanoseconds: 250_000_000)

        let voids = t.recordedVoid()
        let ensure = voids.first { $0.command == "connensure" }
        XCTAssertNotNil(ensure, "splitting a remote pane must ensure-connect first")
        let data = try ensure!.data!.decode(ConnExtData.self)
        XCTAssertEqual(data.connname, "root@server")
    }

    // MARK: - Split inherits cwd (OSC 7)

    /// When the content provider knows the source pane's cwd, the split's CreateBlock
    /// payload carries it as `cmd:cwd` (the backend `MetaKey_CmdCwd`), so the new shell
    /// starts in the same directory.
    func testSplitInheritsCwdSetsCmdCwdMeta() async throws {
        let (t, s) = makeConnWorld()
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = CwdStubDelegate(cwd: "/Users/me/project")
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        coordinator.splitFocusedBlock(blockId: "blk-1", direction: "horizontal")
        try await Task.sleep(nanoseconds: 250_000_000)

        let create = try XCTUnwrap(t.recordedGeneric().first { $0.command == "createblock" })
        let payload = try XCTUnwrap(create.data).decodeAsCreateBlock()
        XCTAssertEqual(payload["cmd:cwd"], "/Users/me/project",
                       "split must persist the source pane's cwd as cmd:cwd")
    }

    /// An update replaces the native UI process, clearing the provider's in-memory OSC 7
    /// cache while the source block and its persisted metadata survive. Splitting during
    /// that restore window must use the persisted cwd instead of opening at `/`.
    func testSplitAfterRestartFallsBackToPersistedCwd() async throws {
        let (t, s) = makeConnWorld()
        s.preload(.block(Block(
            oid: "blk-1", version: 2,
            meta: ["view": .string("term"), "cmd:cwd": .string("/Users/me/restored-project")]
        )))
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = CwdStubDelegate(cwd: nil)
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        coordinator.splitFocusedBlock(blockId: "blk-1", direction: "horizontal")
        try await Task.sleep(nanoseconds: 250_000_000)

        let create = try XCTUnwrap(t.recordedGeneric().first { $0.command == "createblock" })
        let payload = try XCTUnwrap(create.data).decodeAsCreateBlock()
        XCTAssertEqual(payload["cmd:cwd"], "/Users/me/restored-project",
                       "restored split must inherit the persisted source cwd")
    }

    /// With no known cwd (the pane never reported OSC 7), the split's CreateBlock payload
    /// must NOT carry `cmd:cwd` — the new shell opens at the backend default directory.
    func testSplitWithoutKnownCwdOmitsCmdCwdMeta() async throws {
        let (t, s) = makeConnWorld()
        let coordinator = AppCoordinator(transport: t, store: s)
        let delegate = CwdStubDelegate(cwd: nil)
        coordinator.delegate = delegate
        coordinator.start()
        await fulfillment(of: [delegate.ready], timeout: 2)

        coordinator.splitFocusedBlock(blockId: "blk-1", direction: "horizontal")
        try await Task.sleep(nanoseconds: 250_000_000)

        let create = try XCTUnwrap(t.recordedGeneric().first { $0.command == "createblock" })
        let payload = try XCTUnwrap(create.data).decodeAsCreateBlock()
        XCTAssertNil(payload["cmd:cwd"], "no known cwd → no cmd:cwd meta")
    }
}

/// Decodes a recorded `createblock` payload to its block-def string-meta map (only the
/// string-valued keys, which is all this test cares about).
private extension JSONValue {
    func decodeAsCreateBlock() throws -> [String: String] {
        let data = try decode(CommandCreateBlockData.self)
        var out: [String: String] = [:]
        for (k, v) in data.blockdef?.meta ?? [:] {
            if let sv = v.stringValue { out[k] = sv }
        }
        return out
    }
}

/// Minimal coordinator delegate that reports a fixed cwd for any block — drives the
/// split-inherits-cwd path without a live content provider.
@MainActor
private final class CwdStubDelegate: AppCoordinatorDelegate {
    let ready = XCTestExpectation(description: "ready")
    let cwd: String?
    init(cwd: String?) { self.cwd = cwd }

    func coordinatorCwdForBlock(_ blockId: String) -> String? { cwd }

    func coordinatorDidUpdateWorkspace(name: String?, icon: String?, color: String?, workspaceId: String?) {}
    func coordinatorDidUpdateWorkspaceList(_ items: [WorkspaceMenuItem]) {}
    func coordinatorDidUpdateTabs(_ tabs: [TabBarItem], activeTabId: String?) {}
    func coordinatorDidUpdateLayout(env: BlockEnvFactory, root: LayoutNode?, focusedNodeId: String?, magnifiedNodeId: String?) {}
    func coordinatorRequestFocusBlock(_ blockId: String) {}
    func coordinatorDidBecomeReady() { ready.fulfill() }
    func coordinatorRequestCloseWindow() {}
    func coordinatorDidFail(_ error: Error) {}
}
