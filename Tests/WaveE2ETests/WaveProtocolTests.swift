// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveProtocol unit tests — encode the transport GUARDS that are observable
// without a live wavesrv:
//   §A  ASYMMETRIC WS framing codec (WSRpcCommand out / WSRpcEvent in)
//   §A  ping -> pong reply
//   §A  reqid/resid request matching + cont streaming
//   §A  routeannounce to $control on connect, BEFORE routed calls
//   §A  re-announce + re-subscribe on (re)connect (explicit + auto-reconnect)
//   §B  WebReturnType-style event fan-out by scope
//   §P  WAVESRV-ESTART incremental stderr scan
//
// The socket is faked (`FakeWSChannel`) so reconnect/re-announce is deterministic.

import XCTest
@testable import WaveCore
@testable import WaveProtocol

final class WaveProtocolTests: XCTestCase {

    // MARK: GUARDS §A — framing codec

    func testEncodeOutboundIsWscommandRpc() throws {
        let data = try WSFraming.encodeOutbound(RpcMessage(command: "test", reqid: "r1"))
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["wscommand"] as? String, "rpc")
        XCTAssertNotNil(obj["message"])
        XCTAssertNil(obj["eventtype"])
    }

    func testDecodeInboundRpc() throws {
        let inbound = #"{"eventtype":"rpc","data":{"resid":"r1","data":{"ok":true}}}"#
        guard case let .rpc(msg) = try WSFraming.decodeInbound(Data(inbound.utf8)) else {
            return XCTFail("expected .rpc")
        }
        XCTAssertEqual(msg.resid, "r1")
    }

    func testDecodeInboundPingPong() throws {
        guard case let .ping(stime) = try WSFraming.decodeInbound(Data(#"{"type":"ping","stime":7}"#.utf8)) else {
            return XCTFail("expected .ping")
        }
        XCTAssertEqual(stime, 7)
        guard case .pong = try WSFraming.decodeInbound(Data(#"{"type":"pong"}"#.utf8)) else {
            return XCTFail("expected .pong")
        }
        let pong = try WSFraming.encodePong()
        let obj = try JSONSerialization.jsonObject(with: pong) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "pong")
    }

    func testDecodeInboundUnknownIsTolerated() throws {
        guard case .unknown = try WSFraming.decodeInbound(Data(#"{"something":1}"#.utf8)) else {
            return XCTFail("expected .unknown")
        }
    }

    // MARK: GUARDS §P — ESTART scanner

    func testEStartScannerAcrossChunks() {
        var scanner = EStartScanner()
        XCTAssertNil(scanner.feed(Data("some log noise\n".utf8)))
        XCTAssertNil(scanner.feed(Data("WAVESRV-ESTART ws:127.0.0.1:1".utf8))) // partial, no newline
        let result = scanner.feed(Data("234 web:127.0.0.1:5678 version:0.1 buildtime:0\n".utf8))
        guard case let .success(addrs)? = result else {
            return XCTFail("expected addrs")
        }
        XCTAssertEqual(addrs.wsAddr, "127.0.0.1:1234")
        XCTAssertEqual(addrs.webAddr, "127.0.0.1:5678")
    }

    func testEStartScannerIgnoresNonEStartLines() {
        var scanner = EStartScanner()
        XCTAssertNil(scanner.feed(Data("line one\nline two\n".utf8)))
    }

    // MARK: GUARDS §A — connect announces route BEFORE routed calls, then re-subscribes

    func testConnectAnnouncesAndSubscribes() async throws {
        let factory = FakeWSChannelFactory()
        let transport = WaveTransportClient(wavesrvPath: "/unused", channelFactory: factory)
        transport._configureServerForTesting(
            addrs: ServerAddrs(wsAddr: "127.0.0.1:1", webAddr: "127.0.0.1:2"), authKey: "k")

        // Subscribe BEFORE connecting: must be (re)sent on connect.
        let sub = transport.subscribe(SubscriptionRequest(event: "waveobj:update", scopes: ["workspace:w1"])) { _ in }
        defer { sub.cancel() }

        try await transport.connect(routeId: "window:win1")
        let ch = try XCTUnwrap(factory.channel(at: 0))

        let announcedAndSubscribed = await waitUntil { ch.commands().contains("routeannounce") && ch.commands().contains("eventsub") }
        XCTAssertTrue(announcedAndSubscribed)

        // GUARDS §A: routeannounce must precede the eventsub (ordering on the wire).
        let cmds = ch.commands()
        let announceIdx = try XCTUnwrap(cmds.firstIndex(of: "routeannounce"))
        let subIdx = try XCTUnwrap(cmds.firstIndex(of: "eventsub"))
        XCTAssertLessThan(announceIdx, subIdx)

        // routeannounce goes to $control with source == routeId and data == routeId.
        let announce = try XCTUnwrap(ch.message(command: "routeannounce"))
        XCTAssertEqual(announce.route, "$control")
        XCTAssertEqual(announce.source, "window:win1")
        XCTAssertEqual(announce.data?.stringValue, "window:win1")
    }

    func testReconnectReannouncesAndResubscribes() async throws {
        let factory = FakeWSChannelFactory()
        let transport = WaveTransportClient(wavesrvPath: "/unused", channelFactory: factory)
        transport._configureServerForTesting(
            addrs: ServerAddrs(wsAddr: "h:1", webAddr: "h:2"), authKey: "k")
        let sub = transport.subscribe(SubscriptionRequest(event: "blockfile", scopes: ["block:b1"])) { _ in }
        defer { sub.cancel() }

        try await transport.connect(routeId: "window:win1")
        let ch0 = try XCTUnwrap(factory.channel(at: 0))
        let ch0Ready = await waitUntil { ch0.commands().contains("routeannounce") && ch0.commands().contains("eventsub") }
        XCTAssertTrue(ch0Ready)

        try await transport.reconnect()
        let ch1 = try XCTUnwrap(factory.channel(at: 1))
        // GUARDS §A: a brand-new connection re-announces AND re-subscribes.
        let ch1Ready = await waitUntil { ch1.commands().contains("routeannounce") && ch1.commands().contains("eventsub") }
        XCTAssertTrue(ch1Ready)
        XCTAssertEqual(factory.count, 2)
    }

    func testAutoReconnectOnDropReannounces() async throws {
        let factory = FakeWSChannelFactory()
        let transport = WaveTransportClient(wavesrvPath: "/unused", channelFactory: factory)
        transport.reconnectDelayProvider = { _ in 0 } // instant for the test
        transport._configureServerForTesting(addrs: ServerAddrs(wsAddr: "h:1", webAddr: "h:2"), authKey: "k")
        let sub = transport.subscribe(SubscriptionRequest(event: "waveobj:update", scopes: ["workspace:w1"])) { _ in }
        defer { sub.cancel() }

        try await transport.connect(routeId: "window:win1")
        let ch0 = try XCTUnwrap(factory.channel(at: 0))
        let ch0Announced = await waitUntil { ch0.commands().contains("routeannounce") }
        XCTAssertTrue(ch0Announced)

        // Simulate the socket dropping mid-stream: receive() throws -> auto reconnect.
        ch0.drop()

        let reconnected = await waitUntil(timeout: 3.0) { factory.count >= 2 }
        XCTAssertTrue(reconnected)
        let ch1 = try XCTUnwrap(factory.channel(at: 1))
        let ch1Ready = await waitUntil { ch1.commands().contains("routeannounce") && ch1.commands().contains("eventsub") }
        XCTAssertTrue(ch1Ready)
    }

    // MARK: GUARDS §A — reqid/resid request matching

    func testCallMatchesResponseByResid() async throws {
        let factory = FakeWSChannelFactory()
        let transport = WaveTransportClient(wavesrvPath: "/unused", channelFactory: factory)
        transport._configureServerForTesting(addrs: ServerAddrs(wsAddr: "h:1", webAddr: "h:2"), authKey: "k")
        try await transport.connect(routeId: "window:win1")
        let ch = try XCTUnwrap(factory.channel(at: 0))

        struct Req: Codable, Sendable { let n: Int }
        struct Res: Codable, Sendable { let doubled: Int }

        // Issue the call concurrently; the fake "server" replies once it sees the reqid.
        async let result: Res = transport.call(command: "double", data: Req(n: 21), route: nil, timeoutMs: 2000)

        // Wait for the request frame, extract its reqid, echo a response.
        let sawRequest = await waitUntil { ch.message(command: "double") != nil }
        XCTAssertTrue(sawRequest)
        let req = try XCTUnwrap(ch.message(command: "double"))
        let reqid = try XCTUnwrap(req.reqid)
        let response = RpcMessage(resid: reqid, data: .object(["doubled": .int(42)]))
        ch.feedInbound(try WSFraming.encodeInbound(response))

        let res = try await result
        XCTAssertEqual(res.doubled, 42)
    }

    func testCallTimesOutWithoutResponse() async throws {
        let factory = FakeWSChannelFactory()
        let transport = WaveTransportClient(wavesrvPath: "/unused", channelFactory: factory)
        transport._configureServerForTesting(addrs: ServerAddrs(wsAddr: "h:1", webAddr: "h:2"), authKey: "k")
        try await transport.connect(routeId: "window:win1")

        struct Req: Codable, Sendable { let n: Int }
        struct Res: Codable, Sendable { let x: Int }
        do {
            let _: Res = try await transport.call(command: "noreply", data: Req(n: 1), route: nil, timeoutMs: 50)
            XCTFail("expected timeout")
        } catch let WaveError.timeout(reqid) {
            XCTAssertFalse(reqid.isEmpty)
        }
    }

    // MARK: GUARDS §A — ping is answered with pong

    func testInboundPingTriggersPong() async throws {
        let factory = FakeWSChannelFactory()
        let transport = WaveTransportClient(wavesrvPath: "/unused", channelFactory: factory)
        transport._configureServerForTesting(addrs: ServerAddrs(wsAddr: "h:1", webAddr: "h:2"), authKey: "k")
        try await transport.connect(routeId: "window:win1")
        let ch = try XCTUnwrap(factory.channel(at: 0))

        ch.feedInbound(try WSFraming.encodePing(stime: 123))
        let sawPong = await waitUntil { ch.rawContains(type: "pong") }
        XCTAssertTrue(sawPong)
    }

    // MARK: GUARDS §B — event fan-out by scope

    func testEventRecvFansOutByScope() async throws {
        let factory = FakeWSChannelFactory()
        let transport = WaveTransportClient(wavesrvPath: "/unused", channelFactory: factory)
        transport._configureServerForTesting(addrs: ServerAddrs(wsAddr: "h:1", webAddr: "h:2"), authKey: "k")
        try await transport.connect(routeId: "window:win1")
        let ch = try XCTUnwrap(factory.channel(at: 0))

        let hits = Counter()
        let sub = transport.subscribe(
            SubscriptionRequest(event: "waveobj:update", scopes: ["workspace:w1"])
        ) { event in
            if event.hasScope("workspace:w1") { hits.increment() }
        }
        defer { sub.cancel() }

        // Matching scope -> delivered.
        let match = WaveEvent(event: "waveobj:update", scopes: ["workspace:w1"], data: .object([:]))
        ch.feedInbound(try WSFraming.encodeInbound(eventRecv(match)))
        // Non-matching scope -> dropped.
        let miss = WaveEvent(event: "waveobj:update", scopes: ["workspace:other"], data: .object([:]))
        ch.feedInbound(try WSFraming.encodeInbound(eventRecv(miss)))

        let gotOneHit = await waitUntil { hits.value == 1 }
        XCTAssertTrue(gotOneHit)
        XCTAssertEqual(hits.value, 1)
    }

    // MARK: Helpers

    private func eventRecv(_ event: WaveEvent) -> RpcMessage {
        RpcMessage(command: "eventrecv", data: try? JSONValue.encode(event))
    }

    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }
}

