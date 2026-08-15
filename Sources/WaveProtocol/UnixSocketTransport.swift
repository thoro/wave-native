// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveProtocol — HTTP and ws-message transport over unix domain sockets.
//
// In no-TCP mode wavesrv serves its web API and the websocket message protocol
// on unix domain sockets (`web.sock` / `ws.sock` in the data dir,
// `WAVETERM_WEB_UNIX_SOCKET`), so it occupies no local port and cannot be
// reached over the network. URLSession cannot speak HTTP over a unix socket,
// so this file provides:
//   - `UnixHTTPFetcher`: a minimal HTTP/1.1 client (one connection per request,
//     `Connection: close`, Content-Length / chunked / EOF body framing).
//   - `UnixWSChannel`: the ws message protocol as newline-framed JSON with a
//     mandatory first line {"type":"authenticate","authkey":...,"stableid":...}
//     (`pkg/web/ws.go RunWSUnixServer`). Same JSON envelope as the WS path, so
//     the transport above is unchanged.
//   - `DefaultWSChannelFactory`: dispatches ws:// to URLSession and ws+unix: to
//     `UnixWSChannel`.

import Foundation
import Network
import WaveCore

// MARK: - HTTP fetching seam

/// The one-request HTTP seam under `HTTPServiceClient`, so the same client code
/// runs over URLSession (TCP) and the unix-socket fetcher.
public protocol HTTPFetching: Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPFetching {
    public func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WaveError.transport("no HTTP response from \(request.url?.absoluteString ?? "?")")
        }
        return (data, http)
    }
}

// MARK: - Raw unix stream connection

/// A single connected unix-domain stream with async send/receive.
///
/// Deliberately does NOT await `.ready` before returning: NWConnection queues sends
/// issued while connecting and fails them if the connect fails. Waiting for `.ready`
/// on the Swift cooperative pool opened a starvation window — under load (many busy
/// shells) the resume between the server's accept and our request write could be
/// delayed past the server's read deadline, which then closed the connection with a
/// zero-byte response ("no header terminator"). Enqueueing the payload in the same
/// synchronous stretch as `start()` hands the race to the kernel instead.
final class UnixStreamConnection: @unchecked Sendable {
    private let conn: NWConnection

    init(path: String) {
        conn = NWConnection(to: .unix(path: path), using: .tcp)
        conn.start(queue: DispatchQueue.global(qos: .userInitiated))
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err {
                    cont.resume(throwing: WaveError.transport("unix send: \(err)"))
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Receive the next available chunk. Returns nil on clean EOF.
    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, err in
                if let err {
                    cont.resume(throwing: WaveError.transport("unix recv: \(err)"))
                    return
                }
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    func cancel() {
        conn.cancel()
    }
}

// MARK: - HTTP/1.1 over a unix socket

/// Minimal HTTP/1.1 client for wavesrv's unix web socket. One connection per
/// request with `Connection: close` — the response ends at EOF, with
/// Content-Length and chunked framing both honored when present.
public final class UnixHTTPFetcher: HTTPFetching {
    private let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw WaveError.transport("unix http: no url") }
        let out = Self.encodeRequest(request, url: url)

        // A round trip that yields ZERO response bytes means the server closed the
        // connection before parsing the request (deadline/shutdown race) — no handler
        // ran, so one resend is safe regardless of method.
        for attempt in 1...2 {
            let (raw, error) = await roundTrip(out)
            if raw.isEmpty {
                if attempt == 1 { continue }
                throw error ?? WaveError.transport("unix http: empty response for \(url.path)")
            }
            if let error { throw error }
            return try Self.parseResponse(raw, url: url)
        }
        throw WaveError.transport("unix http: unreachable")
    }

