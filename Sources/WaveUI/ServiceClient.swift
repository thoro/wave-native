// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveUI — thin HTTP-service helper for the window/tab/workspace lifecycle the
// chrome drives directly.
//
// Implements PROTOCOL.md §0 (HTTP "service" layer) + §3 (window/workspace/tab/
// block RPCs) and ENFORCES GUARDS §B: every `WebReturnType.updates` is fed into
// the SAME object store used by events, after every service call.
//
// NB: typed RPC wrappers ideally live in `WaveCommands`, but that module is still
// a placeholder (no public API). The chrome needs exactly the few calls below, so
// we issue them over `WaveTransport.callService` here. When `WaveCommands` lands,
// these should move there. (Flagged in the module report.)

import Foundation
import WaveCore
import WaveCommands

/// Service names registered by wavesrv (`pkg/service/service.go:24-31`).
enum WaveService {
    static let client = "client"
    static let object = "object"
    static let window = "window"
    static let workspace = "workspace"
    static let userInput = "userinput"
    static let block = "block"
}

/// wshrpc command strings (`pkg/wshrpc/wshrpctypes_const.go`,
/// `pkg/wshrpc/wshclient/wshclient.go`).
enum WaveCommand {
    static let getFullConfig = "getfullconfig"
    static let setMeta = "setmeta"
    static let resolveIds = "resolveids"
    static let controllerResync = "controllerresync"
    static let controllerInput = "controllerinput"
    static let eventReadHistory = "eventreadhistory"
    static let setConfig = "setconfig"
}

/// Minimal `wshrpc.FileInfo` (`pkg/wshrpc/wshrpctypes_file.go:56`) — only `path` is
/// needed to address a local config file for read/write.
public struct FileInfoArg: Codable, Sendable, Equatable {
    public var path: String
    public init(path: String) { self.path = path }
}

/// Minimal `wshrpc.FileData` (`pkg/wshrpc/wshrpctypes_file.go:49`) — the `fileread` /
/// `filewrite` payload. Whole-file: `data64` is the std-base64 of the file bytes (the
/// same contract Electron's config editor uses, `waveconfig-model.ts`).
public struct FileDataArg: Codable, Sendable, Equatable {
    /// Optional to match the Go `omitempty`: present on the requests we SEND (addresses
    /// the file), and tolerated as absent when decoding a read RESULT (we only read data64).
    public var info: FileInfoArg?
    public var data64: String?
    public init(info: FileInfoArg?, data64: String? = nil) {
        self.info = info
        self.data64 = data64
    }
}

/// Minimal decode of `waveobj.Job` (`pkg/waveobj/wtype.go:313`) — only the `oid`
/// is needed to address a job-manager for termination. Unknown JSON keys are
/// ignored by the synthesized decoder, so the many other Job fields are skipped.
public struct JobInfo: Codable, Sendable, Equatable {
    public var oid: String
    /// Conn the job's manager runs under ("local" or an ssh name).
    public var connection: String? = nil
    /// "shell" or "task" (`pkg/waveobj/wtype.go` Job.JobKind).
    public var jobkind: String? = nil
    public var cmd: String? = nil
    /// The block this job streams into; empty/nil when detached.
    public var attachedblockid: String? = nil
    /// "init" / "running" / "done".
    public var jobmanagerstatus: String? = nil
    public init(oid: String) { self.oid = oid }
}

/// `CommandJobControllerAttachJobData` (`pkg/wshrpc/wshrpctypes.go:883`).
public struct JobAttachData: Codable, Sendable, Equatable {
    public var jobid: String
    public var blockid: String
    public init(jobid: String, blockid: String) {
        self.jobid = jobid
        self.blockid = blockid
    }
}

/// `WorkspaceListEntry` (`pkg/waveobj/wtype.go:162-167`) — return shape of
/// `WorkspaceService.ListWorkspaces`. Not a `WaveObj`, so it lives here.
public struct WorkspaceListEntry: Codable, Sendable, Equatable {
    public var workspaceid: String
    public var windowid: String
    public init(workspaceid: String, windowid: String) {
        self.workspaceid = workspaceid
        self.windowid = windowid
    }
}

