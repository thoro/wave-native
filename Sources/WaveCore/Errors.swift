// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveCore — Error types shared across all modules.
//
// Covers the failure surfaces named in PROTOCOL.md §1 (transport/handshake),
// §2 (object store), and GUARDS.md (§A transport, §P spawn / ESTART parse).

import Foundation

/// Unified error type for the Wave native client.
public enum WaveError: Error, Equatable, CustomStringConvertible {
    /// Transport-layer failure (socket closed, write failed, not connected).
    case transport(String)
    /// The server returned an error string on an RPC (`RpcMessage.error`,
    /// PROTOCOL.md §1) or `WebReturnType.error` (§0).
    case rpc(String)
    /// An RPC request exceeded its timeout (`RpcMessage.timeout`, default 5000ms).
    case timeout(reqid: String)
    /// We are not connected to `wavesrv` yet (no WS / no addresses).
    case notConnected
    /// Failed to encode/decode a wire payload.
    case decoding(String)
    /// Could not parse the `WAVESRV-ESTART` stderr line (GUARDS §P).
    case badEStart(String)
    /// Spawning the `wavesrv` child process failed (GUARDS §P).
    case spawnFailed(String)
    /// A malformed object reference (`ParseORef`, PROTOCOL.md §2).
    case invalidORef(String)
    /// An HTTP `/wave/*` call returned a non-2xx status.
    case http(status: Int, body: String)
    /// The terminal byte-offset reconciler detected a gap/overlap it cannot heal
    /// (GUARDS §T). This is a correctness fault, not a transient error.
    case terminalReconcile(String)

    public var description: String {
        switch self {
        case let .transport(m): return "transport error: \(m)"
        case let .rpc(m): return "rpc error: \(m)"
        case let .timeout(reqid): return "rpc timeout (reqid=\(reqid))"
        case .notConnected: return "not connected to wavesrv"
        case let .decoding(m): return "decoding error: \(m)"
        case let .badEStart(m): return "bad WAVESRV-ESTART line: \(m)"
        case let .spawnFailed(m): return "wavesrv spawn failed: \(m)"
        case let .invalidORef(m): return "invalid oref: \(m)"
        case let .http(status, body): return "http \(status): \(body)"
        case let .terminalReconcile(m): return "terminal reconcile error: \(m)"
        }
    }
}
