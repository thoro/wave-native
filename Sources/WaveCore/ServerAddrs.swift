// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveCore — wavesrv discovery (ESTART parsing).
//
// Implements PROTOCOL.md §1 ("Launch / discovery"): wavesrv prints
// `WAVESRV-ESTART ws:<addr> web:<addr> ...` to stderr
// (`cmd/server/main-server.go:611`; Electron parser
// `emain/emain-wavesrv.ts:108-123`). GUARDS §P: parse robustly, fail fast.

import Foundation

/// The TCP addresses the native client connects to (PROTOCOL §1 — we use the
/// `web` + `ws` TCP addrs, not the domain socket).
public struct ServerAddrs: Sendable, Equatable {
    /// WebSocket listener address (host:port), used to build `ws://<wsAddr>/ws`.
    public let wsAddr: String
    /// HTTP listener address (host:port), used for `http://<webAddr>/wave/*`.
    public let webAddr: String

    public init(wsAddr: String, webAddr: String) {
        self.wsAddr = wsAddr
        self.webAddr = webAddr
    }

    public var httpBaseURL: String {
        // Unix-socket mode: the fetcher connects to the socket; the URL only
        // carries path + query, so the host is a placeholder.
        if Self.unixPath(webAddr) != nil { return "http://wavesrv" }
        return "http://\(webAddr)"
    }

    /// The unix socket path behind a `unix:<path>` addr, or nil for TCP addrs.
    /// The path rides percent-encoded (the ESTART line is space-delimited and
    /// real data dirs contain spaces -- "Application Support"); decode here.
    public static func unixPath(_ addr: String) -> String? {
        guard addr.hasPrefix("unix:") else { return nil }
        let raw = String(addr.dropFirst(5))
        return raw.removingPercentEncoding ?? raw
    }

    /// Build the `/ws` URL with the required `?stableid=<routeid>` (GUARDS §A).
    /// TCP addrs yield `ws://…`; unix addrs yield `ws+unix:<path>?stableid=…`
    /// (dispatched to the unix channel by the default factory).
    public func wsURL(stableId: String) -> String {
        let encoded = stableId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? stableId
        if wsAddr.hasPrefix("unix:") {
            // Keep the percent-encoded form: it goes back through URL(string:),
            // which rejects raw spaces; URL.path decodes it at the endpoint.
            return "\(WaveProtocolConst.unixWSScheme):\(wsAddr.dropFirst(5))?stableid=\(encoded)"
        }
        return "ws://\(wsAddr)/ws?stableid=\(encoded)"
    }

    /// Parse a single `WAVESRV-ESTART ...` stderr line.
    /// Tokens are space-separated `key:value`; we require `ws:` and `web:`.
    /// Throws `WaveError.badEStart` if the line is malformed (GUARDS §P).
    public static func parseEStart(_ line: String) throws -> ServerAddrs {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(WaveProtocolConst.eStartPrefix) else {
            throw WaveError.badEStart("missing \(WaveProtocolConst.eStartPrefix) prefix: \(trimmed)")
        }
        var ws: String?
        var web: String?
        let body = trimmed.dropFirst(WaveProtocolConst.eStartPrefix.count)
        for token in body.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            // Split only on the FIRST colon so `host:port` values survive.
            guard let colon = token.firstIndex(of: ":") else { continue }
            let key = String(token[token.startIndex..<colon])
            let value = String(token[token.index(after: colon)...])
            switch key {
            case "ws": ws = value
            case "web": web = value
            default: break
            }
        }
        guard let wsAddr = ws, !wsAddr.isEmpty else {
            throw WaveError.badEStart("missing ws: addr in: \(trimmed)")
        }
        guard let webAddr = web, !webAddr.isEmpty else {
            throw WaveError.badEStart("missing web: addr in: \(trimmed)")
        }
        return ServerAddrs(wsAddr: wsAddr, webAddr: webAddr)
    }
}
