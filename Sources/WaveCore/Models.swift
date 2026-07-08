// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveCore — Wave Object Store (WOS) model types.
//
// Implements PROTOCOL.md §2 ("Object types"), field-for-field from the Go source
// of truth `pkg/waveobj/wtype.go` (Client :131, Window :147, Workspace :174,
// Tab :189, LayoutState :228, Block :286, LayoutActionData :210, LeafOrderEntry
// :223, Point/WinSize/RuntimeOpts/TermSize) and the layout node tree from the
// frontend (`frontend/layout/lib/types.ts:296-302`, leaf payload
// `frontend/types/custom.d.ts:52-54`).
//
// JSON field naming: all wire keys are lowercase without underscores
// (project rule). The layout NODE tree is the one exception — it is written by
// the FE in camelCase (`blockId`, `flexDirection`), so `LayoutNode`/`TabLayoutData`
// use explicit CodingKeys.
//
// GUARDS §B: there is NO `Workspace.pinnedtabids` — tab order lives in `tabids`.

import Foundation

// MARK: - Geometry / sizing (`pkg/waveobj/wtype.go:276-284, 370-373`)

public struct Point: Codable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

public struct WinSize: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

/// Terminal grid size (`pkg/waveobj/wtype.go:370-373`).
/// GUARDS §T default: `{rows:25, cols:80}` when unknown.
public struct TermSize: Codable, Hashable, Sendable {
    public var rows: Int
    public var cols: Int
    public init(rows: Int, cols: Int) { self.rows = rows; self.cols = cols }

    /// Backend default (`blockcontroller.go:358-367`).
    public static let `default` = TermSize(rows: 25, cols: 80)
}

/// `RuntimeOpts` (`pkg/waveobj/wtype.go:271-274`) — carried on Resync / CreateBlock.
public struct RuntimeOpts: Codable, Hashable, Sendable {
    public var termsize: TermSize?
    public var winsize: WinSize?
    public init(termsize: TermSize? = nil, winsize: WinSize? = nil) {
        self.termsize = termsize
        self.winsize = winsize
    }
}

// MARK: - Block definition (`pkg/waveobj/wtype.go:243-251`)

public struct FileDef: Codable, Sendable {
    public var content: String?
    public var meta: MetaMapType?
    public init(content: String? = nil, meta: MetaMapType? = nil) {
        self.content = content
        self.meta = meta
    }
}

public struct BlockDef: Codable, Sendable {
    public var files: [String: FileDef]?
    public var meta: MetaMapType?
    public init(files: [String: FileDef]? = nil, meta: MetaMapType? = nil) {
        self.files = files
        self.meta = meta
    }
}

// MARK: - Wave objects (all share oid / version / meta)

/// `Client` (`pkg/waveobj/wtype.go:131-140`).
public struct Client: Codable, Sendable, Equatable {
    public var oid: String
    public var version: Int
    @NullableStringArray public var windowids: [String]
    @NullableMeta public var meta: MetaMapType
    public var tosagreed: Int64?
    public var hasoldhistory: Bool?
    public var tempoid: String?
    public var installid: String?

    public init(
        oid: String, version: Int, windowids: [String], meta: MetaMapType,
        tosagreed: Int64? = nil, hasoldhistory: Bool? = nil,
        tempoid: String? = nil, installid: String? = nil
    ) {
        self.oid = oid
        self.version = version
        self.windowids = windowids
        self.meta = meta
        self.tosagreed = tosagreed
        self.hasoldhistory = hasoldhistory
        self.tempoid = tempoid
        self.installid = installid
    }
}

/// `Window` (`pkg/waveobj/wtype.go:147-156`).
public struct Window: Codable, Sendable, Equatable {
    public var oid: String
    public var version: Int
    public var workspaceid: String
    public var isnew: Bool?
    public var pos: Point
    public var winsize: WinSize
    public var lastfocusts: Int64
    @NullableMeta public var meta: MetaMapType

    public init(
        oid: String, version: Int, workspaceid: String, isnew: Bool? = nil,
        pos: Point, winsize: WinSize, lastfocusts: Int64, meta: MetaMapType
    ) {
        self.oid = oid
        self.version = version
        self.workspaceid = workspaceid
        self.isnew = isnew
        self.pos = pos
        self.winsize = winsize
        self.lastfocusts = lastfocusts
        self.meta = meta
    }
}