/// `CloseTabRtnType` (`pkg/service/workspaceservice/workspaceservice.go:205-208`).
/// GUARDS §C: if `closewindow` is set, close the window; else switch to
/// `newactivetabid`.
public struct CloseTabResult: Codable, Sendable, Equatable {
    public var closewindow: Bool?
    public var newactivetabid: String?
    public init(closewindow: Bool? = nil, newactivetabid: String? = nil) {
        self.closewindow = closewindow
        self.newactivetabid = newactivetabid
    }
}

/// Issues HTTP service calls and applies the returned `updates` into the store.
/// This is the single chokepoint that upholds GUARDS §B for the chrome's mutations.
final class ServiceClient: Sendable {
    private let transport: WaveTransport
    private let store: ObjectStoreProtocol

    init(transport: WaveTransport, store: ObjectStoreProtocol) {
        self.transport = transport
        self.store = store
    }

    /// Run a service call, apply its `updates` (GUARDS §B), and surface any error.
    @discardableResult
    func call(_ webCall: WebCallType) async throws -> WebReturnType {
        let result = try await transport.callService(webCall)
        // GUARDS §B: apply inline updates from EVERY service response.
        if let updates = result.updates, !updates.isEmpty {
            store.applyUpdates(updates)
        }
        if let err = result.error, !err.isEmpty {
            throw WaveError.rpc(err)
        }
        if result.success == false {
            throw WaveError.rpc("service call \(webCall.service).\(webCall.method) reported failure")
        }
        return result
    }

    // MARK: Client

    /// `client.GetClientData()` → the singleton `Client` (PROTOCOL §7 step 2).
    func getClientData() async throws -> Client {
        let result = try await call(WebCallType(service: WaveService.client, method: "GetClientData", args: []))
        guard let data = result.data, !data.isNull else {
            throw WaveError.decoding("GetClientData returned no data")
        }
        return try data.decode(Client.self)
    }

    // MARK: Workspace / Tab

    /// `workspace.ListWorkspaces()` (PROTOCOL §3).
    func listWorkspaces() async throws -> [WorkspaceListEntry] {
        let result = try await call(WebCallType(service: WaveService.workspace, method: "ListWorkspaces", args: []))
        guard let data = result.data, !data.isNull else { return [] }
        return try data.decode([WorkspaceListEntry].self)
    }

    /// `workspace.UpdateWorkspace(workspaceId, name, icon, color, applyDefaults)`
    /// (`pkg/service/workspaceservice/workspaceservice.go:45`). The single persist
    /// path for a workspace's name/icon/color — empty strings leave a field unchanged
    /// (unless `applyDefaults` fills a blank one). The backend broadcasts
    /// `workspace:update`, so every window's switcher refreshes via the existing
    /// subscription (no inline updates to act on here). The leading `ctx` arg is
    /// injected by the service layer and omitted from `args`.
    func updateWorkspace(
        workspaceId: String, name: String, icon: String, color: String, applyDefaults: Bool
    ) async throws {
        try await call(WebCallType(
            service: WaveService.workspace, method: "UpdateWorkspace",
            args: [.string(workspaceId), .string(name), .string(icon), .string(color), .bool(applyDefaults)]
        ))
    }

    /// `workspace.DeleteWorkspace(workspaceId)` — deletes the workspace and its tabs.
    /// The backend broadcasts the resulting object updates (applied by `call`).
    func deleteWorkspace(workspaceId: String) async throws {
        try await call(WebCallType(
            service: WaveService.workspace, method: "DeleteWorkspace",
            args: [.string(workspaceId)]
        ))
    }

