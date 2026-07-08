// Copyright 2026, Command Line Inc.
// SPDX-License-Identifier: Apache-2.0
//
// WaveCommands — typed wrappers for the window / workspace / tab / block
// lifecycle RPCs.
//
// Implements PROTOCOL.md §3 ("Workspace / Tab / Window / Block RPCs") and the
// dispatch contract of the HTTP service layer (§0, `pkg/service/service.go`):
//   * lifecycle CRUD goes over the HTTP "service" layer (`/wave/service`,
//     `WebCallType` -> `WebReturnType`); EVERY response's inline `updates` are
//     applied to the object store (GUARDS §B, `frontend/app/store/wos.ts:136`).
//   * meta / ordering / cross-workspace move go over wshrpc (PROTOCOL.md §3
//     "Prefer the HTTP services for lifecycle ... use wshrpc for meta and
//     ordering").
//
// Source of truth for the service method ARG ORDER is the reflective dispatcher
// (`pkg/service/service.go:308-352`): a leading `context.Context` and any
// `waveobj.UIContext` parameter are injected server-side and are NOT part of the
// JSON `args` array — `args` carries only the remaining positional parameters.
// The `UIContext` (when a method needs it) travels in `WebCallType.uicontext`
// (mirrors `frontend/app/store/wos.ts:101-112`).
//
// GUARDS encoded here:
//   §C [MUST]     `SetActiveTab` is the trigger that starts the active tab's
//                 block controllers (`workspaceservice.go:173`).
//   §C [MUST]     honor `CloseTab`'s `{ closewindow, newactivetabid }`
//                 (`workspaceservice.go:218`) — surfaced as `CloseTabResult`.
//   §C [MUST-NOT] never move the last tab out of a workspace — enforced as a
//                 throwing guard before issuing `MoveTabCommand` (recoverable
//                 user action; mirrors the FE `tabCount > 1` guard).
//   §B [MUST]     apply `WebReturnType.updates` from every service call.

import Foundation
import WaveCore
import WaveStore

// MARK: - wshrpc command names (`pkg/wshrpc/wshclient/wshclient.go`)

/// The lowercase wire `command` strings for the wshrpc calls this module issues
/// (method name lowercased, `Command` suffix stripped — see the generated client).
public enum WshCommand {
    public static let getMeta = "getmeta"
    public static let setMeta = "setmeta"
    public static let createBlock = "createblock"
    public static let deleteBlock = "deleteblock"
    public static let moveTab = "movetab"
    public static let updateWorkspaceTabIds = "updateworkspacetabids"
    public static let updateTabName = "updatetabname"
}

// MARK: - MultiArg (`pkg/wshrpc/wshrpctypes.go:27-29`)

/// Envelope used by wshrpc commands that take more than one positional argument
/// (e.g. `updatetabname`, `updateworkspacetabids`). The generated client wraps
/// the args as `wshrpc.MultiArg{ Args: []any{...} }`
/// (`wshclient.go:946-955`). Heterogeneous args are carried as `JSONValue`.
public struct MultiArg: Encodable, Sendable {
    public var args: [JSONValue]
    public init(_ args: [JSONValue]) { self.args = args }

    enum CodingKeys: String, CodingKey { case args }
}

// MARK: - Typed results

/// Return of `WorkspaceService.CloseTab` (`workspaceservice.go:197-200`). GUARDS
/// §C: if `closewindow` is set close the window, otherwise switch to
/// `newactivetabid`. Both fields are `omitempty` on the wire so they decode to
/// their zero value when absent.
public struct CloseTabResult: Codable, Sendable, Equatable {
    public var closewindow: Bool
    public var newactivetabid: String

    public init(closewindow: Bool = false, newactivetabid: String = "") {
        self.closewindow = closewindow
        self.newactivetabid = newactivetabid
    }

    enum CodingKeys: String, CodingKey { case closewindow, newactivetabid }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        closewindow = try c.decodeIfPresent(Bool.self, forKey: .closewindow) ?? false
        newactivetabid = try c.decodeIfPresent(String.self, forKey: .newactivetabid) ?? ""
    }
}

