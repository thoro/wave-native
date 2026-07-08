// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveStore unit tests — encode the PROTOCOL.md §2 / GUARDS §B object-store
// contract without a live wavesrv:
//   • version-guarded merge (drop obj.version <= cached.version)            §B
//   • apply inline WebReturnType.updates from a service call into the cache §B
//   • out-of-order update delivery converges to the highest version        §B
//   • deletes are applied unconditionally (no version guard, FE parity)
//   • per-oref observers + WPS waveobj:update event wiring
//   • subscription scope is the oref STRING, not a bare id                  §B
//
// Uses a MockTransport (a WaveCore.WaveTransport) that returns canned service
// responses and lets the test fire WPS events.

import XCTest
@testable import WaveCore
@testable import WaveStore

// MARK: - Test doubles

/// A thread-safe accumulator for @Sendable observer callbacks.
private final class Recorder<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ value: T) {
        lock.lock(); defer { lock.unlock() }
        items.append(value)
    }

    var values: [T] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

/// A minimal `WaveTransport` for store tests. Only `callService` and `subscribe`
/// are exercised; everything else throws/no-ops.
private final class MockTransport: WaveTransport, @unchecked Sendable {
    private let lock = NSLock()

    // Canned service response (or a handler to compute one per call).
    var serviceHandler: (@Sendable (WebCallType) -> WebReturnType)?

    // Captured subscriptions: scope-string -> live event handler.
    private var subHandlers: [String: @Sendable (WaveEvent) -> Void] = [:]
    private(set) var lastSubscriptionRequest: SubscriptionRequest?

    var addrs: ServerAddrs? { nil }
    var routeId: String? { "window:test" }
    var isConnected: Bool { true }
    var onReconnect: (@Sendable () -> Void)?

    func spawn(env: [String: String]) async throws -> ServerAddrs { throw WaveError.notConnected }
    func connect(routeId: String) async throws { throw WaveError.notConnected }
    func reconnect() async throws { throw WaveError.notConnected }
    func disconnect() {}

    func call<Req: Encodable & Sendable, Res: Decodable & Sendable>(
        command: String, data: Req?, route: String?, timeoutMs: Int64?
    ) async throws -> Res { throw WaveError.notConnected }

    func callVoid<Req: Encodable & Sendable>(
        command: String, data: Req?, route: String?, timeoutMs: Int64?
    ) async throws { throw WaveError.notConnected }

    func notify<Req: Encodable & Sendable>(command: String, data: Req?, route: String?) throws {}

    func stream<Req: Encodable & Sendable>(
        command: String, data: Req?, route: String?,
        onChunk: @escaping @Sendable (Result<RpcMessage, WaveError>) -> Void
    ) throws -> SubscriptionToken { SubscriptionToken {} }

    func callService(_ call: WebCallType) async throws -> WebReturnType {
        guard let handler = serviceHandler else { throw WaveError.notConnected }
        return handler(call)
    }

    func fetchFile(zoneId: String, name: String, offset: Int64) async throws -> (data: Data, info: WaveFile) {
        throw WaveError.notConnected
    }

    func subscribe(
        _ request: SubscriptionRequest,
        handler: @escaping @Sendable (WaveEvent) -> Void
    ) -> SubscriptionToken {
        lock.lock()
        lastSubscriptionRequest = request
        let scopes = request.scopes ?? []
        for scope in scopes {
            subHandlers[scope] = handler
        }
        lock.unlock()
        return SubscriptionToken { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            for scope in scopes { self.subHandlers.removeValue(forKey: scope) }
        }
    }

    /// Drive a WPS event to every handler subscribed to a matching scope.
    func emit(_ event: WaveEvent) {
        let handlers: [@Sendable (WaveEvent) -> Void] = {
            lock.lock(); defer { lock.unlock() }
            return (event.scopes ?? []).compactMap { subHandlers[$0] }
        }()
        for handler in handlers { handler(event) }
    }
}

// MARK: - Builders

private func makeBlock(_ oid: String, _ version: Int, view: String? = nil) -> AnyWaveObj {
    var meta: MetaMapType = [:]
    if let view { meta["view"] = .string(view) }
    return .block(Block(oid: oid, version: version, meta: meta))
}

/// A JSON `obj` payload for a `block` WaveObjUpdate (carries the embedded `otype`).
private func blockObjJSON(_ oid: String, _ version: Int) -> JSONValue {
    .object([
        "otype": .string("block"),
        "oid": .string(oid),
        "version": .int(Int64(version)),
        "meta": .object([:]),
    ])
}

private func blockUpdate(_ oid: String, _ version: Int) -> WaveObjUpdate {
    WaveObjUpdate(updatetype: updateTypeUpdate, otype: "block", oid: oid, obj: blockObjJSON(oid, version))
}

// MARK: - Tests

final class WaveStoreTests: XCTestCase {

    private func makeStore() -> (ObjectStore, MockTransport) {
        let transport = MockTransport()
        return (ObjectStore(transport: transport), transport)
    }

    // GUARDS §B — version-guarded merge.

    func testVersionGuardedMerge() {
        let (store, _) = makeStore()
        let oref = ORef.block("b1")

        XCTAssertTrue(store.merge(makeBlock("b1", 2)))
        XCTAssertEqual(store.get(oref)?.version, 2)

        // A stale (lower) version is dropped.
        XCTAssertFalse(store.merge(makeBlock("b1", 1)))
        XCTAssertEqual(store.get(oref)?.version, 2)

        // An equal version is dropped (guard is "<="), preventing flicker.
        XCTAssertFalse(store.merge(makeBlock("b1", 2)))
        XCTAssertEqual(store.get(oref)?.version, 2)

        // A higher version applies.
        XCTAssertTrue(store.merge(makeBlock("b1", 3)))
        XCTAssertEqual(store.get(oref)?.version, 3)
    }