    /// `workspace.SaveWorkspaceLayout(workspaceId)` — snapshot the workspace's current
    /// tabs + panes into its own meta (`Workspace.Meta["workspace:savedlayout"]`). The
    /// backend broadcasts the workspace update (applied by `call`).
    func saveWorkspaceLayout(workspaceId: String) async throws {
        try await call(WebCallType(
            service: WaveService.workspace, method: "SaveWorkspaceLayout",
            args: [.string(workspaceId)]
        ))
    }

    /// `workspace.RestoreWorkspaceLayout(workspaceId)` — rebuild the workspace to its
    /// saved snapshot (wipe & recreate), force-closing drifted tabs/panes. The backend
    /// broadcasts the resulting object updates (applied by `call`).
    func restoreWorkspaceLayout(workspaceId: String) async throws {
        try await call(WebCallType(
            service: WaveService.workspace, method: "RestoreWorkspaceLayout",
            args: [.string(workspaceId)]
        ))
    }

    /// `workspace.GetColors()` — the 7 selectable workspace hex colors
    /// (`wcore.WorkspaceColors`). Static data; callers cache the result.
    func getColors() async throws -> [String] {
        let result = try await call(WebCallType(service: WaveService.workspace, method: "GetColors", args: []))
        guard let data = result.data, !data.isNull else { return [] }
        return try data.decode([String].self)
    }

    /// `workspace.GetIcons()` — the 14 selectable workspace icon names
    /// (`wcore.WorkspaceIcons`). Static data; callers cache the result.
    func getIcons() async throws -> [String] {
        let result = try await call(WebCallType(service: WaveService.workspace, method: "GetIcons", args: []))
        guard let data = result.data, !data.isNull else { return [] }
        return try data.decode([String].self)
    }

    /// `workspace.SetActiveTab(workspaceId, tabId)` — GUARDS §C: this is the
    /// trigger that starts the active tab's block controllers (PROTOCOL §3).
    func setActiveTab(workspaceId: String, tabId: String) async throws {
        try await call(WebCallType(
            service: WaveService.workspace, method: "SetActiveTab",
            args: [.string(workspaceId), .string(tabId)]
        ))
    }

    /// `workspace.CreateTab(workspaceId, tabName, activateTab)` → new tabId.
    @discardableResult
    func createTab(workspaceId: String, name: String, activate: Bool) async throws -> String {
        let result = try await call(WebCallType(
            service: WaveService.workspace, method: "CreateTab",
            args: [.string(workspaceId), .string(name), .bool(activate)]
        ))
        return result.data?.stringValue ?? ""
    }

    /// `workspace.CloseTab(workspaceId, tabId, fromElectron)` — honor the return
    /// per GUARDS §C.
    func closeTab(workspaceId: String, tabId: String) async throws -> CloseTabResult {
        let result = try await call(WebCallType(
            service: WaveService.workspace, method: "CloseTab",
            args: [.string(workspaceId), .string(tabId), .bool(false)]
        ))
        guard let data = result.data, !data.isNull else { return CloseTabResult() }
        return try data.decode(CloseTabResult.self)
    }

    // MARK: Window

    /// `window.CreateWindow(winSize, workspaceId)` → the new `Window` (its `.oid` is
    /// the backend `window:<id>` a coordinator binds its route to). A non-empty
    /// `workspaceId` binds a NEW window to that EXISTING workspace (`wcore.CreateWindow`);
    /// an empty string would also create a fresh workspace, which the multi-window
    /// flow never wants here — we always pass an explicit workspace. `winSize` is
    /// passed `.null` (the backend defaults it). GUARDS §B: inline updates applied by `call`.
    @discardableResult
    func createWindow(workspaceId: String) async throws -> Window? {
        let result = try await call(WebCallType(
            service: WaveService.window, method: "CreateWindow",
            args: [.null, .string(workspaceId)]
        ))
        guard let data = result.data, !data.isNull else { return nil }
        return try data.decode(Window.self)
    }