// MARK: - WaveCommands

/// Typed entry point for window / workspace / tab / block lifecycle.
///
/// Holds the shared `WaveTransport` (HTTP service + wshrpc) and the
/// `ObjectStoreProtocol` cache. Lifecycle mutations go through the HTTP service
/// layer and feed their inline `updates` back into the store (GUARDS §B);
/// meta/ordering/move go through wshrpc and stay fresh via the `waveobj:update`
/// subscription the store maintains.
///
/// `uiContext` supplies the current window/active-tab context the HTTP service
/// dispatcher injects into `UIContext`-typed parameters. It is read fresh on
/// each call so a changing active tab is always reflected.
public final class WaveCommands: Sendable {
    private let transport: WaveTransport
    private let store: ObjectStoreProtocol
    private let uiContext: @Sendable () -> UIContext

    public init(
        transport: WaveTransport,
        store: ObjectStoreProtocol,
        uiContext: @escaping @Sendable () -> UIContext
    ) {
        self.transport = transport
        self.store = store
        self.uiContext = uiContext
    }

    // MARK: HTTP service plumbing (PROTOCOL.md §0)

    /// POST a `WebCallType` to `/wave/service`, apply the returned `updates` to
    /// the store (GUARDS §B), then surface any error as `WaveError.rpc`.
    @discardableResult
    private func callService(
        _ service: String,
        _ method: String,
        args: [JSONValue],
        uiContext: UIContext? = nil
    ) async throws -> WebReturnType {
        let call = WebCallType(
            service: service, method: method,
            uicontext: uiContext ?? self.uiContext(), args: args
        )
        let rtn = try await transport.callService(call)
        // GUARDS §B: apply inline updates from EVERY service response (even on
        // error the server may have published partial updates — applying them is
        // harmless because the store is version-guarded).
        if let updates = rtn.updates, !updates.isEmpty {
            store.applyUpdates(updates)
        }
        if let err = rtn.error, !err.isEmpty {
            throw WaveError.rpc("\(service).\(method): \(err)")
        }
        return rtn
    }

    /// Decode the `data` payload of a service response into a typed value.
    private func decoded<T: Decodable>(_ rtn: WebReturnType, _ type: T.Type, _ ctx: String) throws -> T {
        guard let data = rtn.data, !data.isNull else {
            throw WaveError.decoding("\(ctx): missing response data")
        }
        do {
            return try data.decode(T.self)
        } catch {
            throw WaveError.decoding("\(ctx): \(error)")
        }
    }

    /// Read a scalar string `data` payload from a service response (avoids a
    /// top-level JSON-fragment round-trip; service methods that return a bare id
    /// — `CreateWorkspace`/`CreateTab`/`CreateBlock` — encode `data` as a string).
    private func stringData(_ rtn: WebReturnType, _ ctx: String) throws -> String {
        guard let s = rtn.data?.stringValue else {
            throw WaveError.decoding("\(ctx): expected string response data")
        }
        return s
    }

    /// Encode an optional `Encodable` into a positional `JSONValue` argument,
    /// mapping `nil` to JSON `null` (the dispatcher accepts `null` for nullable
    /// pointer/struct parameters, `service.go:202-204`).
    private func arg<T: Encodable>(_ value: T?) throws -> JSONValue {
        guard let value else { return .null }
        return try JSONValue.encode(value)
    }

    // MARK: - Window (PROTOCOL.md §3 "Window")

    /// `[svc] WindowService.CreateWindow(ctx, winSize, workspaceId)`
    /// (`windowservice.go:45`). Returns the new `Window` (also merged into the cache).
    @discardableResult
    public func createWindow(winSize: WinSize?, workspaceId: String) async throws -> Window {
        let rtn = try await callService(
            "window", "CreateWindow",
            args: [try arg(winSize), .string(workspaceId)]
        )
        let window: Window = try decoded(rtn, Window.self, "CreateWindow")
        store.merge(.window(window))
        return window
    }

