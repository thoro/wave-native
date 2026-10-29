// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveCore — wire envelope + RPC/event/service payload types.
//
// Implements PROTOCOL.md §0 (HTTP service layer), §1 (RpcMessage, WS framing,
// ping/pong, auth, routing) and §2-§6 command payloads. Source of truth:
//   RpcMessage           `pkg/wshutil/wshrpc.go:127-139` (default timeout :28)
//   WS framing (asym)    out `frontend/app/store/ws.ts:247-254`
//                        in  `pkg/web/ws.go:288-294`; ping/pong `pkg/web/ws.go:148-177`
//   WebCallType/Return   `pkg/service/service.go:45-57`
//   UIContext            `pkg/waveobj/wtype.go:14-17`
//   WaveEvent/SubReq     `pkg/wps/wpstypes.go:61-77`
//   WSFileEventData/FileOp `pkg/wps/wpstypes.go:79-92`
//   WaveFile/FileOpts    `pkg/filestore/blockstore.go:54-83`, `pkg/wshrpc/wshrpctypes_file.go:74`
//   Command*Data         `pkg/wshrpc/wshrpctypes.go:268-349`
//
// GUARDS §A is encoded here: the WS framing is ASYMMETRIC (`WSRpcCommand` out,
// `WSRpcEvent` in) and ping must be answered with `WSPong`.

import Foundation

// MARK: - Protocol constants (PROTOCOL.md §1)

public enum WaveProtocolConst {
    /// `DefaultTimeoutMs` (`pkg/wshutil/wshrpc.go:28`).
    public static let defaultTimeoutMs: Int64 = 5000

    /// Auth header (`pkg/authkey/authkey.go:13`) and env var.
    public static let authKeyHeader = "X-AuthKey"
    public static let authKeyEnv = "WAVETERM_AUTH_KEY"
    /// Ask wavesrv to serve web+ws on unix domain sockets (no TCP port).
    public static let webUnixSocketEnv = "WAVETERM_WEB_UNIX_SOCKET"
    /// URL scheme marking a ws-over-unix-socket target (path = socket path).
    public static let unixWSScheme = "ws+unix"
    public static let dataHomeEnv = "WAVETERM_DATA_HOME"
    public static let configHomeEnv = "WAVETERM_CONFIG_HOME"

    /// Native-app version: env override + build-constant default. This gates the
    /// single-instance UPGRADE decision (a second launch with the SAME version asks
    /// the running instance to open a window and exits; a DIFFERENT version takes
    /// over and restarts wavesrv). Electron has no equivalent — its `second-instance`
    /// hook never compares versions. A fake version per build exercises the takeover
    /// path (see docs/LIVE-UPGRADE-TESTING.md).
    public static let nativeVersionEnv = "WAVE_NATIVE_VERSION"
    public static let defaultNativeVersion = "dev-1"

    /// The running native-app version: the `WAVE_NATIVE_VERSION` override, else the
    /// build-constant default.
    public static func nativeVersion() -> String {
        let env = ProcessInfo.processInfo.environment[nativeVersionEnv]
        if let env, !env.isEmpty { return env }
        return defaultNativeVersion
    }

    /// `WAVESRV-ESTART` stderr prefix (`cmd/server/main-server.go:611`).
    public static let eStartPrefix = "WAVESRV-ESTART"

    /// Circular terminal file name (`pkg/wavebase/wavebase.go:44`).
    public static let blockFileTerm = "term"

    /// HTTP service endpoint path (POST), PROTOCOL.md §0.
    public static let servicePath = "/wave/service"
    /// HTTP file backfill path (GET), PROTOCOL.md §4.
    public static let filePath = "/wave/file"
    /// File backfill response header carrying base64-JSON `WaveFile`.
    public static let zoneFileInfoHeader = "X-ZoneFileInfo"
    public static let lineInfoHeader = "X-WaveLineInfo"
}

/// Routing constants (`pkg/wshutil/wshrouter.go:24-41`, PROTOCOL.md §1).
public enum WaveRoute {
    /// The route to CALL for server RPCs.
    public static let defaultRoute = "wavesrv"
    /// Control channel for auth/announce.
    public static let controlRoute = "$control"