    /// `window.SwitchWorkspace(windowId, workspaceId)` → the active `Workspace`.
    @discardableResult
    func switchWorkspace(windowId: String, workspaceId: String) async throws -> Workspace? {
        let result = try await call(WebCallType(
            service: WaveService.window, method: "SwitchWorkspace",
            args: [.string(windowId), .string(workspaceId)]
        ))
        guard let data = result.data, !data.isNull else { return nil }
        return try data.decode(Workspace.self)
    }

    /// `[wsh] MoveTabCommand` (`pkg/wshrpc/wshserver/wshserver.go:178`). Moves `tabId`
    /// from its current workspace to `destWorkspaceId`; the backend broadcasts the
    /// resulting workspace updates over `waveobj:update`, so there are no inline
    /// updates to apply here. GUARDS §C: the backend refuses to move the last tab out
    /// of a workspace (the strip also gates the gesture when only one tab remains).
    func moveTab(sourceWorkspaceId: String, destWorkspaceId: String, tabId: String) async throws {
        try await transport.callVoid(
            command: "movetab",
            data: CommandMoveTabData(
                sourceworkspaceid: sourceWorkspaceId,
                destworkspaceid: destWorkspaceId,
                tabid: tabId))
    }

    /// `[wsh] MoveBlockToTabCommand`. Moves a pane (top-level block) into `targetTabId`;
    /// the backend re-parents the block, removes its layout node from the source tab
    /// (deleting the tab if it emptied), inserts it focused into the target tab, and
    /// broadcasts the resulting updates over `waveobj:update` — no inline updates here.
    /// The backend refuses to move the last pane out of a workspace's only tab.
    func moveBlockToTab(blockId: String, targetTabId: String) async throws {
        try await transport.callVoid(
            command: "moveblocktotab",
            data: CommandMoveBlockToTabData(blockid: blockId, targettabid: targetTabId))
    }

    /// `[wsh] UpdateWorkspaceTabIdsCommand` (reorder). Sent as
    /// `MultiArg{ args:[workspaceId, tabIds] }` (`pkg/wshrpc/wshclient/wshclient.go:952`).
    /// The backend persists the new order and broadcasts the workspace update over
    /// `waveobj:update`, so the strip refreshes via the normal subscription.
    func updateWorkspaceTabIds(workspaceId: String, tabIds: [String]) async throws {
        try await transport.callVoid(
            command: "updateworkspacetabids",
            data: MultiArg([.string(workspaceId), .array(tabIds.map { .string($0) })]))
    }

    /// `[wsh] UpdateTabNameCommand` (`pkg/wshrpc/wshclient/wshclient.go:946`). Sent
    /// as `MultiArg{ args:[tabId, newName] }` (positional). The backend broadcasts
    /// the resulting tab update over `waveobj:update`, so the strip refreshes via the
    /// normal subscription — no inline updates to apply here.
    func updateTabName(tabId: String, name: String) async throws {
        try await transport.callVoid(
            command: "updatetabname",
            data: MultiArg([.string(tabId), .string(name)]))
    }

    /// `[wsh] SetMetaCommand` (`pkg/wshrpc/wshclient/wshclient.go`). Mutates an
    /// object's `meta` map (e.g. a tab's `tab:flagcolor`). The backend broadcasts the
    /// resulting object update over `waveobj:update`, so subscribers refresh through
    /// the normal subscription — no inline updates to apply here.
    func setMeta(oref: ORef, meta: MetaMapType) async throws {
        try await transport.callVoid(
            command: "setmeta",
            data: CommandSetMetaData(oref: oref, meta: meta))
    }

    // MARK: Block

    /// `object.CreateBlock(uiContext, blockDef, rtOpts)` → new blockId.
    @discardableResult
    func createBlock(
        uiContext: UIContext, blockDef: BlockDef, rtOpts: RuntimeOpts? = nil
    ) async throws -> String {
        let defJSON = try JSONValue.encode(blockDef)
        let optsJSON = rtOpts.map { (try? JSONValue.encode($0)) ?? .null } ?? .null
        let result = try await call(WebCallType(
            service: WaveService.object, method: "CreateBlock",
            uicontext: uiContext, args: [defJSON, optsJSON]
        ))
        return result.data?.stringValue ?? ""
    }

