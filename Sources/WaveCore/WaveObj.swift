// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveCore — polymorphic WaveObj envelope + WaveObjUpdate.
//
// Implements PROTOCOL.md §2 ("Subscribe / live updates"): the `waveobj:update`
// event payload is `WaveObjUpdate { updatetype, otype, oid, obj }`
// (`pkg/waveobj/wtype.go:50-55`). The polymorphic `obj` is keyed by `otype`.
//
// GUARDS §B encoded here as helpers the store relies on: every WaveObj exposes
// `oid` and `version`, so the store can apply the version-guarded merge
// ("drop any update whose obj.version <= cached.version", `wos.ts:272`).

import Foundation

public let updateTypeUpdate = "update"
public let updateTypeDelete = "delete"

/// A decoded Wave object of any concrete type, keyed by its `otype`.
/// (Out of scope per PROTOCOL.md: mainserver/job/temp/builder are not modeled.)
public enum AnyWaveObj: Sendable {
    case client(Client)
    case window(Window)
    case workspace(Workspace)
    case tab(Tab)
    case layout(LayoutState)
    case block(Block)

    public var otype: String {
        switch self {
        case .client: return OType.client
        case .window: return OType.window
        case .workspace: return OType.workspace
        case .tab: return OType.tab
        case .layout: return OType.layout
        case .block: return OType.block
        }
    }

    public var oid: String {
        switch self {
        case let .client(o): return o.oid
        case let .window(o): return o.oid
        case let .workspace(o): return o.oid
        case let .tab(o): return o.oid
        case let .layout(o): return o.oid
        case let .block(o): return o.oid
        }
    }

    /// Monotonic object version — the basis of the GUARDS §B merge guard.
    public var version: Int {
        switch self {
        case let .client(o): return o.version
        case let .window(o): return o.version
        case let .workspace(o): return o.version
        case let .tab(o): return o.version
        case let .layout(o): return o.version
        case let .block(o): return o.version
        }
    }

    /// This object's reference.
    public var oref: ORef { ORef(otype: otype, oid: oid) }

    /// Decode a concrete object from a JSON payload, dispatching on `otype`.
    /// Returns nil for object types this client does not model.
    public static func decode(otype: String, from json: JSONValue) throws -> AnyWaveObj? {
        switch otype {
        case OType.client: return .client(try json.decode(Client.self))
        case OType.window: return .window(try json.decode(Window.self))
        case OType.workspace: return .workspace(try json.decode(Workspace.self))
        case OType.tab: return .tab(try json.decode(Tab.self))
        case OType.layout: return .layout(try json.decode(LayoutState.self))
        case OType.block: return .block(try json.decode(Block.self))
        default: return nil
        }
    }

    // Typed extractors (nil if the case does not match).
    public var asClient: Client? { if case let .client(o) = self { return o }; return nil }
    public var asWindow: Window? { if case let .window(o) = self { return o }; return nil }
    public var asWorkspace: Workspace? { if case let .workspace(o) = self { return o }; return nil }
    public var asTab: Tab? { if case let .tab(o) = self { return o }; return nil }
    public var asLayout: LayoutState? { if case let .layout(o) = self { return o }; return nil }
    public var asBlock: Block? { if case let .block(o) = self { return o }; return nil }
}

/// `WaveObjUpdate` (`pkg/waveobj/wtype.go:50-55`). Carried both inline on every
/// HTTP `WebReturnType.updates` (GUARDS §B) and as the `waveobj:update` event
/// payload (PROTOCOL.md §2).
public struct WaveObjUpdate: Codable, Sendable {
    public var updatetype: String
    public var otype: String
    public var oid: String
    public var obj: JSONValue?

    public init(updatetype: String, otype: String, oid: String, obj: JSONValue? = nil) {
        self.updatetype = updatetype
        self.otype = otype
        self.oid = oid
        self.obj = obj
    }

    public var oref: ORef { ORef(otype: otype, oid: oid) }
    public var isDelete: Bool { updatetype == updateTypeDelete }

    /// Decode `obj` into a concrete `AnyWaveObj` (nil for deletes / unmodeled types).
    public func decodedObj() throws -> AnyWaveObj? {
        guard let obj, !obj.isNull else { return nil }
        return try AnyWaveObj.decode(otype: otype, from: obj)
    }
}
