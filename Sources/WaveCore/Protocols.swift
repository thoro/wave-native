// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveCore — cross-module Swift protocols (the contract every other module codes
// against). Placed in WaveCore so WaveProtocol, WaveStore, WaveCommands,
// WaveTerminal, WaveLayout, WaveWeb and WaveUI all import ONE definition.
//
// `WaveTransport`        : PROTOCOL.md §1 (spawn/connect/call/subscribe/reconnect),
//                          GUARDS §A (auth header, asym framing, ping/pong,
//                          stableid, route-announce + re-subscribe on reconnect).
// `ObjectStoreProtocol`  : PROTOCOL.md §2 (load/subscribe/merge/applyUpdates),
//                          GUARDS §B (version-guarded merge, apply inline updates).

import Foundation

// MARK: - Subscription handle

/// A live subscription. Cancel to stop receiving callbacks. Idempotent.
public final class SubscriptionToken: @unchecked Sendable {
    public let id: String
    private let onCancel: @Sendable () -> Void
    private var cancelled = false
    private let lock = NSLock()

    public init(id: String = UUID().uuidString, onCancel: @escaping @Sendable () -> Void) {
        self.id = id
        self.onCancel = onCancel
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return }
        cancelled = true
        onCancel()
    }

    deinit { cancel() }
}

// MARK: - Transport (PROTOCOL.md §1)

/// The wavesrv transport: spawns the child process, owns the WebSocket + HTTP
/// service connections, and multiplexes wshrpc requests/responses and events.
///
/// Implementations MUST uphold GUARDS §A: send `X-AuthKey` on the WS upgrade and
/// every `/wave/*` call; frame outbound as `WSRpcCommand` and parse inbound as
/// `WSRpcEvent`; answer `WSPing` with `WSPong` within 15s; pass
/// `?stableid=<routeId>`; and on every (re)connect send a `routeannounce` to
/// `$control` and re-subscribe all events BEFORE issuing routed calls.
public protocol WaveTransport: AnyObject, Sendable {
    /// The discovered server addresses (nil until `spawn` succeeds).
    var addrs: ServerAddrs? { get }
    /// The route id this client announced (e.g. `window:<windowId>`).
    var routeId: String? { get }
    /// True once the WS is connected and the route announced.
    var isConnected: Bool { get }

    /// Fired AFTER a successful RE-connect (never the first connect): the route has
    /// been re-announced and all events re-subscribed. Consumers use this to re-run
    /// catch-up backfill for bytes produced while the socket was down (gap G3).
    var onReconnect: (@Sendable () -> Void)? { get set }

    /// Spawn `wavesrv` with the given env (must include a fresh random
    /// `WAVETERM_AUTH_KEY`, GUARDS §P), parse `WAVESRV-ESTART`, and return addrs.
    func spawn(env: [String: String]) async throws -> ServerAddrs

    /// Open the WS (`ws://<wsAddr>/ws?stableid=<routeId>`), start ping/pong, send
    /// the initial `routeannounce` to `$control`.
    func connect(routeId: String) async throws

    /// Re-establish a dropped WS. Implementations MUST re-announce the route and
    /// re-subscribe all active subscriptions (GUARDS §A).
    func reconnect() async throws

    /// Tear down the WS (does not kill the wavesrv process).
    func disconnect()

    /// Issue a wshrpc request expecting a single typed response. Matches the
    /// reply by `resid == reqid`; completes on the first non-`cont` reply.
    /// `route` defaults to `WaveRoute.defaultRoute`; `timeoutMs` defaults to
    /// `WaveProtocolConst.defaultTimeoutMs`.
    func call<Req: Encodable & Sendable, Res: Decodable & Sendable>(
        command: String,
        data: Req?,
        route: String?,
        timeoutMs: Int64?
    ) async throws -> Res

    /// Issue a wshrpc request that returns no payload (just success/error).
    func callVoid<Req: Encodable & Sendable>(
        command: String,
        data: Req?,
        route: String?,
        timeoutMs: Int64?
    ) async throws

    /// Issue a fire-and-forget wshrpc message (no `reqid`, no response awaited).
    func notify<Req: Encodable & Sendable>(
        command: String,
        data: Req?,
        route: String?
    ) throws

    /// Issue a streaming wshrpc request. The handler is invoked for each chunk;
    /// the stream completes (token auto-cancels) on the first non-`cont` reply or
    /// an error. Cancel the token to send a `cancel:true` upstream.
    func stream<Req: Encodable & Sendable>(
        command: String,
        data: Req?,
        route: String?,
        onChunk: @escaping @Sendable (Result<RpcMessage, WaveError>) -> Void
    ) throws -> SubscriptionToken

    /// POST a `WebCallType` to `/wave/service`. Callers MUST feed the returned
    /// `updates` into the object store (GUARDS §B).
    func callService(_ call: WebCallType) async throws -> WebReturnType

    /// HTTP GET file backfill: `/wave/file?zoneid=&name=&offset=`. Returns the raw
    /// bytes plus the decoded `X-ZoneFileInfo` `WaveFile` (PROTOCOL §4 / GUARDS §T).
    func fetchFile(zoneId: String, name: String, offset: Int64) async throws -> (data: Data, info: WaveFile)

