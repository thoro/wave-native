// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveProtocol — WebSocket channel abstraction.
//
// Implements the socket half of PROTOCOL.md §1 / GUARDS §A: open
// `ws://<wsAddr>/ws?stableid=<routeId>` with the `X-AuthKey` upgrade header
// (`pkg/web/ws.go:254-264`). The transport talks to this protocol, not directly
// to URLSession, so reconnect/re-announce can be exercised against a fake socket
// in unit tests (see WaveProtocolTests).
//
// MAC-LINK note: `URLSessionWebSocketTask` is available on macOS 13 and needs no
// external linking; this file builds and runs on the Mac as-is. It is abstracted
// only for testability, not because of a missing symbol.

import Foundation
import WaveCore

/// A bidirectional WebSocket text channel. One logical connection.
public protocol WSChannel: AnyObject, Sendable {
    /// Send one text frame (UTF-8 JSON bytes).
    func send(_ data: Data) async throws
    /// Await the next inbound text frame. Throws when the socket closes/errors —
    /// the transport treats a throw as "connection lost" and reconnects.
    func receive() async throws -> Data
    /// Close the socket. Idempotent.
    func close()
}

/// Opens `WSChannel`s. Injected so tests can substitute a fake socket.
public protocol WSChannelFactory: Sendable {
    /// Connect to `url`, sending `authKey` as the `X-AuthKey` upgrade header.
    func connect(url: URL, authKey: String) async throws -> WSChannel
}

// MARK: - URLSession implementation

/// `WSChannel` backed by `URLSessionWebSocketTask`.
public final class URLSessionWSChannel: WSChannel, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    public init(task: URLSessionWebSocketTask) {
        self.task = task
        task.resume()
    }

    public func send(_ data: Data) async throws {
        // wavesrv reads text frames (`pkg/web/ws.go` ReadMessage + json.Unmarshal);
        // send JSON as a UTF-8 text frame to match the Electron renderer exactly.
        let text = String(decoding: data, as: UTF8.self)
        try await task.send(.string(text))
    }

    public func receive() async throws -> Data {
        let message = try await task.receive()
        switch message {
        case let .string(s):
            return Data(s.utf8)
        case let .data(d):
            return d
        @unknown default:
            return Data()
        }
    }

    public func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

/// Default `WSChannelFactory` using `URLSession`.
public final class URLSessionWSChannelFactory: WSChannelFactory {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(url: URL, authKey: String) async throws -> WSChannel {
        var request = URLRequest(url: url)
        // GUARDS §A: the auth key rides the WS upgrade as a header.
        request.setValue(authKey, forHTTPHeaderField: WaveProtocolConst.authKeyHeader)
        let task = session.webSocketTask(with: request)
        return URLSessionWSChannel(task: task)
    }
}
