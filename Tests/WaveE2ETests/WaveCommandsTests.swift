// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveCommands unit tests — verify the request ENCODING (service/method/args/
// uicontext for the HTTP service layer; command + data for wshrpc) and the
// GUARDS each wrapper upholds, without a live wavesrv:
//   §B  inline `updates` from every service response are applied to the store.
//   §C  SetActiveTab is issued; CloseTab's {closewindow,newactivetabid} is
//       surfaced; the last tab cannot be moved out of a workspace.
//   §3  arg order matches the reflective dispatcher (ctx + UIContext injected
//       server-side, never in `args`); multi-arg wsh commands use MultiArg.

import XCTest
@testable import WaveCommands
import WaveCore

// MARK: - Test doubles

private final class MockTransport: WaveTransport, @unchecked Sendable {
    private let lock = NSLock()

    private var _lastServiceCall: WebCallType?
    private var _lastWshCommand: String?
    private var _lastWshData: JSONValue?
    private var _nextWebReturn = WebReturnType(success: true)
    private var _nextRpcResponse: JSONValue = .null

    var lastServiceCall: WebCallType? { lock.lock(); defer { lock.unlock() }; return _lastServiceCall }
    var lastWshCommand: String? { lock.lock(); defer { lock.unlock() }; return _lastWshCommand }
    var lastWshData: JSONValue? { lock.lock(); defer { lock.unlock() }; return _lastWshData }

    func setNextWebReturn(_ r: WebReturnType) { lock.lock(); _nextWebReturn = r; lock.unlock() }
    func setNextRpcResponse(_ v: JSONValue) { lock.lock(); _nextRpcResponse = v; lock.unlock() }

    // Recorded surface used by WaveCommands.
    func callService(_ call: WebCallType) async throws -> WebReturnType {
        lock.lock(); _lastServiceCall = call; let r = _nextWebReturn; lock.unlock()
        return r
    }

    func call<Req: Encodable & Sendable, Res: Decodable & Sendable>(
        command: String, data: Req?, route: String?, timeoutMs: Int64?
    ) async throws -> Res {
        lock.lock()
        _lastWshCommand = command
        _lastWshData = data.flatMap { try? JSONValue.encode($0) }
        let resp = _nextRpcResponse
        lock.unlock()
        return try resp.decode(Res.self)
    }

    func callVoid<Req: Encodable & Sendable>(
        command: String, data: Req?, route: String?, timeoutMs: Int64?
    ) async throws {
        lock.lock()
        _lastWshCommand = command
        _lastWshData = data.flatMap { try? JSONValue.encode($0) }
        lock.unlock()
    }

    // Unused by WaveCommands tests.
    var addrs: ServerAddrs? { nil }
    var routeId: String? { "window:win-1" }
    var isConnected: Bool { true }
    var onReconnect: (@Sendable () -> Void)?
    func spawn(env: [String: String]) async throws -> ServerAddrs { fatalError("unused") }
    func connect(routeId: String) async throws { fatalError("unused") }
    func reconnect() async throws { fatalError("unused") }
    func disconnect() {}
    func notify<Req: Encodable & Sendable>(command: String, data: Req?, route: String?) throws { fatalError("unused") }
    func stream<Req: Encodable & Sendable>(
        command: String, data: Req?, route: String?,
        onChunk: @escaping @Sendable (Result<RpcMessage, WaveError>) -> Void
    ) throws -> SubscriptionToken { fatalError("unused") }
    func fetchFile(zoneId: String, name: String, offset: Int64) async throws -> (data: Data, info: WaveFile) {
        fatalError("unused")
    }
    func subscribe(_ request: SubscriptionRequest, handler: @escaping @Sendable (WaveEvent) -> Void) -> SubscriptionToken {
        fatalError("unused")
    }
}

private final class MockStore: ObjectStoreProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var objects: [String: AnyWaveObj] = [:]
    private var _appliedUpdates: [WaveObjUpdate] = []

    var appliedUpdates: [WaveObjUpdate] { lock.lock(); defer { lock.unlock() }; return _appliedUpdates }

    func preset(_ obj: AnyWaveObj) { lock.lock(); objects[obj.oref.string] = obj; lock.unlock() }

    func get(_ oref: ORef) -> AnyWaveObj? { lock.lock(); defer { lock.unlock() }; return objects[oref.string] }

    func load(_ oref: ORef) async throws -> AnyWaveObj {
        lock.lock(); let o = objects[oref.string]; lock.unlock()
        guard let o else { throw WaveError.rpc("not found: \(oref.string)") }
        return o
    }

    func loadMany(_ orefs: [ORef]) async throws -> [AnyWaveObj] {
        var rtn: [AnyWaveObj] = []
        for oref in orefs { rtn.append(try await load(oref)) }
        return rtn
    }

    @discardableResult
    func merge(_ obj: AnyWaveObj) -> Bool { lock.lock(); objects[obj.oref.string] = obj; lock.unlock(); return true }

    func applyUpdates(_ updates: [WaveObjUpdate]) {
        lock.lock(); _appliedUpdates.append(contentsOf: updates); lock.unlock()
    }

    func subscribe(_ oref: ORef, handler: @escaping @Sendable (AnyWaveObj?) -> Void) -> SubscriptionToken {
        SubscriptionToken {}
    }
}