/// `Workspace` (`pkg/waveobj/wtype.go:174-183`). NB GUARDS §B: tab order is
/// `tabids`; there is no `pinnedtabids`.
public struct Workspace: Codable, Sendable, Equatable {
    public var oid: String
    public var version: Int
    public var name: String?
    public var icon: String?
    public var color: String?
    @NullableStringArray public var tabids: [String]
    public var activetabid: String
    @NullableMeta public var meta: MetaMapType

    public init(
        oid: String, version: Int, name: String? = nil, icon: String? = nil,
        color: String? = nil, tabids: [String], activetabid: String, meta: MetaMapType
    ) {
        self.oid = oid
        self.version = version
        self.name = name
        self.icon = icon
        self.color = color
        self.tabids = tabids
        self.activetabid = activetabid
        self.meta = meta
    }
}

/// `Tab` (`pkg/waveobj/wtype.go:189-196`). `layoutstate` is a *string oref*
/// pointing at a separate `LayoutState` object (GUARDS §L).
public struct Tab: Codable, Sendable, Equatable {
    public var oid: String
    public var version: Int
    public var name: String
    public var layoutstate: String
    @NullableStringArray public var blockids: [String]
    @NullableMeta public var meta: MetaMapType

    public init(
        oid: String, version: Int, name: String, layoutstate: String,
        blockids: [String], meta: MetaMapType
    ) {
        self.oid = oid
        self.version = version
        self.name = name
        self.layoutstate = layoutstate
        self.blockids = blockids
        self.meta = meta
    }

    /// The `LayoutState` oref referenced by this tab, if any. The real backend
    /// stores `layoutstate` as a BARE oid (UUID), but tolerate a full
    /// `"layout:<oid>"` string too. (`pkg/waveobj/wtype.go` Tab.LayoutState.)
    public var layoutStateORef: ORef? {
        guard !layoutstate.isEmpty else { return nil }
        if let ref = ORef(string: layoutstate), ref.otype == OType.layout { return ref }
        return ORef(otype: OType.layout, oid: layoutstate)
    }

    /// Block orefs for this tab (`GetBlockORefs`, `pkg/waveobj/wtype.go:202-208`).
    public var blockORefs: [ORef] { blockids.map { ORef.block($0) } }
}

/// `Block` (`pkg/waveobj/wtype.go:286-295`). A web block is just a `Block` whose
/// `meta["view"] == "web"` (PROTOCOL.md §5).
public struct Block: Codable, Sendable, Equatable {
    public var oid: String
    public var parentoref: String?
    public var version: Int
    public var runtimeopts: RuntimeOpts?
    public var stickers: [JSONValue]?
    @NullableMeta public var meta: MetaMapType
    public var subblockids: [String]?
    public var jobid: String?

    public init(
        oid: String, parentoref: String? = nil, version: Int,
        runtimeopts: RuntimeOpts? = nil, stickers: [JSONValue]? = nil,
        meta: MetaMapType, subblockids: [String]? = nil, jobid: String? = nil
    ) {
        self.oid = oid
        self.parentoref = parentoref
        self.version = version
        self.runtimeopts = runtimeopts
        self.stickers = stickers
        self.meta = meta
        self.subblockids = subblockids
        self.jobid = jobid
    }

    /// `meta["view"]` (`pkg/waveobj/metaconsts.go:9`) — e.g. `"term"`, `"web"`.
    public var view: String? { meta["view"]?.stringValue }
}

// MARK: - Layout (PROTOCOL.md §6, GUARDS §L)

/// `LayoutActionData` (`pkg/waveobj/wtype.go:210-221`). Backend->client structural
/// changes ride `LayoutState.pendingbackendactions`.
public struct LayoutActionData: Codable, Sendable, Equatable {
    public var actiontype: String
    public var actionid: String?
    public var blockid: String
    public var nodesize: UInt?
    public var indexarr: [Int]?
    public var focused: Bool?
    public var magnified: Bool?
    public var ephemeral: Bool?
    public var targetblockid: String?
    public var position: String?