    /// `[wsh] CreateBlockCommand` (`pkg/wshrpc/wshserver/wshserver.go:240`). Unlike
    /// the HTTP `CreateBlock` above, this QUEUES a layout action — an `insert`, or a
    /// split (`splitright`/`splitdown`/…) when `targetblockid`+`targetaction` are set
    /// — into the tab's LayoutState `pendingbackendactions`, so the new block is
    /// auto-tiled (GUARDS §L). The new object reaches the store via the
    /// `waveobj:update` subscription, so there are no inline `updates` to apply here.
    @discardableResult
    func createBlockWsh(_ data: CommandCreateBlockData) async throws -> ORef {
        return try await transport.call(command: "createblock", data: data)
    }

    /// `[wsh] DeleteBlockCommand` (`pkg/wshrpc/wshserver/wshserver.go:489`). Like
    /// `createBlockWsh`, this both deletes the block AND queues a layout `delete`
    /// action into the tab's LayoutState `pendingbackendactions`, so the pane is
    /// removed via the `waveobj:update` layout subscription (GUARDS §L). Returns no
    /// payload, so it goes through `callVoid` (no inline updates to apply here).
    func deleteBlockWsh(blockId: String) async throws {
        try await transport.callVoid(command: "deleteblock", data: CommandDeleteBlockData(blockid: blockId))
    }

    /// `[wsh] ControllerResyncCommand` (`pkg/wshrpc/wshrpctypes.go:55`, cmd
    /// "controllerresync"). With `forceRestart: true` this is the backend path behind
    /// the terminal's "Force Restart Controller" menu item — it tears down and restarts
    /// the block's shell controller. Returns no payload (error-only on the backend), so
    /// it goes through `callVoid`; the restarted controller streams fresh output via
    /// the block's normal `blockfile` subscription (no inline updates to apply here).
    func controllerResync(tabId: String, blockId: String, forceRestart: Bool) async throws {
        try await transport.callVoid(
            command: WaveCommand.controllerResync,
            data: CommandControllerResyncData(forcerestart: forceRestart, tabid: tabId, blockid: blockId))
    }

    // MARK: Terminal scrollback buffers

    /// `[wsh] TermScrollbackListCommand` (cmd "termscrollbacklist"): every stored
    /// term buffer across all workspaces (plus orphaned filestore zones), with
    /// logical + compressed on-disk sizes. Takes no args.
    func termScrollbackList() async throws -> [TermScrollbackEntry] {
        let none: JSONValue? = nil
        return try await transport.call(command: "termscrollbacklist", data: none)
    }

    /// `[wsh] TermGetRunningCommandsCommand` (cmd "termgetrunningcommands"): child
    /// processes still running under the LOCAL shells of the given scope (one
    /// block, one tab, or a whole workspace). Backs the close confirmations —
    /// remote shells and transient wsh helpers are excluded server-side.
    func termRunningCommands(_ data: CommandTermGetRunningCommandsData) async throws -> [TermRunningCommand] {
        try await transport.call(command: "termgetrunningcommands", data: data)
    }

    /// `[wsh] TermClearBufferCommand` (cmd "termclearbuffer"): truncate a block's
    /// persisted term file (and its serialized cache). The backend publishes the
    /// blockfile `truncate` event, so a mounted pane clears live through its
    /// normal subscription — no inline updates to apply here.
    func termClearBuffer(blockId: String) async throws {
        try await transport.callVoid(command: "termclearbuffer", data: blockId)
    }