// MARK: - Helpers

private func makeCommands(_ transport: MockTransport, _ store: MockStore) -> WaveCommands {
    WaveCommands(transport: transport, store: store) {
        UIContext(windowid: "win-1", activetabid: "active-tab")
    }
}

private func sampleUpdate() -> WaveObjUpdate {
    WaveObjUpdate(updatetype: updateTypeUpdate, otype: OType.workspace, oid: "ws-123",
                  obj: .object(["oid": .string("ws-123"), "version": .int(1)]))
}

final class WaveCommandsTests: XCTestCase {

    // MARK: §3 arg order + §B updates (HTTP service)

    func testCreateWorkspaceEncodingAndUpdates() async throws {
        let transport = MockTransport(); let store = MockStore()
        transport.setNextWebReturn(WebReturnType(success: true, data: .string("ws-123"), updates: [sampleUpdate()]))
        let cmd = makeCommands(transport, store)

        let id = try await cmd.createWorkspace(name: "My WS", icon: "circle", color: "blue", applyDefaults: true)

        XCTAssertEqual(id, "ws-123")
        let call = try XCTUnwrap(transport.lastServiceCall)
        XCTAssertEqual(call.service, "workspace")
        XCTAssertEqual(call.method, "CreateWorkspace")
        XCTAssertEqual(call.args, [.string("My WS"), .string("circle"), .string("blue"), .bool(true)])
        // GUARDS §B: inline updates applied to the SAME cache.
        XCTAssertEqual(store.appliedUpdates.count, 1)
        XCTAssertEqual(store.appliedUpdates.first?.oid, "ws-123")
    }

    func testCreateBlockSetsActiveTabInUIContext() async throws {
        let transport = MockTransport(); let store = MockStore()
        transport.setNextWebReturn(WebReturnType(success: true, data: .string("blk-1")))
        let cmd = makeCommands(transport, store)

        let blockId = try await cmd.createBlock(tabId: "tab-9", blockDef: BlockDef(meta: ["view": .string("term")]))

        XCTAssertEqual(blockId, "blk-1")
        let call = try XCTUnwrap(transport.lastServiceCall)
        XCTAssertEqual(call.service, "object")
        XCTAssertEqual(call.method, "CreateBlock")
        // ctx + UIContext are injected server-side: args carry only blockDef + rtOpts.
        XCTAssertEqual(call.args.count, 2)
        let def = try call.args[0].decode(BlockDef.self)
        XCTAssertEqual(def.meta?["view"]?.stringValue, "term")
        XCTAssertTrue(call.args[1].isNull) // rtOpts nil
        // Backend creates the block on UIContext.activetabid.
        XCTAssertEqual(call.uicontext?.activetabid, "tab-9")
        XCTAssertEqual(call.uicontext?.windowid, "win-1")
    }

    func testSetActiveTabEncoding() async throws {
        let transport = MockTransport(); let store = MockStore()
        let cmd = makeCommands(transport, store)
        try await cmd.setActiveTab(workspaceId: "ws-1", tabId: "tab-2")
        let call = try XCTUnwrap(transport.lastServiceCall)
        XCTAssertEqual(call.service, "workspace")
        XCTAssertEqual(call.method, "SetActiveTab")
        XCTAssertEqual(call.args, [.string("ws-1"), .string("tab-2")])
    }

    func testSetWindowPosAndSizeEncodesNullableArgs() async throws {
        let transport = MockTransport(); let store = MockStore()
        let cmd = makeCommands(transport, store)
        try await cmd.setWindowPosAndSize(windowId: "win-1", pos: Point(x: 1, y: 2), size: nil)
        let call = try XCTUnwrap(transport.lastServiceCall)
        XCTAssertEqual(call.method, "SetWindowPosAndSize")
        XCTAssertEqual(call.args[0], .string("win-1"))
        XCTAssertEqual(try call.args[1].decode(Point.self), Point(x: 1, y: 2))
        XCTAssertTrue(call.args[2].isNull)
    }

    // MARK: §C CloseTab honoring

    func testCloseTabReturnsCloseWindow() async throws {
        let transport = MockTransport(); let store = MockStore()
        transport.setNextWebReturn(WebReturnType(success: true, data: .object(["closewindow": .bool(true)])))
        let cmd = makeCommands(transport, store)
        let result = try await cmd.closeTab(workspaceId: "ws-1", tabId: "tab-1")
        XCTAssertTrue(result.closewindow)
        XCTAssertEqual(result.newactivetabid, "")
    }