    static func encodeRequest(_ request: URLRequest, url: URL) -> Data {
        var target = url.path.isEmpty ? "/" : url.path
        if let q = url.query, !q.isEmpty { target += "?\(q)" }

        var head = "\(request.httpMethod ?? "GET") \(target) HTTP/1.1\r\n"
        head += "Host: wavesrv\r\nConnection: close\r\n"
        for (k, v) in request.allHTTPHeaderFields ?? [:] {
            head += "\(k): \(v)\r\n"
        }
        if let body = request.httpBody {
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        if let body = request.httpBody { out.append(body) }
        return out
    }

    /// One connect+send+read-to-EOF exchange. Returns whatever bytes arrived plus
    /// the error that stopped the exchange (nil on clean EOF), so the caller can
    /// distinguish "request never processed" (no bytes) from a broken response.
    private func roundTrip(_ out: Data) async -> (Data, Error?) {
        let conn = UnixStreamConnection(path: socketPath)
        defer { conn.cancel() }
        var raw = Data()
        do {
            try await conn.send(out)
            while let chunk = try await conn.receive() {
                raw.append(chunk)
            }
        } catch {
            return (raw, error)
        }
        return (raw, nil)
    }

    /// Parse a full raw HTTP/1.1 response (headers already complete — the
    /// connection is closed by the server after the body).
    static func parseResponse(_ raw: Data, url: URL) throws -> (Data, HTTPURLResponse) {
        guard let headerEnd = raw.range(of: Data("\r\n\r\n".utf8)) else {
            throw WaveError.transport("unix http: no header terminator")
        }
        let headText = String(decoding: raw[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw WaveError.transport("unix http: empty head") }
        let statusLine = lines.removeFirst()
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw WaveError.transport("unix http: bad status line: \(statusLine)")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        var body = raw[headerEnd.upperBound...]
        let transferEncoding = headers.first { $0.key.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame }?.value
        if transferEncoding?.lowercased().contains("chunked") == true {
            body = try decodeChunked(Data(body))[...]
            headers = headers.filter { $0.key.caseInsensitiveCompare("Transfer-Encoding") != .orderedSame }
        } else if let clStr = headers.first(where: { $0.key.caseInsensitiveCompare("Content-Length") == .orderedSame })?.value,
                  let cl = Int(clStr), cl <= body.count {
            body = body.prefix(cl)
        }

        guard let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else {
            throw WaveError.transport("unix http: cannot build response")
        }
        return (Data(body), response)
    }

    /// Decode a chunked transfer-encoded body (sizes in hex, CRLF-delimited).
    static func decodeChunked(_ data: Data) throws -> Data {
        var out = Data()
        var idx = data.startIndex
        let crlf = Data("\r\n".utf8)
        while idx < data.endIndex {
            guard let lineEnd = data.range(of: crlf, in: idx..<data.endIndex) else {
                throw WaveError.transport("unix http: bad chunk header")
            }
            let sizeText = String(decoding: data[idx..<lineEnd.lowerBound], as: UTF8.self)
            let hex = sizeText.split(separator: ";").first.map(String.init) ?? sizeText
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else {
                throw WaveError.transport("unix http: bad chunk size: \(sizeText)")
            }
            if size == 0 { break }
            let bodyStart = lineEnd.upperBound
            guard let bodyEnd = data.index(bodyStart, offsetBy: size, limitedBy: data.endIndex) else {
                throw WaveError.transport("unix http: truncated chunk")
            }
            out.append(data[bodyStart..<bodyEnd])
            idx = data.index(bodyEnd, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex
        }
        return out
    }
}

// MARK: - ws message channel over a unix socket

/// Newline-framed line extractor with amortized O(1) consumption. Consumed bytes
/// are trimmed only when the buffer runs dry: rebuilding the buffer per
/// extracted line is O(buffered²) — one 1MB socket read holds hundreds of
/// newline-framed messages under heavy terminal output, and the per-line tail
/// copies made this reader the pipeline's bottleneck (backpressure all the way
/// back to wavesrv's ws write deadline).
struct LineFrameBuffer {
    private var buffer = Data()
    private var readOffset = 0

    mutating func append(_ chunk: Data) {
        buffer.append(chunk)
    }

    /// The next complete line (without its trailing `\n`), skipping empty lines,
    /// or nil when no full line is buffered.
    mutating func nextLine() -> Data? {
        while true {
            let scanStart = buffer.index(buffer.startIndex, offsetBy: readOffset)
            guard scanStart < buffer.endIndex,
                  let nl = buffer[scanStart...].firstIndex(of: 0x0a) else {
                compact()
                return nil
            }
            let line = Data(buffer[scanStart..<nl])
            readOffset = buffer.distance(from: buffer.startIndex, to: nl) + 1
            if line.isEmpty { continue }
            return line
        }
    }

    private mutating func compact() {
        guard readOffset > 0 else { return }
        buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: readOffset))
        readOffset = 0
    }
}

/// `WSChannel` over a unix domain socket: newline-framed JSON messages, with the
/// authenticate line sent on connect (replaces the WS upgrade query/header).
public final class UnixWSChannel: WSChannel, @unchecked Sendable {
    private let conn: UnixStreamConnection
    private let lock = NSLock()
    private var frames = LineFrameBuffer()
    private var closed = false

    public init(path: String, authKey: String, stableId: String) async throws {
        conn = UnixStreamConnection(path: path)
        let auth: [String: String] = ["type": "authenticate", "authkey": authKey, "stableid": stableId]
        var line = try JSONEncoder().encode(auth)
        line.append(0x0a)
        try await conn.send(line)
    }

    public func send(_ data: Data) async throws {
        var framed = data
        framed.append(0x0a)
        try await conn.send(framed)
    }

    public func receive() async throws -> Data {
        while true {
            lock.lock()
            if let line = frames.nextLine() {
                lock.unlock()
                return line
            }
            let isClosed = closed
            lock.unlock()
            if isClosed { throw WaveError.transport("unix ws: closed") }
            guard let chunk = try await conn.receive() else {
                lock.lock()
                closed = true
                lock.unlock()
                throw WaveError.transport("unix ws: eof")
            }
            lock.lock()
            frames.append(chunk)
            lock.unlock()
        }
    }

    public func close() {
        lock.lock()
        closed = true
        lock.unlock()
        conn.cancel()
    }
}

// MARK: - Dispatching channel factory

/// Default `WSChannelFactory`: `ws://` connects via URLSession; `ws+unix:` (path
/// = socket, `stableid` query) connects via `UnixWSChannel`.
public final class DefaultWSChannelFactory: WSChannelFactory {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(url: URL, authKey: String) async throws -> WSChannel {
        guard url.scheme == WaveProtocolConst.unixWSScheme else {
            return try await URLSessionWSChannelFactory(session: session).connect(url: url, authKey: authKey)
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let stableId = comps?.queryItems?.first(where: { $0.name == "stableid" })?.value ?? ""
        guard !stableId.isEmpty else {
            throw WaveError.transport("unix ws url missing stableid: \(url)")
        }
        return try await UnixWSChannel(path: url.path, authKey: authKey, stableId: stableId)
    }
}