    public static func window(_ windowId: String) -> String { "window:\(windowId)" }
    public static func tab(_ tabId: String) -> String { "tab:\(tabId)" }
    public static func controller(_ blockId: String) -> String { "controller:\(blockId)" }
}

/// WPS event names (`pkg/wps/wpstypes.go:17-37`) used by this client.
public enum WaveEventName {
    public static let waveObjUpdate = "waveobj:update"
    public static let workspaceUpdate = "workspace:update"
    public static let blockFile = "blockfile"
    public static let config = "config"
    public static let connChange = "connchange"
    public static let userInput = "userinput"
    public static let badge = "badge"
}

/// File operations (`pkg/wps/wpstypes.go:79-85`).
public enum FileOp {
    public static let create = "create"
    public static let delete = "delete"
    public static let append = "append"
    public static let truncate = "truncate"
    public static let invalidate = "invalidate"
}

// MARK: - RpcMessage (`pkg/wshutil/wshrpc.go:127-139`)

/// The wire envelope for all wshrpc traffic. Fields use `omitempty` semantics
/// (nil optionals are omitted), matching the Go struct tags.
public struct RpcMessage: Codable, Sendable {
    public var command: String?
    public var reqid: String?
    public var resid: String?
    public var timeout: Int64?
    public var route: String?
    public var source: String?
    public var cont: Bool?
    public var cancel: Bool?
    public var error: String?
    public var datatype: String?
    public var data: JSONValue?

    public init(
        command: String? = nil, reqid: String? = nil, resid: String? = nil,
        timeout: Int64? = nil, route: String? = nil, source: String? = nil,
        cont: Bool? = nil, cancel: Bool? = nil, error: String? = nil,
        datatype: String? = nil, data: JSONValue? = nil
    ) {
        self.command = command
        self.reqid = reqid
        self.resid = resid
        self.timeout = timeout
        self.route = route
        self.source = source
        self.cont = cont
        self.cancel = cancel
        self.error = error
        self.datatype = datatype
        self.data = data
    }

    /// `IsRpcRequest` (`pkg/wshutil/wshrpc.go:141-143`).
    public var isRequest: Bool { (command?.isEmpty == false) || (reqid?.isEmpty == false) }
    /// A response is expected only when a `reqid` is present (GUARDS §A / PROTOCOL §1).
    public var wantsResponse: Bool { reqid?.isEmpty == false }
    /// `cont:true` => more stream chunks follow (GUARDS §A).
    public var isContinuation: Bool { cont == true }
    public var isCancel: Bool { cancel == true }
}

// MARK: - WS framing (ASYMMETRIC — GUARDS §A)

/// Outbound WS frame: `{ "wscommand":"rpc", "message": <RpcMessage> }`
/// (`frontend/app/store/ws.ts:247-254`).
public struct WSRpcCommand: Codable, Sendable {
    public var wscommand: String
    public var message: RpcMessage
    public init(message: RpcMessage) {
        self.wscommand = "rpc"
        self.message = message
    }
}

/// Inbound WS frame: `{ "eventtype":"rpc", "data": <RpcMessage> }`
/// (`pkg/web/ws.go:288-294`).
public struct WSRpcEvent: Codable, Sendable {
    public var eventtype: String
    public var data: RpcMessage
    public init(data: RpcMessage) {
        self.eventtype = "rpc"
        self.data = data
    }
}

/// Inbound keepalive: `{ "type":"ping", "stime": N }` (`pkg/web/ws.go:148-177`).
public struct WSPing: Codable, Sendable {
    public var type: String
    public var stime: Int64?
    public init(type: String = "ping", stime: Int64? = nil) {
        self.type = type
        self.stime = stime
    }
}

/// Outbound keepalive reply: `{ "type":"pong" }` — GUARDS §A: MUST send within 15s.
public struct WSPong: Codable, Sendable {
    public var type: String
    public init() { self.type = "pong" }
}

/// Generic peek at an inbound WS frame to discriminate rpc vs ping vs other.
public struct WSFramePeek: Codable, Sendable {
    public var eventtype: String?
    public var type: String?
}

// MARK: - HTTP service layer (`pkg/service/service.go:45-57`)