    /// Destructive teardown for "Quit and Close All Shells": enumerate every durable
    /// job-manager (`jobcontrollerlist`) and terminate each (`jobcontrollerexitjob`),
    /// so no local shell survives for reconnect. Normal quit only detaches the
    /// controllers (`Stop(destroy:false)`), which leaves the wsh job-managers running
    /// — there is no single backend "kill all" RPC, so this composes the same
    /// per-job primitives `wsh jobdebug terminate` uses. Returns how many job-managers
    /// it asked the backend to terminate.
    @discardableResult
    func terminateAllShells() async throws -> Int {
        let jobs = try await listJobs()
        for job in jobs {
            try await transport.callVoid(command: "jobcontrollerexitjob", data: job.oid)
        }
        return jobs.count
    }

    /// `[wsh] JobControllerListCommand` (cmd "jobcontrollerlist"): every durable job
    /// record (all statuses; filter client-side).
    func listJobs() async throws -> [JobInfo] {
        let none: JSONValue? = nil
        return try await transport.call(command: "jobcontrollerlist", data: none)
    }

    /// `[wsh] JobControllerAttachJobCommand` (cmd "jobcontrollerattachjob"): bind a
    /// durable job to `blockId` (block.JobId + job.AttachedBlockId, transactional).
    /// Fails if the job is still attached to a DIFFERENT block — detach first.
    func attachJob(jobId: String, blockId: String) async throws {
        try await transport.callVoid(
            command: "jobcontrollerattachjob",
            data: JobAttachData(jobid: jobId, blockid: blockId))
    }

    /// `[wsh] JobControllerDetachJobCommand` (cmd "jobcontrollerdetachjob"): clear the
    /// job<->block binding (the job keeps running).
    func detachJob(jobId: String) async throws {
        try await transport.callVoid(command: "jobcontrollerdetachjob", data: jobId)
    }

    /// `[wsh] JobControllerDisconnectJobCommand` (cmd "jobcontrollerdisconnectjob"):
    /// drop wavesrv's connection to the job's manager WITHOUT stopping the job. The
    /// next reconnect restarts streaming from the attached block's file offset — for
    /// a freshly attached (empty) block that replays the manager's recent buffer.
    func disconnectJob(jobId: String) async throws {
        try await transport.callVoid(command: "jobcontrollerdisconnectjob", data: jobId)
    }

    // MARK: Config

    /// `[wsh] SetConfigCommand` → `wconfig.SetBaseConfigValue` (cmd "setconfig"). The
    /// payload is the FLAT settings MetaMapType (e.g. `{"web:defaulturl":"…"}`), sent
    /// as the bare dict — NOT nested under a "settings" key. The backend validates
    /// each key/type and merge-patches settings.json; a `.null` value DELETES the key.
    /// Numbers must be JSON numbers (`term:fontsize` is a float, `term:scrollback` an
    /// int). The backend broadcasts the `config` event afterwards, so an open Settings
    /// window refreshes through the coordinator's config-reload path. Returns no
    /// payload; we decode into a discarded `JSONValue` so it goes through `call`
    /// (recorded as a generic command) rather than a service POST.
    func setConfig(_ meta: MetaMapType) async throws {
        let _: JSONValue = try await transport.call(
            command: WaveCommand.setConfig, data: meta, route: nil, timeoutMs: 2000)
    }

    /// Name of the user settings file under the config home (`wconfig.SettingsFile`).
    static let settingsFileName = "settings.json"

    /// Build the absolute path of the user settings file (`<configHome>/settings.json`),
    /// the path the FileService RPCs address.
    static func settingsPath(configHome: String) -> String {
        configHome.hasSuffix("/") ? configHome + settingsFileName : configHome + "/" + settingsFileName
    }