    /// HTTP GET a byte/line range of a wave file (`/wave/file` with `count`,
    /// `tail`, or `startline`/`numlines`). Used by the terminal history layer
    /// for tail backfills and paged scrollback chunks. A default implementation
    /// throws; real transports override it.
    func fetchFileRange(zoneId: String, name: String, range: FileFetchRange) async throws -> FileFetchResult

    /// Subscribe to a WPS event (sends `EventSubCommand`). GUARDS §B: `scopes`
    /// are oref strings. The subscription is re-registered automatically across
    /// reconnects until the token is cancelled.
    func subscribe(
        _ request: SubscriptionRequest,
        handler: @escaping @Sendable (WaveEvent) -> Void
    ) -> SubscriptionToken
}

/// Selects the byte range of a `fetchFileRange` GET. Exactly one addressing
/// mode applies: line-addressed (`startLine`+`numLines`) wins over `tail`,
/// which wins over `offset`(+`count`) -- mirroring `pkg/web/web.go`.
public struct FileFetchRange: Sendable {
    public var offset: Int64
    public var count: Int64?
    public var tail: Int64?
    public var startLine: Int64?
    public var numLines: Int64?
    /// Stream the range as ANSI-stripped plain text (one line per logical
    /// line) instead of raw VT bytes -- the full-buffer copy path.
    public var stripAnsi: Bool

    public init(offset: Int64 = 0, count: Int64? = nil, tail: Int64? = nil,
                startLine: Int64? = nil, numLines: Int64? = nil, stripAnsi: Bool = false) {
        self.offset = offset
        self.count = count
        self.tail = tail
        self.startLine = startLine
        self.numLines = numLines
        self.stripAnsi = stripAnsi
    }

    public static func tail(_ bytes: Int64) -> FileFetchRange {
        FileFetchRange(tail: bytes)
    }

    public static func bytes(offset: Int64, count: Int64) -> FileFetchRange {
        FileFetchRange(offset: offset, count: count)
    }

    public static func lines(start: Int64, count: Int64) -> FileFetchRange {
        FileFetchRange(startLine: start, numLines: count)
    }
}

/// Result of a ranged file GET. `startOffset` is the absolute byte offset the
/// body begins at (server-resolved: clamped offset, tail start, or line start).
public struct FileFetchResult: Sendable {
    public var data: Data
    public var info: WaveFile
    public var startOffset: Int64
    /// For line-addressed and tail fetches: the retained-relative line number
    /// the body starts at (from `X-WaveLineInfo`).
    public var startLine: Int64?
    /// For line-addressed and tail fetches: the file's total flushed line count.
    public var totalLines: Int64?

    public init(data: Data, info: WaveFile, startOffset: Int64,
                startLine: Int64? = nil, totalLines: Int64? = nil) {
        self.data = data
        self.info = info
        self.startOffset = startOffset
        self.startLine = startLine
        self.totalLines = totalLines
    }
}

public extension WaveTransport {
    /// `call` with default route + timeout.
    func call<Req: Encodable & Sendable, Res: Decodable & Sendable>(
        command: String, data: Req?
    ) async throws -> Res {
        try await call(command: command, data: data, route: nil, timeoutMs: nil)
    }

    /// `callVoid` with default route + timeout.
    func callVoid<Req: Encodable & Sendable>(command: String, data: Req?) async throws {
        try await callVoid(command: command, data: data, route: nil, timeoutMs: nil)
    }

    /// Default so non-HTTP transports/test doubles compile; real transports
    /// (HTTP-backed) override.
    func fetchFileRange(zoneId: String, name: String, range: FileFetchRange) async throws -> FileFetchResult {
        throw WaveError.transport("fetchFileRange is not supported by this transport")
    }
}

// MARK: - Object store (PROTOCOL.md §2)

/// The oref-keyed object cache. Loads via HTTP `GetObject(s)`, stays live via the
/// `waveobj:update` event, and applies inline `updates` from every service call.
///
/// Implementations MUST uphold GUARDS §B: version-guarded merge (drop any update
/// whose `version <= cached.version`); apply `WebReturnType.updates` from every
/// service response into the SAME cache used by events.
public protocol ObjectStoreProtocol: AnyObject, Sendable {
    /// Return the cached object for `oref`, or nil if not loaded.
    func get(_ oref: ORef) -> AnyWaveObj?

    /// Load `oref` (HTTP `ObjectService.GetObject`), caching the result.
    func load(_ oref: ORef) async throws -> AnyWaveObj

    /// Batch load (HTTP `ObjectService.GetObjects`).
    func loadMany(_ orefs: [ORef]) async throws -> [AnyWaveObj]

    /// Version-guarded merge of a single object into the cache (GUARDS §B).
    /// Returns true if the object was applied, false if dropped as stale.
    @discardableResult
    func merge(_ obj: AnyWaveObj) -> Bool

    /// Apply a batch of `WaveObjUpdate`s (handles both `update` and `delete`,
    /// version-guarded). Use this for both event payloads and the inline
    /// `WebReturnType.updates` (GUARDS §B).
    func applyUpdates(_ updates: [WaveObjUpdate])

    /// Subscribe to changes for a single object. The handler fires on every
    /// applied merge/delete for `oref`. Cancel the token to unsubscribe.
    func subscribe(
        _ oref: ORef,
        handler: @escaping @Sendable (AnyWaveObj?) -> Void
    ) -> SubscriptionToken
}
