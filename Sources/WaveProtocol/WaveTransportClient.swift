// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveProtocol — the concrete `WaveTransport` (conforms to WaveCore.WaveTransport).
//
// Implements PROTOCOL.md §1 (full transport/handshake) and GUARDS §A end-to-end:
//   - spawn wavesrv + ESTART discovery        (WaveProcess.swift, GUARDS §P)
//   - HTTP service client                      (HTTPServiceClient.swift, §0/§B/§T)
//   - WS connect with `?stableid=` + X-AuthKey  (GUARDS §A)
//   - ASYMMETRIC framing (WSRpcCommand out / WSRpcEvent in)  (WSFraming.swift)
//   - reqid/resid matching + cont streaming     (`pkg/wshutil/wshrpc.go:381-447`)
//   - application ping -> pong within 15s        (`pkg/web/ws.go:148-177`)
//   - routeannounce to $control on every (re)connect, BEFORE routed calls, and
//     re-subscribe ALL events after reconnect    (`frontend/app/store/wshrouter.ts:134-148`,
//                                                  `frontend/app/store/wshrpcutil.ts:24-26`)
//   - WebReturnType.updates surfaced to a delegate for the object cache (GUARDS §B)
//
// Concurrency: state is guarded by a single `NSLock`; no async work runs under the
// lock. Outbound frames go through a single serial AsyncStream consumer so FIFO
// ordering holds (routeannounce is always sent before subsequent routed calls).

import Foundation
import WaveCore

/// Receives the inline `WebReturnType.updates` from every HTTP service call so the
/// object store stays fresh after mutations (GUARDS §B).
public protocol WaveTransportUpdatesDelegate: AnyObject, Sendable {
    func transport(_ transport: WaveTransportClient, didReceive updates: [WaveObjUpdate])
}

/// Internal wshrpc command names this transport issues directly (the rest flow
/// through typed wrappers in WaveCommands). Matches the generated wshclient
/// command strings and `pkg/wshrpc/wshrpctypes_const.go`.
enum WaveRpcCommand {
    static let routeAnnounce = "routeannounce" // $control (`wshrpctypes_const.go:42`)
    static let eventSub = "eventsub" // wshclient.go:278
    static let eventUnsub = "eventunsub" // wshclient.go:284
    static let eventRecv = "eventrecv" // server->client delivery (`wshrpctypes_const.go:46`)
}

public final class WaveTransportClient: WaveCore.WaveTransport, @unchecked Sendable {
    // MARK: Configuration (immutable)

    private let wavesrvPath: String
    private let arguments: [String]
    private let channelFactory: WSChannelFactory
    private let session: URLSession
    private let estartTimeoutMs: Int64

    /// Backoff for auto-reconnect attempts, in milliseconds, keyed by attempt #
    /// (1-based). Overridable for tests (set to 0 for instant reconnect).
    var reconnectDelayProvider: @Sendable (Int) -> UInt64 = { attempt in
        let ladder: [UInt64] = [0, 0, 250, 500, 1000, 2000, 5000]
        return attempt < ladder.count ? ladder[attempt] : 10000
    }

    // MARK: Mutable state (guarded by `lock`)

    private let lock = NSLock()
    private var _addrs: ServerAddrs?
    private var _routeId: String?
    private var _authKey: String?
    private var _connected = false
    private var process: Process?
    private var http: HTTPServiceClient?

    private var channel: WSChannel?
    private var receiveTask: Task<Void, Never>?
    private var outboundTask: Task<Void, Never>?
    private var outboundContinuation: AsyncStream<Data>.Continuation?

    private var intentionalDisconnect = false
    private var reconnecting = false
    private var hasConnectedOnce = false
    private var _onReconnect: (@Sendable () -> Void)?

    private var pending: [String: PendingCall] = [:]
    private var subs: [String: SubEntry] = [:]
    private weak var _updatesDelegate: WaveTransportUpdatesDelegate?

    // MARK: Init

