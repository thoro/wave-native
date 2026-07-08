// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// E2E harness — a transparent recording decorator over the REAL transport.
//
// This is NOT a mock of wavesrv: every call is forwarded to a real
// `WaveTransportClient` that talks to a real `wavesrv` (docs/E2E.md "What is NOT
// mocked"). The decorator only *observes* which RPCs the chrome issues, so the
// E2E-7 gate can assert "each tab/workspace action maps to the right RPC" while
// the bytes still go to the live server.
//
// One thing it intercepts: `spawn`. The `WaveServerProcess` harness already owns
// (and can SIGTERM) the wavesrv child, so `spawn` here injects that running
// server into the wrapped client via `_configureServerForTesting` instead of
// launching a second process. The auth key it asserts on the env keeps GUARDS §P
// coverage; the key actually used on the wire is the harness server's key (so it
// matches the server that is running).

import Foundation
import XCTest
import WaveCore
@testable import WaveProtocol

final class RecordingTransport: WaveTransport, @unchecked Sendable {
    private let real: WaveTransportClient
    private let server: WaveServerProcess

    private let lock = NSLock()
    private var _serviceCalls: [(service: String, method: String)] = []
    private var _commands: [String] = []

    init(real: WaveTransportClient, server: WaveServerProcess) {
        self.real = real
        self.server = server
    }

    // MARK: Recorded observations

    func serviceCalls() -> [(service: String, method: String)] {
        lock.lock(); defer { lock.unlock() }; return _serviceCalls
    }

    func commands() -> [String] {
        lock.lock(); defer { lock.unlock() }; return _commands
    }

    func didCallService(_ method: String) -> Bool {
        serviceCalls().contains { $0.method == method }
    }

    func serviceCallCount(_ method: String) -> Int {
        serviceCalls().filter { $0.method == method }.count
    }

    func didSendCommand(_ command: String) -> Bool {
        commands().contains(command)
    }

    private func recordService(_ call: WebCallType) {
        lock.lock(); _serviceCalls.append((call.service, call.method)); lock.unlock()
    }

    private func recordCommand(_ command: String) {
        lock.lock(); _commands.append(command); lock.unlock()
    }

    // MARK: WaveTransport — read-only state (pass-through)

    var addrs: ServerAddrs? { real.addrs }
    var routeId: String? { real.routeId }
    var isConnected: Bool { real.isConnected }
    var onReconnect: (@Sendable () -> Void)? {
        get { real.onReconnect }
        set { real.onReconnect = newValue }
    }

    // MARK: spawn — inject the harness-owned server (no second process)

    func spawn(env: [String: String]) async throws -> ServerAddrs {
        // GUARDS §P: the coordinator must still hand us a fresh auth key in env.
        XCTAssertNotNil(env[WaveProtocolConst.authKeyEnv],
                        "GUARDS §P: spawn env must carry \(WaveProtocolConst.authKeyEnv)")
        // Use the running harness server's addrs + key so the wire auth matches.
        real._configureServerForTesting(addrs: server.addrs, authKey: server.authKey)
        return server.addrs
    }

    // MARK: connect / lifecycle (pass-through)

    func connect(routeId: String) async throws { try await real.connect(routeId: routeId) }
    func reconnect() async throws { try await real.reconnect() }
    func disconnect() { real.disconnect() }

    // MARK: RPC (record command, forward)

    func call<Req: Encodable & Sendable, Res: Decodable & Sendable>(
        command: String, data: Req?, route: String?, timeoutMs: Int64?
    ) async throws -> Res {
        recordCommand(command)
        return try await real.call(command: command, data: data, route: route, timeoutMs: timeoutMs)
    }

    func callVoid<Req: Encodable & Sendable>(
        command: String, data: Req?, route: String?, timeoutMs: Int64?
    ) async throws {
        recordCommand(command)
        try await real.callVoid(command: command, data: data, route: route, timeoutMs: timeoutMs)
    }

    func notify<Req: Encodable & Sendable>(command: String, data: Req?, route: String?) throws {
        recordCommand(command)
        try real.notify(command: command, data: data, route: route)
    }

    func stream<Req: Encodable & Sendable>(
        command: String, data: Req?, route: String?,
        onChunk: @escaping @Sendable (Result<RpcMessage, WaveError>) -> Void
    ) throws -> SubscriptionToken {
        recordCommand(command)
        return try real.stream(command: command, data: data, route: route, onChunk: onChunk)
    }

    // MARK: HTTP service / file (record, forward)

    func callService(_ call: WebCallType) async throws -> WebReturnType {
        recordService(call)
        return try await real.callService(call)
    }

    func fetchFile(zoneId: String, name: String, offset: Int64) async throws -> (data: Data, info: WaveFile) {
        try await real.fetchFile(zoneId: zoneId, name: name, offset: offset)
    }

    // MARK: events (pass-through)

    func subscribe(
        _ request: SubscriptionRequest, handler: @escaping @Sendable (WaveEvent) -> Void
    ) -> SubscriptionToken {
        real.subscribe(request, handler: handler)
    }
}