/// `UIContext` (`pkg/waveobj/wtype.go:14-17`).
public struct UIContext: Codable, Sendable {
    public var windowid: String
    public var activetabid: String
    public init(windowid: String, activetabid: String) {
        self.windowid = windowid
        self.activetabid = activetabid
    }
}

/// `WebCallType` (`pkg/service/service.go:45-50`) — POST body to `/wave/service`.
public struct WebCallType: Codable, Sendable {
    public var service: String
    public var method: String
    public var uicontext: UIContext?
    public var args: [JSONValue]

    public init(service: String, method: String, uicontext: UIContext? = nil, args: [JSONValue]) {
        self.service = service
        self.method = method
        self.uicontext = uicontext
        self.args = args
    }
}

/// `WebReturnType` (`pkg/service/service.go:52-57`). GUARDS §B: `updates` MUST be
/// applied to the object cache after every service call.
public struct WebReturnType: Codable, Sendable {
    public var success: Bool?
    public var error: String?
    public var data: JSONValue?
    public var updates: [WaveObjUpdate]?

    public init(
        success: Bool? = nil, error: String? = nil,
        data: JSONValue? = nil, updates: [WaveObjUpdate]? = nil
    ) {
        self.success = success
        self.error = error
        self.data = data
        self.updates = updates
    }
}

// MARK: - Events (`pkg/wps/wpstypes.go`)

/// `WaveEvent` (`pkg/wps/wpstypes.go:61-67`). Delivered via `eventrecv` (PROTOCOL §2).
public struct WaveEvent: Codable, Sendable {
    public var event: String
    public var scopes: [String]?
    public var sender: String?
    public var persist: Int?
    public var data: JSONValue?

    public init(
        event: String, scopes: [String]? = nil, sender: String? = nil,
        persist: Int? = nil, data: JSONValue? = nil
    ) {
        self.event = event
        self.scopes = scopes
        self.sender = sender
        self.persist = persist
        self.data = data
    }

    public func hasScope(_ scope: String) -> Bool { scopes?.contains(scope) ?? false }
}

/// `Badge` (`pkg/baseds/baseds.go`) — a transient block/tab attention marker set by
/// `wsh badge`. `badgeid` is a uuidv7, so its string order is creation order.
public struct Badge: Codable, Sendable, Equatable {
    public var badgeid: String
    public var icon: String
    public var color: String?
    public var priority: Double
    public var pidlinked: Bool?

    public init(badgeid: String, icon: String, color: String? = nil, priority: Double, pidlinked: Bool? = nil) {
        self.badgeid = badgeid
        self.icon = icon
        self.color = color
        self.priority = priority
        self.pidlinked = pidlinked
    }
}

/// `BadgeEvent` (`pkg/baseds/baseds.go`) — the `badge` WPS event payload and the
/// `getallbadges` snapshot row. Exactly one of clear/clearall/clearbyid/badge applies.
public struct BadgeEvent: Codable, Sendable, Equatable {
    public var oref: String
    public var clear: Bool?
    public var clearall: Bool?
    public var clearbyid: String?
    public var badge: Badge?

    public init(oref: String, clear: Bool? = nil, clearall: Bool? = nil, clearbyid: String? = nil, badge: Badge? = nil) {
        self.oref = oref
        self.clear = clear
        self.clearall = clearall
        self.clearbyid = clearbyid
        self.badge = badge
    }
}

/// `UserInputRequest` (`pkg/userinput/userinput.go:30-41`) — a backend prompt during
/// SSH connect (password / key passphrase / keyboard-interactive / unknown host key /
/// wsh install consent). Delivered as the `userinput` WPS event, scoped to the bare
/// window oid that owns the originating block (all windows on fallback).
public struct UserInputRequest: Codable, Sendable, Equatable {
    public var requestid: String
    public var querytext: String
    /// "text" (free/secret input) or "confirm" (yes/no).
    public var responsetype: String
    public var title: String
    public var markdown: Bool
    /// Frontend self-dismiss deadline; the backend enforces its own ctx timeout.
    public var timeoutms: Int
    /// Non-empty -> show a checkbox with this label (wsh install "for all connections").
    public var checkboxmsg: String
    /// true -> visible text input; false -> masked (password-style).
    public var publictext: Bool
    public var oklabel: String?
    public var cancellabel: String?