    // GUARDS §B — applyUpdates decodes + version-guards.

    func testApplyUpdatesApplied() {
        let (store, _) = makeStore()
        let oref = ORef.block("b2")

        store.applyUpdates([blockUpdate("b2", 1)])
        XCTAssertEqual(store.get(oref)?.version, 1)

        store.applyUpdates([blockUpdate("b2", 3)])
        XCTAssertEqual(store.get(oref)?.version, 3)

        // Out-of-order late v2 is dropped.
        store.applyUpdates([blockUpdate("b2", 2)])
        XCTAssertEqual(store.get(oref)?.version, 3)
    }

    // GUARDS §B — out-of-order delivery converges to highest version.

    func testOutOfOrderDeliveryConverges() {
        let (store, _) = makeStore()
        let oref = ORef.block("b3")

        store.applyUpdates([blockUpdate("b3", 5), blockUpdate("b3", 3), blockUpdate("b3", 4)])
        XCTAssertEqual(store.get(oref)?.version, 5)
    }

    // Deletes apply unconditionally (FE parity, wos.ts:263-266).

    func testDeleteRemovesUnconditionally() {
        let (store, _) = makeStore()
        let oref = ORef.block("b4")
        store.merge(makeBlock("b4", 9))
        XCTAssertNotNil(store.get(oref))

        store.applyUpdates([WaveObjUpdate(updatetype: updateTypeDelete, otype: "block", oid: "b4")])
        XCTAssertNil(store.get(oref))
    }

    // Per-oref observers fire on merge and delete.

    func testSubscribeNotifiesOnMergeAndDelete() {
        let (store, _) = makeStore()
        let oref = ORef.block("b5")
        let recorder = Recorder<Int?>()

        let token = store.subscribe(oref) { obj in recorder.append(obj?.version) }

        store.merge(makeBlock("b5", 1))
        store.merge(makeBlock("b5", 2))
        store.merge(makeBlock("b5", 2)) // dropped — no extra notification
        store.applyUpdates([WaveObjUpdate(updatetype: updateTypeDelete, otype: "block", oid: "b5")])

        XCTAssertEqual(recorder.values, [1, 2, nil])
        token.cancel()

        // After cancel, no further notifications.
        store.merge(makeBlock("b5", 3))
        XCTAssertEqual(recorder.values, [1, 2, nil])
    }

    // GUARDS §B — subscription scope is the oref STRING; WPS events flow through.

    func testWPSEventAppliesAndNotifies() throws {
        let (store, transport) = makeStore()
        let oref = ORef.block("b6")
        let recorder = Recorder<Int?>()

        // Retain the token: a discarded SubscriptionToken deinits immediately and
        // cancels the subscription (RAII), tearing down the WPS sub before `emit`.
        let token = store.subscribe(oref) { obj in recorder.append(obj?.version) }
        defer { token.cancel() }

        XCTAssertEqual(transport.lastSubscriptionRequest?.event, WaveEventName.waveObjUpdate)
        XCTAssertEqual(transport.lastSubscriptionRequest?.scopes, [oref.string])
        XCTAssertEqual(oref.string, "block:b6") // scope is the oref string, not "b6"

        let eventData = try JSONValue.encode(blockUpdate("b6", 7))
        transport.emit(WaveEvent(event: WaveEventName.waveObjUpdate, scopes: [oref.string], data: eventData))

        XCTAssertEqual(store.get(oref)?.version, 7)
        XCTAssertEqual(recorder.values, [7])
    }

    // GUARDS §B — load() applies inline updates AND caches the returned object.

    func testLoadAppliesInlineUpdatesAndCaches() async throws {
        let (store, transport) = makeStore()
        let target = ORef.block("b7")
        let sibling = ORef.block("b8")

        transport.serviceHandler = { call in
            XCTAssertEqual(call.service, "object")
            XCTAssertEqual(call.method, "GetObject")
            return WebReturnType(
                success: true,
                data: blockObjJSON("b7", 4),
                updates: [blockUpdate("b8", 2)]
            )
        }

        let loaded = try await store.load(target)
        XCTAssertEqual(loaded.version, 4)
        XCTAssertEqual(store.get(target)?.version, 4)
        // The inline sibling update landed in the SAME cache.
        XCTAssertEqual(store.get(sibling)?.version, 2)
    }

    // load() surfaces a service-level error.

    func testLoadPropagatesServiceError() async {
        let (store, transport) = makeStore()
        transport.serviceHandler = { _ in WebReturnType(success: false, error: "boom") }
        do {
            _ = try await store.load(ORef.block("b9"))
            XCTFail("expected an error")
        } catch let WaveError.rpc(msg) {
            XCTAssertEqual(msg, "boom")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // loadMany() decodes an array payload and caches each element.

    func testLoadManyCachesAll() async throws {
        let (store, transport) = makeStore()
        transport.serviceHandler = { call in
            XCTAssertEqual(call.method, "GetObjects")
            return WebReturnType(
                success: true,
                data: .array([blockObjJSON("m1", 1), blockObjJSON("m2", 1)])
            )
        }
        let objs = try await store.loadMany([ORef.block("m1"), ORef.block("m2")])
        XCTAssertEqual(objs.count, 2)
        XCTAssertEqual(store.get(ORef.block("m1"))?.version, 1)
        XCTAssertEqual(store.get(ORef.block("m2"))?.version, 1)
    }
}
