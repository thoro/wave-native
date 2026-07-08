// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveCore — ORef (Wave Object Reference)
//
// Implements PROTOCOL.md §2 ("ORef format: \"<otype>:<oid>\"") mirroring the Go
// source of truth `pkg/waveobj/waveobj.go:30-100` (ParseORef, String, JSON
// marshal-as-string) and the otype constants from `pkg/waveobj/wtype.go:24-48`.
//
// Encodes GUARDS §B (subscription scope is the *oref string*, never a bare id):
// callers build scopes from `ORef.string`.

import Foundation

/// Valid Wave object types (`pkg/waveobj/wtype.go:24-35`).
public enum OType {
    public static let client = "client"
    public static let window = "window"
    public static let workspace = "workspace"
    public static let tab = "tab"
    public static let layout = "layout"
    public static let block = "block"
    public static let mainServer = "mainserver"
    public static let job = "job"
    public static let temp = "temp"
    public static let builder = "builder"

    /// `ValidOTypes` (`pkg/waveobj/wtype.go:37-48`).
    public static let valid: Set<String> = [
        client, window, workspace, tab, layout, block, mainServer, job, temp, builder,
    ]
}

/// A reference to a Wave object, serialized on the wire as the single string
/// `"<otype>:<oid>"`. An empty `ORef` (both fields empty) serializes to `""`,
/// matching the Go `MarshalJSON`/`UnmarshalJSON` behavior.
public struct ORef: Hashable, Sendable, CustomStringConvertible, Codable {
    public let otype: String
    public let oid: String

    public init(otype: String, oid: String) {
        self.otype = otype
        self.oid = oid
    }

    /// `pkg/waveobj/waveobj.go:36-41` — empty if either field is empty.
    public var isEmpty: Bool { otype.isEmpty || oid.isEmpty }

    /// `pkg/waveobj/waveobj.go:36-41` — `"<otype>:<oid>"`, or `""` when empty.
    public var string: String {
        guard !isEmpty else { return "" }
        return "\(otype):\(oid)"
    }

    public var description: String { string }

    // MARK: Parsing

    /// Mirror of `ParseORef` (`pkg/waveobj/waveobj.go:78-95`): exactly two
    /// colon-separated fields, otype matching `^[a-z]+$` and present in
    /// `OType.valid`.
    public static func parse(_ s: String) throws -> ORef {
        let fields = s.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2 else {
            throw WaveError.invalidORef("invalid object reference: \(s)")
        }
        let otype = String(fields[0])
        guard isValidOTypeToken(otype) else {
            throw WaveError.invalidORef("invalid object type: \(otype)")
        }
        guard OType.valid.contains(otype) else {
            throw WaveError.invalidORef("unknown object type: \(otype)")
        }
        return ORef(otype: otype, oid: String(fields[1]))
    }

    /// Non-throwing convenience; returns nil on a malformed reference.
    public init?(string s: String) {
        guard let parsed = try? ORef.parse(s) else { return nil }
        self = parsed
    }

    /// `otypeRe = ^[a-z]+$` (`pkg/waveobj/waveobj.go:78`).
    private static func isValidOTypeToken(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.allSatisfy { $0 >= "a" && $0 <= "z" }
    }

    // MARK: Codable (as a single JSON string)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let s = try container.decode(String.self)
        if s.isEmpty {
            self.init(otype: "", oid: "")
            return
        }
        self = try ORef.parse(s)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

public extension ORef {
    static func client(_ oid: String) -> ORef { ORef(otype: OType.client, oid: oid) }
    static func window(_ oid: String) -> ORef { ORef(otype: OType.window, oid: oid) }
    static func workspace(_ oid: String) -> ORef { ORef(otype: OType.workspace, oid: oid) }
    static func tab(_ oid: String) -> ORef { ORef(otype: OType.tab, oid: oid) }
    static func layout(_ oid: String) -> ORef { ORef(otype: OType.layout, oid: oid) }
    static func block(_ oid: String) -> ORef { ORef(otype: OType.block, oid: oid) }
}