// MARK: - Test doubles

/// Thread-safe hit counter for async event assertions.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// A `WSChannel` whose inbound is driven by the test and whose outbound is
/// captured for assertions.
final class FakeWSChannel: WSChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [Data] = []
    private let inbound: AsyncThrowingStream<Data, Error>
    private let inboundCont: AsyncThrowingStream<Data, Error>.Continuation
    private var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator

    init() {
        (inbound, inboundCont) = AsyncThrowingStream<Data, Error>.makeStream()
        iterator = inbound.makeAsyncIterator()
    }

    func send(_ data: Data) async throws {
        lock.lock(); sent.append(data); lock.unlock()
    }

    func receive() async throws -> Data {
        guard let next = try await iterator.next() else {
            throw WaveError.transport("fake channel closed")
        }
        return next
    }

    func close() {
        inboundCont.finish()
    }

    // Test controls.
    func feedInbound(_ data: Data) { inboundCont.yield(data) }
    func drop() { inboundCont.finish(throwing: WaveError.transport("dropped")) }

    /// Outbound RpcMessage `command`s captured so far (skips non-rpc frames).
    func commands() -> [String] {
        outboundMessages().compactMap { $0.command }
    }

    /// The first captured outbound RpcMessage with the given command.
    func message(command: String) -> RpcMessage? {
        outboundMessages().first { $0.command == command }
    }

    /// True if any raw outbound frame carries `{"type": <type>}` (for pong checks).
    func rawContains(type: String) -> Bool {
        snapshot().contains { data in
            let peek = try? JSONDecoder().decode(WSFramePeek.self, from: data)
            return peek?.type == type
        }
    }

    private func outboundMessages() -> [RpcMessage] {
        snapshot().compactMap { data in
            guard let frame = try? JSONDecoder().decode(WSRpcCommand.self, from: data) else { return nil }
            return frame.message
        }
    }

    private func snapshot() -> [Data] {
        lock.lock(); defer { lock.unlock() }; return sent
    }
}