    public init(
        actiontype: String, actionid: String? = nil, blockid: String,
        nodesize: UInt? = nil, indexarr: [Int]? = nil, focused: Bool? = nil,
        magnified: Bool? = nil, ephemeral: Bool? = nil,
        targetblockid: String? = nil, position: String? = nil
    ) {
        self.actiontype = actiontype
        self.actionid = actionid
        self.blockid = blockid
        self.nodesize = nodesize
        self.indexarr = indexarr
        self.focused = focused
        self.magnified = magnified
        self.ephemeral = ephemeral
        self.targetblockid = targetblockid
        self.position = position
    }
}

/// `LeafOrderEntry` (`pkg/waveobj/wtype.go:223-226`).
public struct LeafOrderEntry: Codable, Sendable, Equatable {
    public var nodeid: String
    public var blockid: String
    public init(nodeid: String, blockid: String) {
        self.nodeid = nodeid
        self.blockid = blockid
    }
}

/// Leaf payload of a layout node (`frontend/types/custom.d.ts:52-54`).
/// NOTE camelCase wire key `blockId`.
public struct TabLayoutData: Codable, Sendable, Equatable, Hashable {
    public var blockId: String
    public init(blockId: String) { self.blockId = blockId }

    enum CodingKeys: String, CodingKey { case blockId }
}

/// Layout flex direction (`frontend/layout/lib/types.ts:41-44`).
public enum FlexDirection: String, Codable, Sendable {
    case row
    case column
}

/// A node in the layout tree (`frontend/layout/lib/types.ts:296-302`).
/// GUARDS §L: `size` defaults to `10`; `flexDirection` is `"row"|"column"`.
/// NOTE camelCase wire keys (the FE writes this object).
public struct LayoutNode: Codable, Sendable, Equatable {
    public var id: String
    public var data: TabLayoutData?
    public var children: [LayoutNode]?
    public var flexDirection: FlexDirection
    public var size: Double

    public static let defaultSize: Double = 10

    public init(
        id: String, data: TabLayoutData? = nil, children: [LayoutNode]? = nil,
        flexDirection: FlexDirection = .row, size: Double = LayoutNode.defaultSize
    ) {
        self.id = id
        self.data = data
        self.children = children
        self.flexDirection = flexDirection
        self.size = size
    }

    enum CodingKeys: String, CodingKey {
        case id, data, children, flexDirection, size
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        data = try c.decodeIfPresent(TabLayoutData.self, forKey: .data)
        children = try c.decodeIfPresent([LayoutNode].self, forKey: .children)
        flexDirection = try c.decodeIfPresent(FlexDirection.self, forKey: .flexDirection) ?? .row
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? LayoutNode.defaultSize
    }
}

/// `LayoutState` (`pkg/waveobj/wtype.go:228-237`). A SEPARATE WaveObj referenced
/// by `Tab.layoutstate` (GUARDS §L). `rootnode` is `any` on the wire; decode it
/// into a `LayoutNode` via `rootLayoutNode` when needed.
public struct LayoutState: Codable, Sendable {
    public var oid: String
    public var version: Int
    public var rootnode: JSONValue?
    public var magnifiednodeid: String?
    public var focusednodeid: String?
    public var leaforder: [LeafOrderEntry]?
    public var pendingbackendactions: [LayoutActionData]?
    public var meta: MetaMapType?

    public init(
        oid: String, version: Int, rootnode: JSONValue? = nil,
        magnifiednodeid: String? = nil, focusednodeid: String? = nil,
        leaforder: [LeafOrderEntry]? = nil,
        pendingbackendactions: [LayoutActionData]? = nil, meta: MetaMapType? = nil
    ) {
        self.oid = oid
        self.version = version
        self.rootnode = rootnode
        self.magnifiednodeid = magnifiednodeid
        self.focusednodeid = focusednodeid
        self.leaforder = leaforder
        self.pendingbackendactions = pendingbackendactions
        self.meta = meta
    }

    /// Decode `rootnode` (`any`) into a typed `LayoutNode`.
    public var rootLayoutNode: LayoutNode? {
        guard let rootnode, !rootnode.isNull else { return nil }
        return try? rootnode.decode(LayoutNode.self)
    }

    /// Set `rootnode` from a typed `LayoutNode`.
    public mutating func setRootLayoutNode(_ node: LayoutNode?) throws {
        guard let node else { rootnode = nil; return }
        rootnode = try JSONValue.encode(node)
    }
}