    /// `[svc] WindowService.GetWindow` (`windowservice.go:29`) via the object
    /// store (cached, version-guarded). PROTOCOL.md §2: `GetObject` is HTTP-only;
    /// the store owns that fetch.
    public func getWindow(_ windowId: String) async throws -> Window {
        let obj = try await store.load(.window(windowId))
        guard let window = obj.asWindow else {
            throw WaveError.decoding("getWindow: object \(windowId) is not a window")
        }
        return window
    }

    /// `[svc] WindowService.SetWindowPosAndSize(ctx, windowId, pos, size)`
    /// (`windowservice.go:60`).
    public func setWindowPosAndSize(windowId: String, pos: Point?, size: WinSize?) async throws {
        try await callService(
            "window", "SetWindowPosAndSize",
            args: [.string(windowId), try arg(pos), try arg(size)]
        )
    }

    /// `[svc] WindowService.SwitchWorkspace(ctx, windowId, workspaceId)`
    /// (`windowservice.go:89`). Returns the now-active `Workspace`.
    @discardableResult
    public func switchWorkspace(windowId: String, workspaceId: String) async throws -> Workspace {
        let rtn = try await callService(
            "window", "SwitchWorkspace",
            args: [.string(windowId), .string(workspaceId)]
        )
        let ws: Workspace = try decoded(rtn, Workspace.self, "SwitchWorkspace")
        store.merge(.workspace(ws))
        return ws
    }

    /// `[svc] WindowService.CloseWindow(ctx, windowId, fromElectron)`
    /// (`windowservice.go:109`).
    public func closeWindow(windowId: String, fromElectron: Bool = false) async throws {
        try await callService(
            "window", "CloseWindow",
            args: [.string(windowId), .bool(fromElectron)]
        )
    }

    /// `[svc] ClientService.FocusWindow(ctx, windowId)` (`clientservice.go:49`).
    public func focusWindow(_ windowId: String) async throws {
        try await callService("client", "FocusWindow", args: [.string(windowId)])
    }

    // MARK: - Workspace (PROTOCOL.md §3 "Workspace")

    /// `[svc] WorkspaceService.CreateWorkspace(ctx, name, icon, color, applyDefaults)`
    /// (`workspaceservice.go:31`). Returns the new workspace id.
    @discardableResult
    public func createWorkspace(
        name: String = "", icon: String = "", color: String = "", applyDefaults: Bool = true
    ) async throws -> String {
        let rtn = try await callService(
            "workspace", "CreateWorkspace",
            args: [.string(name), .string(icon), .string(color), .bool(applyDefaults)]
        )
        return try stringData(rtn, "CreateWorkspace")
    }

    /// `[svc] WorkspaceService.UpdateWorkspace(ctx, workspaceId, name, icon, color, applyDefaults)`
    /// (`workspaceservice.go:45`).
    public func updateWorkspace(
        workspaceId: String, name: String, icon: String, color: String, applyDefaults: Bool
    ) async throws {
        try await callService(
            "workspace", "UpdateWorkspace",
            args: [
                .string(workspaceId), .string(name), .string(icon),
                .string(color), .bool(applyDefaults),
            ]
        )
    }

    /// `[svc] WorkspaceService.GetWorkspace` (`workspaceservice.go:76`) via the
    /// object store (cached, version-guarded).
    public func getWorkspace(_ workspaceId: String) async throws -> Workspace {
        let obj = try await store.load(.workspace(workspaceId))
        guard let ws = obj.asWorkspace else {
            throw WaveError.decoding("getWorkspace: object \(workspaceId) is not a workspace")
        }
        return ws
    }

    /// `[svc] WorkspaceService.DeleteWorkspace` (`workspaceservice.go:92`).
    /// Returns the `claimableWorkspace` id (empty string when the workspace was
    /// actually deleted rather than orphaned).
    @discardableResult
    public func deleteWorkspace(_ workspaceId: String) async throws -> String {
        let rtn = try await callService("workspace", "DeleteWorkspace", args: [.string(workspaceId)])
        // `claimableWorkspace` is `omitempty`: absent => deleted outright.
        guard let data = rtn.data, let claimable = data.stringValue else { return "" }
        return claimable
    }