/// Hands out `FakeWSChannel`s and records them so tests can drive reconnects.
final class FakeWSChannelFactory: WSChannelFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [FakeWSChannel] = []

    func connect(url: URL, authKey: String) async throws -> WSChannel {
        let ch = FakeWSChannel()
        lock.lock(); channels.append(ch); lock.unlock()
        return ch
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return channels.count }

    func channel(at index: Int) -> FakeWSChannel? {
        lock.lock(); defer { lock.unlock() }
        return index < channels.count ? channels[index] : nil
    }
}

// MARK: - Inbound encoder for tests (mirror of the server's WSRpcEvent frame)

extension WSFraming {
    /// Encode an `RpcMessage` as the server would (`{ "eventtype":"rpc", "data": … }`)
    /// so tests can feed it back through `decodeInbound`.
    static func encodeInbound(_ message: RpcMessage) throws -> Data {
        try JSONEncoder().encode(WSRpcEvent(data: message))
    }
}

// MARK: - Unix ws line framing

/// The unix ws channel's newline framing must extract lines with amortized O(1)
/// consumption (a 1MB socket read holds hundreds of messages under heavy
/// terminal output) while preserving partial lines across appends.
final class LineFrameBufferTests: XCTestCase {
    private func d(_ s: String) -> Data { Data(s.utf8) }