    /// `[wsh] FileReadCommand` (`pkg/wshrpc/wshclient/wshclient.go:361`, cmd "fileread").
    /// Reads the whole `settings.json` and decodes its std-base64 `data64` to text.
    func readConfigFile(configHome: String) async throws -> String {
        let path = Self.settingsPath(configHome: configHome)
        let result: FileDataArg = try await transport.call(
            command: "fileread",
            data: FileDataArg(info: FileInfoArg(path: path)),
            route: nil, timeoutMs: 5000)
        guard let d64 = result.data64, !d64.isEmpty else { return "" }
        guard let data = WaveBase64.decode(d64) else {
            throw WaveError.decoding("settings.json is not valid base64")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// `[wsh] FileWriteCommand` (`pkg/wshrpc/wshclient/wshclient.go:380`, cmd "filewrite").
    /// Writes the WHOLE `settings.json` (std-base64). Error-only return → `callVoid`.
    func writeConfigFile(configHome: String, text: String) async throws {
        let path = Self.settingsPath(configHome: configHome)
        try await transport.callVoid(
            command: "filewrite",
            data: FileDataArg(info: FileInfoArg(path: path), data64: WaveBase64.encode(text)),
            route: nil, timeoutMs: 5000)
    }

    // MARK: Connection

    /// `[wsh] ConnStatusCommand` (`pkg/wshrpc/wshclient/wshclient.go:141`, cmd
    /// "connstatus"). Returns the live status of every known/active connection — the
    /// seed for the `ConnectionStore` (kept current afterwards by the `connchange`
    /// event). Takes no args.
    func connStatus() async throws -> [ConnStatus] {
        let none: JSONValue? = nil
        return try await transport.call(command: "connstatus", data: none)
    }

    /// `[wsh] ConnListCommand` (`wshclient.go:123`, cmd "connlist"). The configured
    /// connection names (ssh-config hosts + saved connections), for the typeahead
    /// picker. Takes no args.
    func connList() async throws -> [String] {
        let none: JSONValue? = nil
        return try await transport.call(command: "connlist", data: none)
    }

    /// SSH connect + connserver start + wsh install all run under the connect RPC's
    /// context (Electron passes the same 60s). The 5s default killed the wsh binary
    /// copy mid-transfer ("context deadline exceeded"), silently downgrading the
    /// connection to wsh-disabled.
    private static let connConnectTimeoutMs: Int64 = 60000

    /// `[wsh] ConnConnectCommand` (`wshclient.go:105`, cmd "connconnect"). Explicitly
    /// (re)connects `host` — used by the connect-error "Retry" affordance. Returns no
    /// payload; progress arrives via `connchange`.
    func connConnect(_ request: ConnRequest) async throws {
        try await transport.callVoid(
            command: "connconnect", data: request, route: nil,
            timeoutMs: Self.connConnectTimeoutMs)
    }

    /// `[wsh] ConnEnsureCommand` (`wshclient.go:117`, cmd "connensure"). Ensures the
    /// named connection is connected (a no-op if already up), the precondition the
    /// backend requires before a remote shell can start. Invoked when a block's
    /// `connection` meta is set to a remote host.
    func connEnsure(_ data: ConnExtData) async throws {
        try await transport.callVoid(
            command: "connensure", data: data, route: nil,
            timeoutMs: Self.connConnectTimeoutMs)
    }

    /// `[wsh] ConnDisconnectCommand` (`wshclient.go:111`, cmd "conndisconnect"). The
    /// arg is the bare connection name (positional string, not a struct).
    func connDisconnect(_ connName: String) async throws {
        try await transport.callVoid(command: "conndisconnect", data: connName)
    }

    // MARK: User input (SSH prompts / consent dialogs)

    /// `userinput.SendUserInputResponse(response)`
    /// (`pkg/service/userinputservice/userinputservice.go:13`): answer a backend
    /// `userinput` prompt. Fire-and-forget on the backend side (non-blocking channel
    /// send keyed by requestid), so a late answer after the backend's timeout is
    /// silently dropped — never an error worth surfacing to the user.
    func sendUserInputResponse(_ response: UserInputResponse) async throws {
        try await call(WebCallType(
            service: WaveService.userInput, method: "SendUserInputResponse",
            args: [try JSONValue.encode(response)]))
    }
}
