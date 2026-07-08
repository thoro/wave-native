// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveProtocol — WebSocket frame codec.
//
// Implements PROTOCOL.md §1 ("WebSocket framing (ASYMMETRIC)") and GUARDS §A:
//   - Outbound (client->server): { "wscommand":"rpc", "message": <RpcMessage> }
//     (`frontend/app/store/ws.ts:247-254`).
//   - Inbound  (server->client): { "eventtype":"rpc", "data": <RpcMessage> }
//     (`pkg/web/ws.go:288-294`).
//   - Keepalive: inbound { "type":"ping", "stime":N } must be answered with
//     { "type":"pong" } (`pkg/web/ws.go:148-177`).
//
// The framing is ASYMMETRIC: encoding an inbound shape on the way out (or vice
// versa) is silently dropped by the peer. These pure functions are unit-tested
// without a live socket (see WaveProtocolTests).

import Foundation
import WaveCore

/// A classified inbound WebSocket frame. The server multiplexes three frame
/// shapes on the single `/ws` connection.
public enum InboundWSFrame: Sendable {
    /// An RPC envelope (`{ "eventtype":"rpc", "data": … }`) — request, response,
    /// stream chunk, or an `eventrecv` event delivery.
    case rpc(RpcMessage)
    /// Application-level keepalive `{ "type":"ping", "stime":N }`.
    case ping(stime: Int64?)
    /// Application-level keepalive `{ "type":"pong" }`.
    case pong
    /// A frame we do not model (forward-compatible: ignore).
    case unknown
}

/// Stateless WebSocket frame codec for the wavesrv contract.
public enum WSFraming {
    // Fresh coders per call keep the type `Sendable` without shared mutable state.
    private static func encoder() -> JSONEncoder { JSONEncoder() }
    private static func decoder() -> JSONDecoder { JSONDecoder() }

    /// Encode an `RpcMessage` as an OUTBOUND frame (`wscommand:rpc`). GUARDS §A.
    public static func encodeOutbound(_ message: RpcMessage) throws -> Data {
        try encoder().encode(WSRpcCommand(message: message))
    }

    /// Encode the keepalive reply `{ "type":"pong" }`. GUARDS §A (15s deadline).
    public static func encodePong() throws -> Data {
        try encoder().encode(WSPong())
    }

    /// Encode a `{ "type":"ping", "stime":N }` frame (used by the fake server in
    /// tests and never required from a real client, which only answers pings).
    public static func encodePing(stime: Int64?) throws -> Data {
        try encoder().encode(WSPing(type: "ping", stime: stime))
    }

    /// Classify and decode an inbound text frame. GUARDS §A: inbound RPCs are
    /// framed as `{ "eventtype":"rpc", "data": … }`, NOT `wscommand`.
    public static func decodeInbound(_ data: Data) throws -> InboundWSFrame {
        let peek = try decoder().decode(WSFramePeek.self, from: data)
        if peek.type == "ping" {
            let ping = try? decoder().decode(WSPing.self, from: data)
            return .ping(stime: ping?.stime)
        }
        if peek.type == "pong" {
            return .pong
        }
        if peek.eventtype == "rpc" {
            let evt = try decoder().decode(WSRpcEvent.self, from: data)
            return .rpc(evt.data)
        }
        return .unknown
    }
}