    // MARK: - Tab (PROTOCOL.md §3 "Tab")

    /// `[svc] WorkspaceService.CreateTab(workspaceId, tabName, activateTab)`
    /// (`workspaceservice.go:149`). Returns the new tab id.
    @discardableResult
    public func createTab(
        workspaceId: String, tabName: String = "", activateTab: Bool = true
    ) async throws -> String {
        let rtn = try await callService(
            "workspace", "CreateTab",
            args: [.string(workspaceId), .string(tabName), .bool(activateTab)]
        )
        return try stringData(rtn, "CreateTab")
    }

    /// `[svc] ClientService.GetTab` (`clientservice.go:32`) via the object store.
    public func getTab(_ tabId: String) async throws -> Tab {
        let obj = try await store.load(.tab(tabId))
        guard let tab = obj.asTab else {
            throw WaveError.decoding("getTab: object \(tabId) is not a tab")
        }
        return tab
    }

    /// `[svc] WorkspaceService.SetActiveTab(workspaceId, tabId)`
    /// (`workspaceservice.go:173`).
    ///
    /// GUARDS §C [MUST]: this call is the trigger that makes the backend start
    /// the active tab's block controllers — it MUST be issued on every tab
    /// switch, not merely tracked locally.
    public func setActiveTab(workspaceId: String, tabId: String) async throws {
        try await callService(
            "workspace", "SetActiveTab",
            args: [.string(workspaceId), .string(tabId)]
        )
    }

    /// `[svc] WorkspaceService.CloseTab(ctx, workspaceId, tabId, fromElectron)`
    /// (`workspaceservice.go:218`).
    ///
    /// GUARDS §C [MUST]: the caller MUST honor the returned `CloseTabResult` —
    /// if `closewindow` close the window, else switch to `newactivetabid`.
    @discardableResult
    public func closeTab(
        workspaceId: String, tabId: String, fromElectron: Bool = false
    ) async throws -> CloseTabResult {
        let rtn = try await callService(
            "workspace", "CloseTab",
            args: [.string(workspaceId), .string(tabId), .bool(fromElectron)]
        )
        // The Go return is `{}` when the last tab closed the window AND
        // newactivetabid is empty; decodeIfPresent handles the omitempty fields.
        guard let data = rtn.data, !data.isNull else { return CloseTabResult() }
        return try decoded(rtn, CloseTabResult.self, "CloseTab")
    }

    /// `[wsh] MoveTabCommand` (cross-workspace, `wshrpctypes.go:99`).
    ///
    /// GUARDS §C [MUST-NOT]: refuse to move the last tab out of the source
    /// workspace (the backend rejects it; mirror the FE `tabCount > 1` guard).
    /// The source workspace is read from the cache (loading it if necessary) to
    /// evaluate the precondition.
    public func moveTab(
        sourceWorkspaceId: String, destWorkspaceId: String, tabId: String
    ) async throws {
        let srcObj: AnyWaveObj
        if let cached = store.get(.workspace(sourceWorkspaceId)) {
            srcObj = cached
        } else {
            srcObj = try await store.load(.workspace(sourceWorkspaceId))
        }
        guard let src = srcObj.asWorkspace else {
            throw WaveError.decoding("moveTab: source \(sourceWorkspaceId) is not a workspace")
        }
        // GUARDS §C [MUST-NOT]: never move the last tab out. This is a recoverable
        // user action (the UI can simply disable the gesture), so it is surfaced
        // as a throwing error rather than a trapping precondition.
        guard src.tabids.count > 1 else {
            throw WaveError.rpc("moveTab: cannot move the last tab out of workspace \(sourceWorkspaceId)")
        }
        let data = CommandMoveTabData(
            sourceworkspaceid: sourceWorkspaceId,
            destworkspaceid: destWorkspaceId,
            tabid: tabId
        )
        try await transport.callVoid(command: WshCommand.moveTab, data: data)
    }