    func testManyLinesInOneChunkSkipsEmpties() {
        var b = LineFrameBuffer()
        b.append(d("alpha\nbeta\n\ngam"))
        XCTAssertEqual(b.nextLine(), d("alpha"))
        XCTAssertEqual(b.nextLine(), d("beta"))
        XCTAssertNil(b.nextLine())
        b.append(d("ma\n"))
        XCTAssertEqual(b.nextLine(), d("gamma"))
        XCTAssertNil(b.nextLine())
    }

    func testPartialLineSurvivesCompaction() {
        var b = LineFrameBuffer()
        b.append(d("one\ntwo\npart"))
        XCTAssertEqual(b.nextLine(), d("one"))
        XCTAssertEqual(b.nextLine(), d("two"))
        XCTAssertNil(b.nextLine())
        b.append(d("ial\nnext\n"))
        XCTAssertEqual(b.nextLine(), d("partial"))
        XCTAssertEqual(b.nextLine(), d("next"))
        XCTAssertNil(b.nextLine())
    }

    func testByteSplitAcrossEveryBoundary() {
        let payload = d("first\nsecond\n\nthird\n")
        for split in 0...payload.count {
            var b = LineFrameBuffer()
            b.append(payload.prefix(split))
            var lines: [Data] = []
            while let l = b.nextLine() { lines.append(l) }
            b.append(payload.suffix(payload.count - split))
            while let l = b.nextLine() { lines.append(l) }
            XCTAssertEqual(lines, [d("first"), d("second"), d("third")], "split=\(split)")
        }
    }
}