    public init(
        wavesrvPath: String,
        arguments: [String] = [],
        channelFactory: WSChannelFactory = DefaultWSChannelFactory(),
        session: URLSession = .shared,
        estartTimeoutMs: Int64 = 10000
    ) {
        self.wavesrvPath = wavesrvPath
        self.arguments = arguments
        self.channelFactory = channelFactory
        self.session = session
        self.estartTimeoutMs = estartTimeoutMs
    }

    /// The delegate that receives inline `WebReturnType.updates` (GUARDS §B).
    public var updatesDelegate: WaveTransportUpdatesDelegate? {
        get { lock.lock(); defer { lock.unlock() }; return _updatesDelegate }
        set { lock.lock(); defer { lock.unlock() }; _updatesDelegate = newValue }
    }

    // MARK: WaveTransport — read-only state

    public var addrs: ServerAddrs? { lock.lock(); defer { lock.unlock() }; return _addrs }
    public var routeId: String? { lock.lock(); defer { lock.unlock() }; return _routeId }
    public var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return _connected }

    public var onReconnect: (@Sendable () -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onReconnect }
        set { lock.lock(); defer { lock.unlock() }; _onReconnect = newValue }
    }

    // MARK: WaveTransport — spawn / discovery (GUARDS §P)

    public func spawn(env: [String: String]) async throws -> ServerAddrs {
        // GUARDS §P: the auth key MUST be present in the env we hand wavesrv; we
        // also need it for the WS upgrade + every HTTP call (GUARDS §A).
        guard let authKey = env[WaveProtocolConst.authKeyEnv], !authKey.isEmpty else {
            throw WaveError.spawnFailed("env missing \(WaveProtocolConst.authKeyEnv) (GUARDS §P)")
        }
        let dataHome = env[WaveProtocolConst.dataHomeEnv].flatMap { $0.isEmpty ? nil : $0 }

        // Serialize the discover-or-spawn decision across concurrent app instances
        // sharing one data home so we never start two wavesrv for the same database.
        var instanceLock: WaveServerLock?
        if let dataHome {
            instanceLock = await WaveServerLock.acquire(dataHome: dataHome)
        }
        defer { instanceLock?.release() }

        // SEAMLESS UPGRADE: attach to a still-running wavesrv we spawned earlier
        // (its PTYs/scrollback survive the app restart) instead of spawning a fresh
        // one. Falls through to a fresh spawn if there is no live/healthy server.
        if let dataHome, let attached = await attachToRunningServer(dataHome: dataHome) {
            return attached
        }

        let (addrs, process) = try await WaveProcessLauncher.launch(
            path: wavesrvPath, env: env, arguments: arguments, timeoutMs: estartTimeoutMs)
        let httpClient = HTTPServiceClient(addrs: addrs, authKey: authKey, session: session)
        lock.lock()
        _addrs = addrs
        _authKey = authKey
        self.process = process
        http = httpClient
        lock.unlock()

        // Persist the descriptor so the NEXT app launch can discover + attach to
        // this (detached) wavesrv. Best-effort: a missing descriptor just means the
        // next launch spawns fresh.
        if let dataHome {
            let version = env[WaveProtocolConst.nativeVersionEnv].flatMap { $0.isEmpty ? nil : $0 }
            WaveServerDescriptor.write(
                RunningServerDescriptor(
                    wsaddr: addrs.wsAddr, webaddr: addrs.webAddr,
                    authkey: authKey, pid: process.processIdentifier, version: version),
                dataHome: dataHome)
        }
        return addrs
    }

    /// Try to attach to the wavesrv recorded in `<dataHome>/wavesrv-running.json`.
    /// Returns its addrs (and installs the HTTP client) only if the pid is alive AND
    /// a probe round-trips with the persisted auth key; otherwise clears the stale
    /// descriptor and returns nil so the caller spawns fresh. We deliberately do NOT
    /// set `self.process` here — we did not start this server and must never kill it.
    private func attachToRunningServer(dataHome: String) async -> ServerAddrs? {
        guard let desc = WaveServerDescriptor.read(dataHome: dataHome) else { return nil }
        guard WaveServerDescriptor.isAlive(pid: desc.pid) else {
            WaveServerDescriptor.remove(dataHome: dataHome)
            return nil
        }
        let addrs = desc.addrs
        let httpClient = HTTPServiceClient(addrs: addrs, authKey: desc.authkey, session: session)
        guard await Self.serverHealthy(httpClient) else {
            // pid alive but socket refused / auth rejected / server wedged: stale.
            WaveServerDescriptor.remove(dataHome: dataHome)
            return nil
        }
        lock.lock()
        _addrs = addrs
        _authKey = desc.authkey
        http = httpClient
        lock.unlock()
        return addrs
    }

    /// Health + auth probe for an attach candidate: a `client.GetClientData` call
    /// reaches the web addr AND validates the auth key. Wrapped in a short timeout
    /// so a wedged/half-dead server can't stall app launch. Any throw/timeout/error
    /// reply => not healthy.
    private static func serverHealthy(_ client: HTTPServiceClient) async -> Bool {
        let probe = WebCallType(service: "client", method: "GetClientData", args: [])
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                guard let ret = try? await client.callService(probe) else { return false }
                return ret.success != false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    // MARK: WaveTransport — connect / reconnect / disconnect (GUARDS §A)

    public func connect(routeId: String) async throws {
        lock.lock()
        _routeId = routeId
        intentionalDisconnect = false
        lock.unlock()
        try await establish()
    }

    public func reconnect() async throws {
        lock.lock()
        intentionalDisconnect = false
        lock.unlock()
        teardownChannel()
        try await establish()
    }

    public func disconnect() {
        lock.lock()
        intentionalDisconnect = true
        lock.unlock()
        teardownChannel()
        // Fail any in-flight requests so awaiting callers don't hang forever.
        let inflight = drainPending()
        for pc in inflight {
            pc.timeoutTask?.cancel()
            pc.handler(.failure(.notConnected))
        }
    }

    /// Open the socket, install the outbound/inbound plumbing, then (GUARDS §A)
    /// announce the route to `$control` and re-subscribe all events BEFORE the
    /// caller issues any routed call.
    private func establish() async throws {
        lock.lock()
        let addrs = _addrs
        let authKey = _authKey
        let routeId = _routeId
        lock.unlock()
        guard let addrs, let authKey, let routeId else {
            throw WaveError.notConnected
        }
        guard let url = URL(string: addrs.wsURL(stableId: routeId)) else {
            throw WaveError.transport("bad ws url for \(addrs.wsAddr)")
        }

        // Drop any prior plumbing first (reconnect path).
        teardownChannel()

        let newChannel = try await channelFactory.connect(url: url, authKey: authKey)

        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        let outTask = Task { [weak self] in
            for await data in stream {
                if Task.isCancelled { break }
                do {
                    try await newChannel.send(data)
                } catch {
                    self?.handleConnectionLost(newChannel)
                    break
                }
            }
        }
        let recvTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop(newChannel)
        }

        // Install the channel + outbound queue, but keep `_connected` false so no
        // user `call`/`callVoid` frame can be enqueued yet (registerAndSend gates
        // on `_connected`). The announce/eventsub frames below go straight to the
        // queue, guaranteeing routeannounce is on the wire BEFORE any routed call
        // (GUARDS §A) regardless of concurrent callers.
        lock.lock()
        channel = newChannel
        outboundContinuation = continuation
        outboundTask = outTask
        receiveTask = recvTask
        lock.unlock()

        // GUARDS §A: announce BEFORE any routed call, then re-subscribe everything.
        announceRoute(routeId: routeId)
        resubscribeAll()

        lock.lock()
        _connected = true
        let wasReconnect = hasConnectedOnce
        hasConnectedOnce = true
        let onReconnect = _onReconnect
        lock.unlock()

        // Fire the reconnect hook OFF the lock, and only for an actual RE-connect
        // (gap G3): the first establish() must not trigger catch-up backfill.
        if wasReconnect {
            onReconnect?()
        }
    }

    private func teardownChannel() {
        lock.lock()
        let ch = channel
        let rt = receiveTask
        let ot = outboundTask
        let cont = outboundContinuation
        channel = nil
        receiveTask = nil
        outboundTask = nil
        outboundContinuation = nil
        _connected = false
        lock.unlock()

        cont?.finish()
        rt?.cancel()
        ot?.cancel()
        ch?.close()
    }

    // MARK: Receive loop + inbound dispatch

    private func receiveLoop(_ ch: WSChannel) async {
        while true {
            if Task.isCancelled { return }
            do {
                let data = try await ch.receive()
                handleInbound(data, channel: ch)
            } catch {
                handleConnectionLost(ch)
                return
            }
        }
    }

    private func handleInbound(_ data: Data, channel ch: WSChannel) {
        guard let frame = try? WSFraming.decodeInbound(data) else { return }
        switch frame {
        case .ping:
            // GUARDS §A: answer every ping with a pong (15s read deadline).
            if let pong = try? WSFraming.encodePong() {
                _ = enqueueData(pong)
            }
        case .pong:
            break
        case let .rpc(message):
            handleInboundRpc(message)
        case .unknown:
            break
        }
    }

    private func handleInboundRpc(_ message: RpcMessage) {
        // Event delivery (`eventrecv`) — fan out to subscribers (PROTOCOL §2).
        if let command = message.command, command == WaveRpcCommand.eventRecv {
            dispatchEvent(message.data)
            return
        }
        // Response to one of our requests — match by resid == reqid (GUARDS §A).
        if let resid = message.resid, !resid.isEmpty {
            completeRequest(resid: resid, message: message)
            return
        }
        // Server-initiated request we don't model (ignore for this client's scope).
    }

    private func handleConnectionLost(_ ch: WSChannel) {
        lock.lock()
        // Ignore stale notifications from a channel we've already replaced.
        guard channel === ch else { lock.unlock(); return }
        _connected = false
        let intentional = intentionalDisconnect
        lock.unlock()
        if intentional { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        lock.lock()
        if reconnecting || intentionalDisconnect {
            lock.unlock()
            return
        }
        reconnecting = true
        let provider = reconnectDelayProvider
        lock.unlock()

        Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while true {
                if self.isIntentional() {
                    self.setReconnecting(false)
                    return
                }
                attempt += 1
                let delayMs = provider(attempt)
                if delayMs > 0 {
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                }
                if self.isIntentional() {
                    self.setReconnecting(false)
                    return
                }
                do {
                    try await self.establish()
                    self.setReconnecting(false)
                    return
                } catch {
                    if attempt >= 50 {
                        self.setReconnecting(false)
                        return
                    }
                    continue
                }
            }
        }
    }

    // MARK: WaveTransport — RPC calls

    public func call<Req: Encodable & Sendable, Res: Decodable & Sendable>(
        command: String, data: Req?, route: String?, timeoutMs: Int64?
    ) async throws -> Res {
        let response = try await sendRequest(
            command: command, data: try encodeData(data), route: route, timeoutMs: timeoutMs)
        if let err = response.error, !err.isEmpty {
            throw WaveError.rpc(err)
        }
        let payload = response.data ?? .null
        do {
            return try payload.decode(Res.self)
        } catch {
            throw WaveError.decoding("call \(command) response: \(error)")
        }
    }

    public func callVoid<Req: Encodable & Sendable>(
        command: String, data: Req?, route: String?, timeoutMs: Int64?
    ) async throws {
        let response = try await sendRequest(
            command: command, data: try encodeData(data), route: route, timeoutMs: timeoutMs)
        if let err = response.error, !err.isEmpty {
            throw WaveError.rpc(err)
        }
    }

    public func notify<Req: Encodable & Sendable>(
        command: String, data: Req?, route: String?
    ) throws {
        lock.lock()
        let source = _routeId
        lock.unlock()
        let message = RpcMessage(
            command: command,
            route: route ?? WaveRoute.defaultRoute,
            source: source,
            data: try encodeData(data))
        guard enqueueFrame(message) else { throw WaveError.notConnected }
    }

    public func stream<Req: Encodable & Sendable>(
        command: String, data: Req?, route: String?,
        onChunk: @escaping @Sendable (Result<RpcMessage, WaveError>) -> Void
    ) throws -> SubscriptionToken {
        let reqid = UUID().uuidString
        lock.lock()
        let source = _routeId
        lock.unlock()
        let message = RpcMessage(
            command: command,
            reqid: reqid,
            timeout: WaveProtocolConst.defaultTimeoutMs,
            route: route ?? WaveRoute.defaultRoute,
            source: source,
            data: try encodeData(data))
        let pc = PendingCall(isStream: true, handler: onChunk)
        guard registerAndSend(reqid: reqid, pending: pc, message: message) else {
            throw WaveError.notConnected
        }
        return SubscriptionToken(id: reqid) { [weak self] in
            self?.cancelStream(reqid: reqid)
        }
    }

    /// Build, register, send a request and await its terminal reply.
    private func sendRequest(
        command: String, data: JSONValue?, route: String?, timeoutMs: Int64?
    ) async throws -> RpcMessage {
        let reqid = UUID().uuidString
        let timeout = timeoutMs ?? WaveProtocolConst.defaultTimeoutMs
        lock.lock()
        let source = _routeId
        lock.unlock()
        let message = RpcMessage(
            command: command,
            reqid: reqid,
            timeout: timeout,
            route: route ?? WaveRoute.defaultRoute,
            source: source,
            data: data)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RpcMessage, Error>) in
            let pc = PendingCall(isStream: false) { result in
                switch result {
                case let .success(m): cont.resume(returning: m)
                case let .failure(e): cont.resume(throwing: e)
                }
            }
            pc.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout)) * 1_000_000)
                self?.failPending(reqid: reqid, error: .timeout(reqid: reqid))
            }
            if !registerAndSend(reqid: reqid, pending: pc, message: message) {
                pc.timeoutTask?.cancel()
                cont.resume(throwing: WaveError.notConnected)
            }
        }
    }

    private func registerAndSend(reqid: String, pending pc: PendingCall, message: RpcMessage) -> Bool {
        lock.lock()
        guard _connected, let cont = outboundContinuation else {
            lock.unlock()
            return false
        }
        pending[reqid] = pc
        lock.unlock()
        if let data = try? WSFraming.encodeOutbound(message) {
            if case .terminated = cont.yield(data) {
                // queue already torn down
            } else {
                return true
            }
        }
        // Roll back registration if the send failed / queue was terminated.
        lock.lock()
        pending.removeValue(forKey: reqid)
        lock.unlock()
        return false
    }

    private func completeRequest(resid: String, message: RpcMessage) {
        lock.lock()
        guard let pc = pending[resid] else {
            lock.unlock()
            return
        }
        let result: Result<RpcMessage, WaveError>
        if let err = message.error, !err.isEmpty {
            result = .failure(.rpc(err))
        } else {
            result = .success(message)
        }
        let isError = message.error?.isEmpty == false

        if message.isContinuation && !isError {
            // GUARDS §A: a `cont:true` reply means "more chunks coming".
            if pc.isStream {
                // Streams deliver each chunk and keep the registration.
                lock.unlock()
                pc.handler(result)
            } else {
                // A plain call completes only on the first non-cont reply; ignore
                // any intermediate cont chunks.
                lock.unlock()
            }
            return
        }
        // Terminal reply (non-cont, or an error): complete + unregister.
        pending.removeValue(forKey: resid)
        lock.unlock()
        pc.timeoutTask?.cancel()
        pc.handler(result)
    }

    private func failPending(reqid: String, error: WaveError) {
        lock.lock()
        guard let pc = pending.removeValue(forKey: reqid) else {
            lock.unlock()
            return
        }
        lock.unlock()
        pc.timeoutTask?.cancel()
        pc.handler(.failure(error))
    }

    private func cancelStream(reqid: String) {
        lock.lock()
        let removed = pending.removeValue(forKey: reqid)
        let source = _routeId
        lock.unlock()
        guard removed != nil else { return } // already completed naturally
        // Tell the server to stop the stream (`cancel:true` with the same reqid).
        let cancelMsg = RpcMessage(reqid: reqid, route: WaveRoute.defaultRoute, source: source, cancel: true)
        _ = enqueueFrame(cancelMsg)
    }

    // MARK: WaveTransport — HTTP service / file (GUARDS §B/§T)

    public func callService(_ call: WebCallType) async throws -> WebReturnType {
        lock.lock()
        let client = http
        let delegate = _updatesDelegate
        lock.unlock()
        guard let client else { throw WaveError.notConnected }
        let ret = try await client.callService(call)
        // GUARDS §B: feed inline updates into the object cache via the delegate.
        if let updates = ret.updates, !updates.isEmpty {
            delegate?.transport(self, didReceive: updates)
        }
        if ret.success == false, let err = ret.error, !err.isEmpty {
            throw WaveError.rpc(err)
        }
        return ret
    }

    public func fetchFile(zoneId: String, name: String, offset: Int64) async throws -> (data: Data, info: WaveFile) {
        lock.lock()
        let client = http
        lock.unlock()
        guard let client else { throw WaveError.notConnected }
        return try await client.fetchFile(zoneId: zoneId, name: name, offset: offset)
    }

    public func fetchFileRange(zoneId: String, name: String, range: FileFetchRange) async throws -> FileFetchResult {
        lock.lock()
        let client = http
        lock.unlock()
        guard let client else { throw WaveError.notConnected }
        return try await client.fetchFileRange(zoneId: zoneId, name: name, range: range)
    }

    // MARK: WaveTransport — event subscriptions (GUARDS §A/§B)

    public func subscribe(
        _ request: SubscriptionRequest,
        handler: @escaping @Sendable (WaveEvent) -> Void
    ) -> SubscriptionToken {
        let id = UUID().uuidString
        lock.lock()
        subs[id] = SubEntry(request: request, handler: handler)
        lock.unlock()
        updateServerSubscription(forEvent: request.event)
        return SubscriptionToken(id: id) { [weak self] in
            self?.removeSubscription(id: id, request: request)
        }
    }

    private func removeSubscription(id: String, request: SubscriptionRequest) {
        lock.lock()
        let removed = subs.removeValue(forKey: id)
        lock.unlock()
        guard removed != nil else { return }
        updateServerSubscription(forEvent: request.event)
    }

    private func resubscribeAll() {
        // Called from the establish path (before `_connected` flips), so it must send
        // regardless of the connected flag — unlike `updateServerSubscription`.
        lock.lock()
        let events = Set(subs.values.map { $0.request.event })
        lock.unlock()
        for event in events {
            sendUnionEventSub(forEvent: event)
        }
    }

    /// Like `sendUnionEventSub` but only while connected (used when a local
    /// subscription is added/removed during steady state; the establish path uses
    /// `resubscribeAll` instead).
    private func updateServerSubscription(forEvent event: String) {
        lock.lock(); let connected = _connected; lock.unlock()
        guard connected else { return }
        sendUnionEventSub(forEvent: event)
    }

    /// Push the server-side subscription for `event` as the UNION of every local
    /// subscription's scopes. The broker REPLACES a route's scope set for a given
    /// (route, event) on each `eventsub` (`pkg/wps/wps.go:82` unsubscribe_nolock),
    /// so sending one eventsub per local subscription would clobber the others —
    /// only the last would receive events. Mirrors the FE's per-event scope union
    /// (`frontend/app/store/wps.ts`).
    private func sendUnionEventSub(forEvent event: String) {
        lock.lock()
        let entries = subs.values.filter { $0.request.event == event }
        lock.unlock()
        guard !entries.isEmpty else {
            let msg = RpcMessage(
                command: WaveRpcCommand.eventUnsub,
                route: WaveRoute.defaultRoute,
                source: routeId,
                data: try? JSONValue.encode(SubscriptionRequest(event: event)))
            _ = enqueueFrame(msg)
            return
        }
        // An allscopes sub (or a scopeless one, which delivers everything client-side)
        // means the server must send all of this event's updates.
        let anyAll = entries.contains { $0.request.allscopes == true || ($0.request.scopes?.isEmpty ?? true) }
        var scopeSet = Set<String>()
        for e in entries { scopeSet.formUnion(e.request.scopes ?? []) }
        let request = anyAll
            ? SubscriptionRequest(event: event, allscopes: true)
            : SubscriptionRequest(event: event, scopes: scopeSet.sorted())
        sendEventSub(request)
    }

    private func sendEventSub(_ request: SubscriptionRequest) {
        let msg = RpcMessage(
            command: WaveRpcCommand.eventSub,
            route: WaveRoute.defaultRoute,
            source: routeId,
            data: try? JSONValue.encode(request))
        _ = enqueueFrame(msg)
    }

    private func dispatchEvent(_ data: JSONValue?) {
        guard let data, !data.isNull, let event = try? data.decode(WaveEvent.self) else { return }
        lock.lock()
        let entries = subs.values.filter { $0.request.event == event.event }
        lock.unlock()
        for entry in entries {
            if shouldDeliver(event, to: entry.request) {
                entry.handler(event)
            }
        }
    }

    /// Mirror of the FE scope filter (`frontend/app/store/wps.ts:130-148`):
    /// `allscopes` => all; otherwise the event's scopes must include one of the
    /// subscription's scopes (oref strings, GUARDS §B). An empty/absent scope list
    /// on the subscription means "all events of this name".
    private func shouldDeliver(_ event: WaveEvent, to request: SubscriptionRequest) -> Bool {
        if request.allscopes == true { return true }
        guard let wanted = request.scopes, !wanted.isEmpty else { return true }
        return wanted.contains { event.hasScope($0) }
    }

    // MARK: Route announce (GUARDS §A)

    private func announceRoute(routeId: String) {
        // routeannounce: command="routeannounce", data=<routeId string>,
        // source=<routeId>, route=$control — fire-and-forget
        // (`frontend/app/store/wshrouter.ts:134-148`).
        let msg = RpcMessage(
            command: WaveRpcCommand.routeAnnounce,
            route: WaveRoute.controlRoute,
            source: routeId,
            data: .string(routeId))
        _ = enqueueFrame(msg)
    }

    // MARK: Outbound queue helpers

    private func enqueueFrame(_ message: RpcMessage) -> Bool {
        guard let data = try? WSFraming.encodeOutbound(message) else { return false }
        return enqueueData(data)
    }

    private func enqueueData(_ data: Data) -> Bool {
        lock.lock()
        let cont = outboundContinuation
        lock.unlock()
        guard let cont else { return false }
        if case .terminated = cont.yield(data) { return false }
        return true
    }

    private func encodeData<Req: Encodable & Sendable>(_ data: Req?) throws -> JSONValue? {
        guard let data else { return nil }
        do {
            return try JSONValue.encode(data)
        } catch {
            throw WaveError.decoding("request payload: \(error)")
        }
    }

    // MARK: Small locked accessors

    private func isIntentional() -> Bool {
        lock.lock(); defer { lock.unlock() }; return intentionalDisconnect
    }

    private func setReconnecting(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }; reconnecting = value
    }

    private func drainPending() -> [PendingCall] {
        lock.lock(); defer { lock.unlock() }
        let all = Array(pending.values)
        pending.removeAll()
        return all
    }

    // MARK: Test seam

    /// Inject discovered server state without spawning a real process. Used by the
    /// fake-socket reconnect tests (GUARDS §A). Not part of the public contract.
    func _configureServerForTesting(addrs: ServerAddrs, authKey: String) {
        let client = HTTPServiceClient(addrs: addrs, authKey: authKey, session: session)
        lock.lock()
        _addrs = addrs
        _authKey = authKey
        http = client
        lock.unlock()
    }
}

// MARK: - Supporting types

/// A registered in-flight request (single `call`/`callVoid` or a `stream`).
private final class PendingCall: @unchecked Sendable {
    let isStream: Bool
    let handler: @Sendable (Result<RpcMessage, WaveError>) -> Void
    var timeoutTask: Task<Void, Never>?

    init(isStream: Bool, handler: @escaping @Sendable (Result<RpcMessage, WaveError>) -> Void) {
        self.isStream = isStream
        self.handler = handler
    }
}

/// A registered event subscription (request + handler), kept across reconnects.
private struct SubEntry: Sendable {
    let request: SubscriptionRequest
    let handler: @Sendable (WaveEvent) -> Void
}