    public init(requestid: String, querytext: String, responsetype: String, title: String,
                markdown: Bool, timeoutms: Int, checkboxmsg: String, publictext: Bool,
                oklabel: String? = nil, cancellabel: String? = nil) {
        self.requestid = requestid
        self.querytext = querytext
        self.responsetype = responsetype
        self.title = title
        self.markdown = markdown
        self.timeoutms = timeoutms
        self.checkboxmsg = checkboxmsg
        self.publictext = publictext
        self.oklabel = oklabel
        self.cancellabel = cancellabel
    }
}

/// `UserInputResponse` (`pkg/userinput/userinput.go:43-50`) — sent back via the
/// `userinput` service `SendUserInputResponse`, matched by `requestid` (channel cap 1;
/// late/duplicate responses are silently dropped by the backend).
public struct UserInputResponse: Codable, Sendable, Equatable {
    public var type: String
    public var requestid: String
    public var text: String?
    public var confirm: Bool?
    /// Non-empty -> backend surfaces it as an error (the "user cancelled" path).
    public var errormsg: String?
    public var checkboxstat: Bool?

    public init(type: String, requestid: String, text: String? = nil, confirm: Bool? = nil,
                errormsg: String? = nil, checkboxstat: Bool? = nil) {
        self.type = type
        self.requestid = requestid
        self.text = text
        self.confirm = confirm
        self.errormsg = errormsg
        self.checkboxstat = checkboxstat
    }

    /// The decline/dismiss answer for `request`: confirm prompts answer "no"
    /// (`confirm:false`, how the backend expects a decline); text prompts have no
    /// "no", so they carry an errormsg that unblocks the backend with an error.
    public static func cancelled(for request: UserInputRequest) -> UserInputResponse {
        if request.responsetype == "confirm" {
            return UserInputResponse(type: request.responsetype, requestid: request.requestid, confirm: false)
        }
        return UserInputResponse(type: request.responsetype, requestid: request.requestid,
                                 errormsg: "user cancelled")
    }
}

/// `SubscriptionRequest` (`pkg/wps/wpstypes.go:73-77`). GUARDS §B: `scopes` are
/// oref strings (e.g. `workspace:<oid>`), not bare ids.
public struct SubscriptionRequest: Codable, Sendable {
    public var event: String
    public var scopes: [String]?
    public var allscopes: Bool?

    public init(event: String, scopes: [String]? = nil, allscopes: Bool? = nil) {
        self.event = event
        self.scopes = scopes
        self.allscopes = allscopes
    }
}

/// `WSFileEventData` (`pkg/wps/wpstypes.go:87-92`) — payload of a `blockfile` event.
/// GUARDS §T: `data64` is std base64; `fileop` is one of `FileOp.*`.
public struct WSFileEventData: Codable, Sendable {
    public var zoneid: String
    public var filename: String
    public var fileop: String
    public var data64: String

    public init(zoneid: String, filename: String, fileop: String, data64: String) {
        self.zoneid = zoneid
        self.filename = filename
        self.fileop = fileop
        self.data64 = data64
    }
}

// MARK: - Filestore (`pkg/filestore/blockstore.go:54-83`)

/// `FileOpts` (`pkg/wshrpc/wshrpctypes_file.go:74-81`).
public struct FileOpts: Codable, Sendable {
    public var maxsize: Int64?
    public var circular: Bool?
    public var ijson: Bool?
    public var ijsonbudget: Int?
    public var truncate: Bool?
    public var append: Bool?
    public var compressed: Bool?
    public var segmented: Bool?

    public init(
        maxsize: Int64? = nil, circular: Bool? = nil, ijson: Bool? = nil,
        ijsonbudget: Int? = nil, truncate: Bool? = nil, append: Bool? = nil,
        compressed: Bool? = nil, segmented: Bool? = nil
    ) {
        self.maxsize = maxsize
        self.circular = circular
        self.ijson = ijson
        self.ijsonbudget = ijsonbudget
        self.truncate = truncate
        self.append = append
        self.compressed = compressed
        self.segmented = segmented
    }
}