    /// `[wsh] UpdateWorkspaceTabIdsCommand` (reorder, `wshrpctypes.go:98`). Sent
    /// as `MultiArg{ args:[workspaceId, tabIds] }` (`wshclient.go:952`).
    public func updateWorkspaceTabIds(workspaceId: String, tabIds: [String]) async throws {
        let multi = MultiArg([.string(workspaceId), .array(tabIds.map { .string($0) })])
        try await transport.callVoid(command: WshCommand.updateWorkspaceTabIds, data: multi)
    }

    /// `[wsh] UpdateTabNameCommand` (`wshrpctypes.go:97`). Sent as
    /// `MultiArg{ args:[tabId, newName] }` (`wshclient.go:946`).
    public func updateTabName(tabId: String, newName: String) async throws {
        let multi = MultiArg([.string(tabId), .string(newName)])
        try await transport.callVoid(command: WshCommand.updateTabName, data: multi)
    }

    // MARK: - Block (PROTOCOL.md §3 "Block")

    /// `[svc] ObjectService.CreateBlock(uiContext, blockDef, rtOpts)`
    /// (`objectservice.go:82`). The backend creates the block on
    /// `uiContext.ActiveTabId`, so the call's `UIContext.activetabid` is set to
    /// `tabId` (the rest of the context comes from the supplied provider).
    /// Returns the new block id.
    @discardableResult
    public func createBlock(
        tabId: String, blockDef: BlockDef, rtOpts: RuntimeOpts? = nil
    ) async throws -> String {
        let ctx = UIContext(windowid: uiContext().windowid, activetabid: tabId)
        let rtn = try await callService(
            "object", "CreateBlock",
            args: [try arg(blockDef), try arg(rtOpts)],
            uiContext: ctx
        )
        return try stringData(rtn, "CreateBlock")
    }

    /// `[wsh] CreateBlockCommand` (`wshrpctypes.go:58`) — the richer create that
    /// supports `magnified` / `ephemeral` / split-replace via
    /// `targetblockid` + `targetaction`. Returns the new block's `ORef`. Use this
    /// (rather than the HTTP `createBlock`) when those options are needed; the
    /// resulting object reaches the cache via the `waveobj:update` subscription.
    @discardableResult
    public func createBlock(_ data: CommandCreateBlockData) async throws -> ORef {
        try await transport.call(command: WshCommand.createBlock, data: data)
    }

    /// `[svc] ObjectService.DeleteBlock(uiContext, blockId)`
    /// (`objectservice.go:104`). Inline `updates` are applied (GUARDS §B).
    public func deleteBlock(_ blockId: String) async throws {
        try await callService("object", "DeleteBlock", args: [.string(blockId)])
    }

    /// `GetObject(block:<id>)` via the object store (cached, version-guarded).
    public func getBlock(_ blockId: String) async throws -> Block {
        let obj = try await store.load(.block(blockId))
        guard let block = obj.asBlock else {
            throw WaveError.decoding("getBlock: object \(blockId) is not a block")
        }
        return block
    }

    // MARK: - Meta (PROTOCOL.md §2 "Mutate")

    /// `[wsh] GetMetaCommand` (`wshrpctypes.go:51`).
    public func getMeta(_ oref: ORef) async throws -> MetaMapType {
        try await transport.call(command: WshCommand.getMeta, data: CommandGetMetaData(oref: oref))
    }

    /// `[wsh] SetMetaCommand` (`wshrpctypes.go:52`). Used for navigation persist
    /// (web blocks, PROTOCOL.md §5 / GUARDS §W) and any object meta mutation.
    public func setMeta(_ oref: ORef, meta: MetaMapType) async throws {
        try await transport.callVoid(
            command: WshCommand.setMeta,
            data: CommandSetMetaData(oref: oref, meta: meta)
        )
    }
}