    func testCloseTabReturnsNewActiveTab() async throws {
        let transport = MockTransport(); let store = MockStore()
        transport.setNextWebReturn(WebReturnType(success: true, data: .object(["newactivetabid": .string("tab-2")])))
        let cmd = makeCommands(transport, store)
        let result = try await cmd.closeTab(workspaceId: "ws-1", tabId: "tab-1")
        XCTAssertFalse(result.closewindow)
        XCTAssertEqual(result.newactivetabid, "tab-2")
    }

    // MARK: §C move-last-tab guard

    func testMoveTabRejectsLastTab() async throws {
        let transport = MockTransport(); let store = MockStore()
        store.preset(.workspace(Workspace(oid: "ws-src", version: 1, tabids: ["only"], activetabid: "only", meta: [:])))
        let cmd = makeCommands(transport, store)
        do {
            try await cmd.moveTab(sourceWorkspaceId: "ws-src", destWorkspaceId: "ws-dst", tabId: "only")
            XCTFail("expected moveTab to reject the last tab")
        } catch let WaveError.rpc(msg) {
            XCTAssertTrue(msg.contains("last tab"))
        }
        XCTAssertNil(transport.lastWshCommand) // never reached the wire
    }

    func testMoveTabSendsCommandWhenAllowed() async throws {
        let transport = MockTransport(); let store = MockStore()
        store.preset(.workspace(Workspace(oid: "ws-src", version: 1, tabids: ["a", "b"], activetabid: "a", meta: [:])))
        let cmd = makeCommands(transport, store)
        try await cmd.moveTab(sourceWorkspaceId: "ws-src", destWorkspaceId: "ws-dst", tabId: "a")
        XCTAssertEqual(transport.lastWshCommand, "movetab")
        let data = try XCTUnwrap(transport.lastWshData?.decode(CommandMoveTabData.self))
        XCTAssertEqual(data.sourceworkspaceid, "ws-src")
        XCTAssertEqual(data.destworkspaceid, "ws-dst")
        XCTAssertEqual(data.tabid, "a")
    }

    // MARK: MultiArg wsh commands

    func testUpdateWorkspaceTabIdsMultiArg() async throws {
        let transport = MockTransport(); let store = MockStore()
        let cmd = makeCommands(transport, store)
        try await cmd.updateWorkspaceTabIds(workspaceId: "ws-1", tabIds: ["t1", "t2", "t3"])
        XCTAssertEqual(transport.lastWshCommand, "updateworkspacetabids")
        let data = try XCTUnwrap(transport.lastWshData)
        let args = try XCTUnwrap(data["args"]?.arrayValue)
        XCTAssertEqual(args[0], .string("ws-1"))
        XCTAssertEqual(args[1], .array([.string("t1"), .string("t2"), .string("t3")]))
    }

    func testUpdateTabNameMultiArg() async throws {
        let transport = MockTransport(); let store = MockStore()
        let cmd = makeCommands(transport, store)
        try await cmd.updateTabName(tabId: "tab-1", newName: "Renamed")
        XCTAssertEqual(transport.lastWshCommand, "updatetabname")
        let args = try XCTUnwrap(transport.lastWshData?["args"]?.arrayValue)
        XCTAssertEqual(args, [.string("tab-1"), .string("Renamed")])
    }

    // MARK: meta + advanced create over wshrpc

    func testSetMetaEncoding() async throws {
        let transport = MockTransport(); let store = MockStore()
        let cmd = makeCommands(transport, store)
        try await cmd.setMeta(.block("blk-1"), meta: ["url": .string("https://example.com")])
        XCTAssertEqual(transport.lastWshCommand, "setmeta")
        let data = try XCTUnwrap(transport.lastWshData?.decode(CommandSetMetaData.self))
        XCTAssertEqual(data.oref, ORef.block("blk-1"))
        XCTAssertEqual(data.meta["url"]?.stringValue, "https://example.com")
    }

    func testCreateBlockAdvancedReturnsORef() async throws {
        let transport = MockTransport(); let store = MockStore()
        transport.setNextRpcResponse(.string("block:blk-9"))
        let cmd = makeCommands(transport, store)
        let oref = try await cmd.createBlock(
            CommandCreateBlockData(tabid: "tab-1", magnified: true)
        )
        XCTAssertEqual(oref, ORef.block("blk-9"))
        XCTAssertEqual(transport.lastWshCommand, "createblock")
        let data = try XCTUnwrap(transport.lastWshData?.decode(CommandCreateBlockData.self))
        XCTAssertEqual(data.tabid, "tab-1")
        XCTAssertEqual(data.magnified, true)
    }

    // MARK: §0 error surface

    func testServiceErrorThrowsRpc() async throws {
        let transport = MockTransport(); let store = MockStore()
        transport.setNextWebReturn(WebReturnType(success: false, error: "boom"))
        let cmd = makeCommands(transport, store)
        do {
            _ = try await cmd.createWorkspace(name: "x")
            XCTFail("expected error")
        } catch let WaveError.rpc(msg) {
            XCTAssertTrue(msg.contains("boom"))
        }
    }
}
