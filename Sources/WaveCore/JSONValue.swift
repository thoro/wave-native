// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveCore — JSONValue
//
// A lossless Codable representation of arbitrary JSON. Needed because the wire
// protocol (PROTOCOL.md §1 RpcMessage.data, §2 WaveObj.meta / LayoutState.rootnode,
// §3 WebReturnType.data) carries Go `any` / `map[string]any` fields. Swift's
// Codable cannot round-trip `[String: Any]`, so every such field uses JSONValue.
//
// `MetaMapType` (the Wave object `meta` map, `pkg/waveobj/metamap.go:8`) is a
// `[String: JSONValue]`.

import Foundation

/// The Wave object `meta` map (`pkg/waveobj/metamap.go:8` — `map[string]any`).
public typealias MetaMapType = [String: JSONValue]

/// Property wrapper for a WaveObj `meta` map that the server may legitimately send
/// as `null` (e.g. a freshly created client/window/workspace on first launch). The
/// Go type is a non-nil `map[string]any`, but its JSON is `null` when empty, so a
/// plain `[String: JSONValue]` decode would fail. This decodes null (or any
/// non-object) as an empty map so object decoding never breaks on a null `meta`.
@propertyWrapper
public struct NullableMeta: Codable, Sendable, Equatable {
    public var wrappedValue: MetaMapType
    public init(wrappedValue: MetaMapType = [:]) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = [:]
            return
        }
        wrappedValue = (try? container.decode(MetaMapType.self)) ?? [:]
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

/// Decodes a JSON string array, treating `null` (and a missing key, via the
/// `KeyedDecodingContainer` extension below) as `[]`. The backend sends `null` for
/// e.g. `Client.windowids` when there are no windows, which would otherwise crash the
/// synthesized `[String]` decode.
@propertyWrapper
public struct NullableStringArray: Codable, Sendable, Equatable {
    public var wrappedValue: [String]
    public init(wrappedValue: [String] = []) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = []
            return
        }
        wrappedValue = (try? container.decode([String].self)) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    /// Make a missing key decode to `[]` as well (not just an explicit `null`).
    public func decode(_ type: NullableStringArray.Type, forKey key: Key) throws -> NullableStringArray {
        try decodeIfPresent(type, forKey: key) ?? NullableStringArray(wrappedValue: [])
    }
}

/// A fully-decoded JSON value. Round-trips byte-for-byte through `Codable`.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: Decoding

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let b = try? container.decode(Bool.self) {
            self = .bool(b)
            return
        }
        // Prefer integer when the value has no fractional component.
        if let i = try? container.decode(Int64.self) {
            self = .int(i)
            return
        }
        if let d = try? container.decode(Double.self) {
            self = .double(d)
            return
        }
        if let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
            return
        }
        if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container, debugDescription: "unsupported JSON value")
    }

    // MARK: Encoding

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(b): try container.encode(b)
        case let .int(i): try container.encode(i)
        case let .double(d): try container.encode(d)
        case let .string(s): try container.encode(s)
        case let .array(a): try container.encode(a)
        case let .object(o): try container.encode(o)
        }
    }

    // MARK: Convenience accessors

    public var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    public var boolValue: Bool? { if case let .bool(b) = self { return b }; return nil }
    public var intValue: Int64? {
        switch self {
        case let .int(i): return i
        case let .double(d): return Int64(d)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .double(d): return d
        case let .int(i): return Double(i)
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? { if case let .array(a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case let .object(o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Keyed lookup into an object value.
    public subscript(_ key: String) -> JSONValue? {
        guard case let .object(o) = self else { return nil }
        return o[key]
    }
}

// MARK: - Codable <-> JSONValue bridges

public extension JSONValue {
    /// Encode any `Encodable` into a `JSONValue` (used to put typed RPC request
    /// payloads into `RpcMessage.data` / `WebCallType.args`).
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decode this `JSONValue` into a typed `Decodable` (used to pull a typed RPC
    /// response out of `RpcMessage.data` / `WebReturnType.data`).
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Literal conveniences (ergonomic construction in callers/tests)

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}
