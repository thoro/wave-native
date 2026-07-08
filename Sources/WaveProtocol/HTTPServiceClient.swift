// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveProtocol — HTTP "service" layer client.
//
// Implements PROTOCOL.md §0 / §4 and GUARDS §A/§B/§T:
//   - POST <web>/wave/service  body=WebCallType  -> WebReturnType
//     (`pkg/service/service.go:45-57`, handler `pkg/web/web.go:107-148`). Every
//     response carries `updates: []WaveObjUpdate` that MUST be applied to the
//     object cache (GUARDS §B) — the transport forwards them to its delegate.
//   - GET <web>/wave/file?zoneid=&name=&offset=  -> raw bytes + X-ZoneFileInfo
//     header (base64-std JSON `WaveFile`) (`pkg/web/web.go:150-210`). Used for
//     terminal backfill (PROTOCOL §4 / GUARDS §T).
//   - `X-AuthKey` header on every call (GUARDS §A).

import Foundation
import WaveCore

/// Stateless HTTP client for the `/wave/service` and `/wave/file` endpoints.
public final class HTTPServiceClient: @unchecked Sendable {
    private let baseURL: String
    private let authKey: String
    private let fetcher: HTTPFetching

    public init(baseURL: String, authKey: String, fetcher: HTTPFetching) {
        self.baseURL = baseURL
        self.authKey = authKey
        self.fetcher = fetcher
    }

    public convenience init(baseURL: String, authKey: String, session: URLSession = .shared) {
        self.init(baseURL: baseURL, authKey: authKey, fetcher: session)
    }

    /// Address-aware constructor: a `unix:<path>` web addr routes through the
    /// unix-socket HTTP fetcher; TCP addrs use URLSession.
    public convenience init(addrs: ServerAddrs, authKey: String, session: URLSession = .shared) {
        if let path = ServerAddrs.unixPath(addrs.webAddr) {
            self.init(baseURL: addrs.httpBaseURL, authKey: authKey, fetcher: UnixHTTPFetcher(socketPath: path))
        } else {
            self.init(baseURL: addrs.httpBaseURL, authKey: authKey, fetcher: session)
        }
    }

    /// POST a `WebCallType` to `/wave/service`. Returns the decoded `WebReturnType`
    /// (caller applies `.updates`). Throws `WaveError.http` on a non-2xx status.
    public func callService(_ call: WebCallType) async throws -> WebReturnType {
        guard let url = URL(string: baseURL + WaveProtocolConst.servicePath) else {
            throw WaveError.transport("bad service URL: \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(authKey, forHTTPHeaderField: WaveProtocolConst.authKeyHeader)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(call)

        let (data, http) = try await fetcher.fetch(request)
        guard (200 ..< 300).contains(http.statusCode) else {
            throw WaveError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        do {
            return try JSONDecoder().decode(WebReturnType.self, from: data)
        } catch {
            throw WaveError.decoding("WebReturnType: \(error)")
        }
    }

    /// GET the file backfill for `zoneId`/`name` from `offset`. Returns the raw
    /// bytes plus the decoded `WaveFile` from the `X-ZoneFileInfo` header.
    ///
    /// GUARDS §T: the returned `WaveFile.size` / `dataStartIdx` are authoritative
    /// — the server clamps `offset` to the circular start; callers must reconcile
    /// against the returned info, not the requested offset. A 204 (file not yet
    /// created) yields empty bytes and a zero-size `WaveFile`.
    public func fetchFile(zoneId: String, name: String, offset: Int64) async throws -> (data: Data, info: WaveFile) {
        let result = try await fetchFileRange(zoneId: zoneId, name: name, range: FileFetchRange(offset: offset))
        return (result.data, result.info)
    }

    /// GET a byte/line range of a wave file. `range` maps 1:1 onto the
    /// `/wave/file` query params (see `pkg/web/web.go handleWaveFile`); the
    /// result's `startOffset` is derived the same way the server derives it, so
    /// callers can anchor the body absolutely without a second round trip.
    public func fetchFileRange(zoneId: String, name: String, range: FileFetchRange) async throws -> FileFetchResult {
        var components = URLComponents(string: baseURL + WaveProtocolConst.filePath)
        var queryItems = [
            URLQueryItem(name: "zoneid", value: zoneId),
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "offset", value: String(range.offset)),
        ]
        if let count = range.count {
            queryItems.append(URLQueryItem(name: "count", value: String(count)))
        }
        if let tail = range.tail {
            queryItems.append(URLQueryItem(name: "tail", value: String(tail)))
        }
        if let startLine = range.startLine, let numLines = range.numLines {
            queryItems.append(URLQueryItem(name: "startline", value: String(startLine)))
            queryItems.append(URLQueryItem(name: "numlines", value: String(numLines)))
        }
        if range.stripAnsi {
            queryItems.append(URLQueryItem(name: "stripansi", value: "1"))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw WaveError.transport("bad file URL: \(baseURL)")
        }
        var request = URLRequest(url: url)
        request.setValue(authKey, forHTTPHeaderField: WaveProtocolConst.authKeyHeader)

        let (data, http) = try await fetcher.fetch(request)
        if http.statusCode == 204 {
            // File doesn't exist yet (`pkg/web/web.go:172-174`): nothing to backfill.
            let empty = WaveFile(
                zoneid: zoneId, name: name, opts: FileOpts(),
                createdts: 0, size: 0, modts: 0)
            return FileFetchResult(data: Data(), info: empty, startOffset: 0)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw WaveError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        guard let header = http.value(forHTTPHeaderField: WaveProtocolConst.zoneFileInfoHeader) else {
            throw WaveError.decoding("missing \(WaveProtocolConst.zoneFileInfoHeader) header")
        }
        guard let headerJSON = Data(base64Encoded: header) else {
            throw WaveError.decoding("\(WaveProtocolConst.zoneFileInfoHeader) is not valid base64")
        }
        let info: WaveFile
        do {
            info = try JSONDecoder().decode(WaveFile.self, from: headerJSON)
        } catch {
            throw WaveError.decoding("WaveFile header: \(error)")
        }
        var startOffset: Int64
        var startLine: Int64?
        var totalLines: Int64?
        if let lineInfo = http.value(forHTTPHeaderField: WaveProtocolConst.lineInfoHeader) {
            // "startByte:endByte:startLine:totalLines" (line-addressed or tail fetch)
            let parts = lineInfo.split(separator: ":").compactMap { Int64($0) }
            guard parts.count == 4 else {
                throw WaveError.decoding("\(WaveProtocolConst.lineInfoHeader) malformed: \(lineInfo)")
            }
            startOffset = parts[0]
            startLine = parts[2]
            totalLines = parts[3]
        } else if let tail = range.tail, tail > 0 {
            startOffset = Swift.max(info.size - Int64(data.count), 0)
        } else {
            startOffset = Swift.max(range.offset, info.dataStartIdx)
        }
        return FileFetchResult(
            data: data, info: info, startOffset: startOffset,
            startLine: startLine, totalLines: totalLines)
    }
}