/// `WaveFile` (`pkg/filestore/blockstore.go:54-65`) — decoded from the base64-JSON
/// `X-ZoneFileInfo` header on the file-backfill GET (PROTOCOL §4).
public struct WaveFile: Codable, Sendable {
    public var zoneid: String
    public var name: String
    public var opts: FileOpts
    public var createdts: Int64
    public var size: Int64
    public var modts: Int64
    public var meta: MetaMapType?

    public init(
        zoneid: String, name: String, opts: FileOpts, createdts: Int64,
        size: Int64, modts: Int64, meta: MetaMapType? = nil
    ) {
        self.zoneid = zoneid
        self.name = name
        self.opts = opts
        self.createdts = createdts
        self.size = size
        self.modts = modts
        self.meta = meta
    }

    /// `DataLength` (`pkg/filestore/blockstore.go:69-77`): for circular and
    /// segmented files, the number of currently retained bytes.
    public var dataLength: Int64 {
        if opts.circular == true, let max = opts.maxsize {
            return Swift.min(size, max)
        }
        if opts.segmented == true {
            return size - dataStartIdx
        }
        return size
    }

    /// `DataStartIdx` (`pkg/filestore/blockstore.go:84-97`): the absolute index of
    /// the first byte still retained — the circular start clamp (GUARDS §T), or
    /// for segmented files the first byte of the oldest retained 64KB part.
    public var dataStartIdx: Int64 {
        if opts.circular == true, let max = opts.maxsize, size > max {
            return size - max
        }
        if opts.segmented == true, let max = opts.maxsize, max > 0, size > 0 {
            let partDataSize: Int64 = 65536
            let maxParts = max / partDataSize
            let firstSeg = (size - 1) / partDataSize + 1 - maxParts
            if firstSeg > 0 {
                return firstSeg * partDataSize
            }
        }
        return 0
    }
}

// MARK: - Command payloads (`pkg/wshrpc/wshrpctypes.go`)

/// `CommandGetMetaData` (`:268-270`).
public struct CommandGetMetaData: Codable, Sendable {
    public var oref: ORef
    public init(oref: ORef) { self.oref = oref }
}

/// `CommandSetMetaData` (`:272-275`).
public struct CommandSetMetaData: Codable, Sendable {
    public var oref: ORef
    public var meta: MetaMapType
    public init(oref: ORef, meta: MetaMapType) {
        self.oref = oref
        self.meta = meta
    }
}

/// `CommandMoveTabData` (`:277-281`). GUARDS §C: never move the last tab out.
public struct CommandMoveTabData: Codable, Sendable {
    public var sourceworkspaceid: String
    public var destworkspaceid: String
    public var tabid: String
    public init(sourceworkspaceid: String, destworkspaceid: String, tabid: String) {
        self.sourceworkspaceid = sourceworkspaceid
        self.destworkspaceid = destworkspaceid
        self.tabid = tabid
    }
}

/// `CommandMoveBlockToTabData` — move a pane (top-level block) into another tab.
public struct CommandMoveBlockToTabData: Codable, Sendable {
    public var blockid: String
    public var targettabid: String
    public init(blockid: String, targettabid: String) {
        self.blockid = blockid
        self.targettabid = targettabid
    }
}

/// `CommandResolveIdsData` (`:283-286`).
public struct CommandResolveIdsData: Codable, Sendable {
    public var blockid: String
    public var ids: [String]
    public init(blockid: String, ids: [String]) {
        self.blockid = blockid
        self.ids = ids
    }
}

/// `CommandResolveIdsRtnData` (`:288-290`).
public struct CommandResolveIdsRtnData: Codable, Sendable {
    public var resolvedids: [String: ORef]
    public init(resolvedids: [String: ORef]) { self.resolvedids = resolvedids }
}

/// `CommandCreateBlockData` (`:292-301`).
public struct CommandCreateBlockData: Codable, Sendable {
    public var tabid: String
    public var blockdef: BlockDef?
    public var rtopts: RuntimeOpts?
    public var magnified: Bool?
    public var ephemeral: Bool?
    public var focused: Bool?
    public var targetblockid: String?
    public var targetaction: String?