// MARK: - Unix HTTP fetcher (retry + encoding)

final class UnixHTTPFetcherTests: XCTestCase {
    func testEncodeRequest() {
        var req = URLRequest(url: URL(string: "http://wavesrv/wave/service?x=1")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)
        let out = UnixHTTPFetcher.encodeRequest(req, url: req.url!)
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("POST /wave/service?x=1 HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{}"))
    }

    func testFetchRetriesAfterZeroByteResponse() async throws {
        // First accept closes with NOTHING written (a server that hit its read
        // deadline); the retry must transparently succeed on the second accept.
        let path = "/tmp/wnx-\(getpid())-retry.sock"
        let server = try OneShotUnixServer(path: path, handlers: [
            { _ in },
            { cfd in
                var buf = [UInt8](repeating: 0, count: 8192)
                _ = read(cfd, &buf, buf.count)
                let resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"
                _ = resp.withCString { write(cfd, $0, strlen($0)) }
            },
        ])
        defer { server.stop() }
        var req = URLRequest(url: URL(string: "http://wavesrv/wave/service")!)
        req.httpMethod = "POST"
        req.httpBody = Data("{}".utf8)
        let (data, resp) = try await UnixHTTPFetcher(socketPath: path).fetch(req)
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
    }

    func testFetchFailsAfterTwoZeroByteResponses() async throws {
        let path = "/tmp/wnx-\(getpid())-fail.sock"
        let server = try OneShotUnixServer(path: path, handlers: [{ _ in }, { _ in }])
        defer { server.stop() }
        let req = URLRequest(url: URL(string: "http://wavesrv/wave/config")!)
        do {
            _ = try await UnixHTTPFetcher(socketPath: path).fetch(req)
            XCTFail("expected empty-response failure")
        } catch {
            XCTAssertTrue("\(error)".contains("empty response") || "\(error)".contains("unix"),
                          "unexpected error: \(error)")
        }
    }
}

/// Minimal unix-socket server: accepts one connection per handler, in order,
/// closing each connection after its handler returns.
private final class OneShotUnixServer: @unchecked Sendable {
    private let path: String
    private let fd: Int32

    init(path: String, handlers: [@Sendable (Int32) -> Void]) throws {
        self.path = path
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WaveError.transport("socket: \(errno)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            path.utf8CString.withUnsafeBufferPointer { src -> Bool in
                guard src.count <= dst.count else { return false }
                dst.baseAddress!.copyMemory(from: src.baseAddress!, byteCount: src.count)
                return true
            }
        }
        guard ok else { throw WaveError.transport("socket path too long: \(path)") }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw WaveError.transport("bind/listen \(path): \(errno)")
        }
        let listenFd = fd
        DispatchQueue(label: "oneshot-unix-server").async {
            for handler in handlers {
                let cfd = accept(listenFd, nil, nil)
                guard cfd >= 0 else { return }
                handler(cfd)
                close(cfd)
            }
        }
    }

    func stop() {
        close(fd)
        unlink(path)
    }
}