    public init(
        tabid: String, blockdef: BlockDef? = nil, rtopts: RuntimeOpts? = nil,
        magnified: Bool? = nil, ephemeral: Bool? = nil, focused: Bool? = nil,
        targetblockid: String? = nil, targetaction: String? = nil
    ) {
        self.tabid = tabid
        self.blockdef = blockdef
        self.rtopts = rtopts
        self.magnified = magnified
        self.ephemeral = ephemeral
        self.focused = focused
        self.targetblockid = targetblockid
        self.targetaction = targetaction
    }
}

/// `CommandControllerResyncData` (`:308-313`). PROTOCOL §4: start/create/restart.
/// GUARDS §T: send `rtopts.termsize` on Resync.
public struct CommandControllerResyncData: Codable, Sendable {
    public var forcerestart: Bool?
    public var tabid: String
    public var blockid: String
    public var rtopts: RuntimeOpts?

    public init(
        forcerestart: Bool? = nil, tabid: String, blockid: String, rtopts: RuntimeOpts? = nil
    ) {
        self.forcerestart = forcerestart
        self.tabid = tabid
        self.blockid = blockid
        self.rtopts = rtopts
    }
}

/// `CommandBlockInputData` (`:320-325`). GUARDS §T: `inputdata64` is std base64.
public struct CommandBlockInputData: Codable, Sendable {
    public var blockid: String
    public var inputdata64: String?
    public var signame: String?
    public var termsize: TermSize?

    public init(
        blockid: String, inputdata64: String? = nil,
        signame: String? = nil, termsize: TermSize? = nil
    ) {
        self.blockid = blockid
        self.inputdata64 = inputdata64
        self.signame = signame
        self.termsize = termsize
    }
}

/// `CommandDeleteBlockData` (`:341-343`).
public struct CommandDeleteBlockData: Codable, Sendable {
    public var blockid: String
    public init(blockid: String) { self.blockid = blockid }
}

/// `CommandTermSearchScrollbackData` (`pkg/wshrpc/wshrpctypes.go`, cmd
/// "termsearchscrollback") — full on-disk scrollback substring search.
public struct CommandTermSearchScrollbackData: Codable, Sendable {
    public var blockid: String
    public var query: String
    public var casesensitive: Bool?
    public var maxresults: Int?
    public init(blockid: String, query: String, casesensitive: Bool? = nil, maxresults: Int? = nil) {
        self.blockid = blockid
        self.query = query
        self.casesensitive = casesensitive
        self.maxresults = maxresults
    }
}

/// `TermSearchMatch` — one search hit. `offset` is the raw term-file byte
/// offset of the matched line's start; `line` is its retained-relative logical
/// line number (raw-\n space, matching the filestore line index).
public struct TermSearchMatch: Codable, Sendable, Equatable {
    public var offset: Int64
    public var line: Int64
    public var linetext: String
    public init(offset: Int64, line: Int64, linetext: String) {
        self.offset = offset
        self.line = line
        self.linetext = linetext
    }
}

/// `CommandTermSearchScrollbackRtnData`.
public struct CommandTermSearchScrollbackRtnData: Codable, Sendable {
    public var matches: [TermSearchMatch]?
    public var truncated: Bool?
    public var filesize: Int64?
    public var datastartidx: Int64?
    public var totallines: Int64?
    public init(
        matches: [TermSearchMatch]? = nil, truncated: Bool? = nil, filesize: Int64? = nil,
        datastartidx: Int64? = nil, totallines: Int64? = nil
    ) {
        self.matches = matches
        self.truncated = truncated
        self.filesize = filesize
        self.datastartidx = datastartidx
        self.totallines = totallines
    }
}

/// `CommandTermGetRunningCommandsData` (cmd "termgetrunningcommands") — scope
/// selector for the "is an application still running here?" close check.
/// Exactly one of the fields is set: a whole workspace (window close), one
/// tab, or a single block.
public struct CommandTermGetRunningCommandsData: Codable, Sendable {
    public var workspaceid: String?
    public var tabid: String?
    public var blockid: String?
    public init(workspaceid: String? = nil, tabid: String? = nil, blockid: String? = nil) {
        self.workspaceid = workspaceid
        self.tabid = tabid
        self.blockid = blockid
    }
}

/// `TermRunningCommand` — one child process still running under a local shell.
public struct TermRunningCommand: Codable, Sendable, Equatable {
    public var blockid: String
    public var pid: Int
    public var command: String
    public init(blockid: String, pid: Int, command: String) {
        self.blockid = blockid
        self.pid = pid
        self.command = command
    }
}

/// `TermScrollbackEntry` (cmd "termscrollbacklist") — one stored term buffer.
public struct TermScrollbackEntry: Codable, Sendable, Equatable {
    public var workspaceid: String?
    public var workspacename: String?
    public var tabid: String?
    public var tabname: String?
    public var blockid: String
    public var view: String?
    public var controller: String?
    public var connection: String?
    public var size: Int64?
    public var disksize: Int64?
    public var unlimited: Bool?
    public var orphaned: Bool?
    public init(
        workspaceid: String? = nil, workspacename: String? = nil, tabid: String? = nil,
        tabname: String? = nil, blockid: String, view: String? = nil, controller: String? = nil,
        connection: String? = nil, size: Int64? = nil, disksize: Int64? = nil,
        unlimited: Bool? = nil, orphaned: Bool? = nil
    ) {
        self.workspaceid = workspaceid
        self.workspacename = workspacename
        self.tabid = tabid
        self.tabname = tabname
        self.blockid = blockid
        self.view = view
        self.controller = controller
        self.connection = connection
        self.size = size
        self.disksize = disksize
        self.unlimited = unlimited
        self.orphaned = orphaned
    }
}

/// `CommandEventReadHistoryData` (`:345-349`).
public struct CommandEventReadHistoryData: Codable, Sendable {
    public var event: String
    public var scope: String
    public var maxitems: Int
    public init(event: String, scope: String, maxitems: Int) {
        self.event = event
        self.scope = scope
        self.maxitems = maxitems
    }
}

// MARK: - Connection payloads (`pkg/wshrpc/wshrpctypes.go`)

/// Connection status string constants (`pkg/wslconn/wslconn.go:37-41`, shared by the
/// SSH conncontroller). Not a Go enum — plain strings on the wire.
public enum ConnStatusValue {
    public static let initialized = "init"
    public static let connecting = "connecting"
    public static let connected = "connected"
    public static let disconnected = "disconnected"
    public static let error = "error"
}

/// `ConnStatus` (`pkg/wshrpc/wshrpctypes.go:423`) — payload of the `connchange`
/// event and the `connstatus` RPC. Only the fields the chrome needs are modeled;
/// the rest (wshversion, keepalive timings) are decoded leniently as optionals.
public struct ConnStatus: Codable, Sendable, Equatable {
    public var status: String
    public var connection: String
    public var connected: Bool
    public var hasconnected: Bool
    public var activeconnnum: Int
    public var error: String?
    public var wsherror: String?
    public var connhealthstatus: String?
    public var wshenabled: Bool?

    public init(
        status: String, connection: String, connected: Bool = false,
        hasconnected: Bool = false, activeconnnum: Int = 0, error: String? = nil,
        wsherror: String? = nil, connhealthstatus: String? = nil, wshenabled: Bool? = nil
    ) {
        self.status = status
        self.connection = connection
        self.connected = connected
        self.hasconnected = hasconnected
        self.activeconnnum = activeconnnum
        self.error = error
        self.wsherror = wsherror
        self.connhealthstatus = connhealthstatus
        self.wshenabled = wshenabled
    }
}

/// `ConnRequest` (`pkg/wshrpc/wshrpctypes.go:376`). `keywords` is omitted — the
/// chrome connects by host only, letting the backend resolve ssh-config keywords.
public struct ConnRequest: Codable, Sendable {
    public var host: String
    public var logblockid: String?
    public init(host: String, logblockid: String? = nil) {
        self.host = host
        self.logblockid = logblockid
    }
}

/// `ConnExtData` (`pkg/wshrpc/wshrpctypes.go:613`) — arg to `connensure`.
public struct ConnExtData: Codable, Sendable {
    public var connname: String
    public var logblockid: String?
    public init(connname: String, logblockid: String? = nil) {
        self.connname = connname
        self.logblockid = logblockid
    }
}
