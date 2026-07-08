# Wave Native — Backend Protocol Definition

Authoritative contract for the native macOS (Swift) client talking to the existing
Go `wavesrv`. The native client is a **drop-in alternative frontend**: it reuses
`wavesrv` unchanged and speaks the same protocol the Electron renderer and the
`wsh` CLI speak. Nothing in `wavesrv` is Electron-specific.

Scope of this client: **terminal blocks, web blocks, workspaces/tabs/windows.**
Everything else (preview, AI, sysinfo, vdom) is intentionally out of scope.

> All file:line references point into the Wave repo at `/workspace` and are the
> source of truth. If this document and the code disagree, the code wins — update
> this document.

---

## 0. Two transports (internalize this first)

There are **two** channels and the client needs both:

1. **HTTP "service" layer** — `POST http://<web-addr>/wave/service`
   body `WebCallType`, response `WebReturnType { success, error, data, updates }`
   (`pkg/service/service.go:46,53`). Used for **all object CRUD and
   tab/workspace/window/block lifecycle**. `GetObject` / `GetObjects` /
   `UpdateObject` are HTTP-only. **Every response carries `updates:
   []WaveObjUpdate` that MUST be applied to the local object cache**
   (`frontend/app/store/wos.ts:136`).

2. **wshrpc over WebSocket** — `ws://<ws-addr>/ws?stableid=<routeid>` — the
   command/event stream: `waveobj:update` and `blockfile` events, meta get/set,
   id resolution, and terminal controller I/O.

A native client is *better* positioned than the browser renderer here: auth is an
HTTP/WS **header**, trivial in Swift, impossible in a sandboxed browser.

---

## 1. Transport & handshake

### Launch / discovery
- We spawn `wavesrv` as a child process. It prints to **stderr**:
  `WAVESRV-ESTART ws:<addr> web:<addr> ...` (`cmd/server/main-server.go:611`).
  Parse that line to learn the WS and HTTP addresses (the Electron launcher does
  this at `emain/emain-wavesrv.ts:108-123`).
- Three listeners exist: TCP `web` (HTTP), TCP `websocket` (`/ws`), and a unix
  domain socket at `<WAVETERM_DATA_HOME>/wave.sock`
  (`pkg/wavebase/wavebase.go:182-184`, `cmd/server/main-server.go:590-614`).
  The native client uses the **TCP web + ws** addresses from the ESTART line.

### Wire envelope — `RpcMessage` (`pkg/wshutil/wshrpc.go:127-139`)
```
{ command, reqid, resid, timeout, route, source, cont, cancel, error, datatype, data }
```
- Default timeout 5000ms (`:28`).
- Request carries `reqid`; response echoes it as `resid`.
- `cont: true` → more stream chunks follow (terminal output, etc.).
- `cancel: true` → cancel an in-flight streaming request.
- Omit `reqid` → fire-and-forget (no response expected).
- Semantics: `pkg/wshutil/wshrpc.go:381-447, 515-575`.

### WebSocket framing (ASYMMETRIC — important)
- **Outbound** (client→server): `{ "wscommand": "rpc", "message": <RpcMessage> }`
  (`frontend/app/store/ws.ts:247-254`).
- **Inbound** (server→client): `{ "eventtype": "rpc", "data": <RpcMessage> }`
  (`pkg/web/ws.go:288-294`).
- Keepalive: server sends `{ "type": "ping", "stime": N }`, client must reply
  `{ "type": "pong" }`. 15s read deadline (`pkg/web/ws.go:148-177`).
- `/ws` requires query `?stableid=<your route id>` (`pkg/web/ws.go:254-257`).
- (Domain-socket framing is newline-delimited JSON, `pkg/wshutil/wshrpcio.go:19-44`
  — only relevant if we ever use the socket instead of the TCP ws.)

### Auth
- Header **`X-AuthKey`** on the WS upgrade and on every `/wave/*` HTTP call.
  Const `AuthKeyHeader = "X-AuthKey"`, env `WAVETERM_AUTH_KEY`
  (`pkg/authkey/authkey.go:13-14`; validated `pkg/web/ws.go:258-264`,
  `pkg/web/web.go:411-416`).
- **We** generate a random key and pass it to `wavesrv` via the
  `WAVETERM_AUTH_KEY` env var when we spawn it (mirrors `emain/authkey.ts:9`).
- Do **not** use the domain-socket Ed25519 JWT scheme (`pkg/wavejwt`) — only
  `wavesrv` can mint those. Header auth + ws is the supported path for a client.

### Routing (`pkg/wshutil/wshrouter.go:24-41`)
- `DefaultRoute = "wavesrv"` — the route you **call** for server RPCs.
- `$control` — control channel for auth/announce.
- Prefixes: `tab:`, `feblock:`, `controller:`, `conn:`, `proc:`, `window:`.
- The client **registers its own route** by sending a `routeannounce` to
  `$control` with `source = <routeid>` (`frontend/app/store/wshrouter.ts:134-148`;
  server `pkg/wshutil/wshrouter_controlimpl.go:25-39`). Use `window:<windowid>`
  for a window-scoped client. **Re-announce on every reconnect**
  (`frontend/app/store/wshrpcutil.ts:24-26`) or the client goes silent.

---

## 2. Wave Object Store (WOS)

### Object types (`pkg/waveobj/wtype.go`) — all share `oid / version / meta`
- `Client { windowids[] }` (`:131`)
- `Window { workspaceid, pos, winsize }` (`:147`)
- `Workspace { tabids[], activetabid, name, icon, color }` (`:174`)
  — **no `pinnedtabids`**; tab order lives in `tabids`.
- `Tab { layoutstate (string oref), blockids[], name }` (`:189`)
- `LayoutState { rootnode, magnifiednodeid, focusednodeid, leaforder, pendingbackendactions }` (`:228`)
- `Block { meta, parentoref, subblockids, jobid }` (`:286`)
- ORef format: `"<otype>:<oid>"`, e.g. `tab:abc...` (`pkg/waveobj/waveobj.go:30-80`).

### Load
- HTTP `ObjectService.GetObject(oref)` / `GetObjects([]oref)`
  (`pkg/service/objectservice/objectservice.go:39,60`; FE wrapper `wos.ts:67`).
- Id resolution: wshrpc `ResolveIdsCommand` (`pkg/wshrpc/wshrpctypes.go:57`).

### Subscribe (live updates)
- Event `"waveobj:update"` (`pkg/wps/wpstypes.go:24`), payload
  `WaveObjUpdate { updatetype, otype, oid, obj }` (`pkg/waveobj/wtype.go:50`).
- Subscribe with wshrpc `EventSubCommand(SubscriptionRequest{ event, scopes[], allscopes })`
  (`pkg/wshrpc/wshrpctypes.go:65`); **scope = the oref string** (`pkg/wps/wps.go:241`).
- Events arrive as `eventrecv` commands (`wshrpctypes.go:119`) → FE `wps.ts:130`.
- **Version-guarded merge**: ignore an update if `current.version >= update.obj.version`
  (`wos.ts:272`).

### Mutate
- HTTP `UpdateObject` / `UpdateObjectMeta`
  (`objectservice.go:142,121`).
- wshrpc `SetMetaCommand` / `GetMetaCommand` (`wshrpctypes.go:52,51`),
  `UpdateTabNameCommand` (`:97`).

---

## 3. Workspace / Tab / Window / Block RPCs

`[svc]` = HTTP service layer · `[wsh]` = wshrpc command.

### Window
- `[svc] CreateWindow` (`windowservice.go:45`), `GetWindow` (`:29`),
  `SetWindowPosAndSize` (`:60`), `SwitchWorkspace` (`:89`), `CloseWindow` (`:109`)
- `[svc] FocusWindow / GetClientData / GetTab / AgreeTos`
  (`clientservice.go:49,25,32,53`)

### Workspace
- `[svc] CreateWorkspace` (`workspaceservice.go:31`), `UpdateWorkspace` (`:45`),
  `GetWorkspace` (`:76`), `DeleteWorkspace → (updates, claimableWorkspace)` (`:92`),
  `ListWorkspaces` (`:116`), `GetColors / GetIcons` (`:135,145`)
- `[wsh] WorkspaceListCommand` (`wshrpctypes.go:149`)

### Tab
- `[svc] CreateTab` (`workspaceservice.go:149`),
  `CloseTab → { closewindow, newactivetabid }` (`:218`),
  `SetActiveTab` (`:173`)  ← **this is what triggers backend block-controller start**
- `[wsh] GetTabCommand` (`wshrpctypes.go:96`), `UpdateTabNameCommand` (`:97`),
  `UpdateWorkspaceTabIdsCommand` (reorder, `:98`),
  `MoveTabCommand` (cross-workspace, `:99`)

### Block
- `[svc] CreateBlock / DeleteBlock` (`objectservice.go:82,104`)
- `[wsh] CreateBlockCommand` (richer: magnified / ephemeral / targetblockid /
  targetaction split-replace, `wshrpctypes.go:58`), `DeleteBlockCommand` (`:60`),
  `BlockInfoCommand` (blockid → tab/workspace reverse lookup, `:81`)

Prefer the HTTP services for lifecycle (they return `updates` inline); use wshrpc
for meta and ordering.

---

## 4. Terminal block (the real backend coupling) ⭐

**Architecture: NOT streaming-PTY-over-RPC.** The Go controller owns the PTY and
writes all output into a **circular 2 MB filestore file named `"term"`**,
broadcasting each append as a base64 `blockfile` event. The client **backfills
via HTTP** and **live-streams via the event**. Keystrokes/resize flow back as RPC.

### Lifecycle
- `ControllerResyncCommand { forcerestart, tabid, blockid, rtopts }` =
  start / create / restart (`wshrpctypes.go:53`, impl `wshserver.go:329`, logic
  `blockcontroller.go:151-285`). Controllers live in an in-process map keyed by
  blockid (`blockcontroller.go:79`).
- `ControllerStopCommand` (`wshserver.go:324`).
- The `controller:<id>` route is **dead code — do not replicate it.** Call the
  server RPCs over the normal ws connection.

### Input (keystrokes / signals / resize)
- `ControllerInputCommand` with
  `CommandBlockInputData { blockid, inputdata64 (base64 std of raw bytes), signame, termsize }`
  (`wshrpctypes.go:320-325`, impl `wshserver.go:335`; FE `term-model.ts:509-512`).

### Output + backfill (the subtle part — see GUARDS.md §T)
- File const `BlockFile_Term = "term"` (`pkg/wavebase/wavebase.go:44`), created as
  a **circular 2 MB** file (`shellcontroller.go:381`).
- PTY read loop → `HandleAppendBlockFile` appends and publishes
  `WaveEvent { Event: "blockfile", Data: WSFileEventData { zoneid, filename:"term", fileop:"append", data64 } }`
  (`blockcontroller.go:369-389`; `pkg/wps/wpstypes.go:80-92`).
- Backfill: `GET /wave/file?zoneid=<blockid>&name=term&offset=N` → raw bytes plus
  an `X-ZoneFileInfo` header (base64 JSON `WaveFile`) (`pkg/web/web.go:150-210`).
  Circular start clamp at `filestore/blockstore.go:78-83`.
- FE order: **subscribe to the event first, then backfill**, then reconcile by
  absolute byte offset (`frontend/app/view/term/termwrap.ts:382-448, 502-525`).
- Optional fast-restore cache `cache:term:full` (`blockservice.go:45-68`) —
  **skip it**; just GET `term` from the offset.

### Resize
- `TermSize { rows, cols }` (`wtype.go:370`).
- Live resize = `ControllerInputCommand { termsize }` after fit
  (`termwrap.ts:584-591`) → persists + `SetSize` (TIOCSWINSZ).
- Initial size = `rtopts.termsize` on Resync; backend default `{25,80}`
  (`blockcontroller.go:358-367`).

### What libghostty replaces vs what we wire
- libghostty handles all escape-sequence parsing + grid rendering + producing the
  correct input byte stream for keys.
- **We** wire: Resync on mount, subscribe `blockfile`, backfill+reconcile, feed
  decoded bytes into libghostty, send libghostty's output bytes back via
  `ControllerInputCommand`, and forward resize.

---

## 5. Web block (almost entirely frontend)

- No web-specific controller, no nav backend. A web block is a generic `Block`
  with `meta.view == "web"` (`metaconsts.go:9`; starter `wcore/layout.go:50-52`).
- Meta keys read by the view (`webview.tsx:91,104,107,114,855-857`):
  `url`, `pinnedurl`, `web:zoom`, `web:hidenav`, `web:useragenttype`,
  `web:partition`.
- Only backend calls the web view makes: `SetMetaCommand` to persist `url` on
  navigate (`webview.tsx:382-386`), plus pinnedurl/zoom/useragent/hidenav; optional
  `FetchSuggestionsCommand` for bookmark typeahead (`:292-298`).
- **Native mapping:** `WKWebView` (an `NSView`). Read `meta.url` → load;
  on `didFinish` navigation → `SetMetaCommand { oref: block:<id>, meta: { url } }`.
  Map `web:partition` → `WKWebsiteDataStore`. Back/forward/reload/zoom = WKWebView
  API. Bookmark typeahead optional.

---

## 6. Layout (tiling)

- Layout is a **separate `LayoutState` WaveObj** referenced by `Tab.layoutstate`
  (`wtype.go:193,228-241`), created/deleted with the tab
  (`wcore/workspace.go:275-288,335`).
- Node tree: recursive
  `LayoutNode { id, data?{ blockId }, children?[], flexDirection: "row"|"column", size: number(default 10) }`
  (`frontend/layout/lib/types.ts:296-302`; leaf payload `custom.d.ts:52-54`).
- **No dedicated layout RPC.** The FE reducer mutates the tree locally
  (`layoutModel.ts:610-712`) then `persistToBackend()` (debounced 100ms,
  `:576-594`) writes the **whole object** via `ObjectService.UpdateObject`
  (`wos.ts:302-315`, generic `objectservice.go:142`).
- **Backend → client structural changes** ride
  `LayoutState.pendingbackendactions`
  (`[]LayoutActionData { actiontype, blockid, indexarr, nodesize, targetblockid, position }`,
  `wtype.go:210-221`), queued by `QueueLayoutAction` / `ApplyPortableLayout`
  (`wcore/layout.go:82-142`) when the backend creates a block. The client applies
  them on load and writes back with the list cleared.

---

## 7. Init sequence (minimum to a usable window)

From `frontend/wave.ts:147-233`:

1. Spawn `wavesrv` with env (`WAVETERM_AUTH_KEY`, `WAVETERM_DATA_HOME`,
   `WAVETERM_CONFIG_HOME`); parse `WAVESRV-ESTART` for ws/web addrs.
2. HTTP `client.GetClientData` (+ first-run bootstrap) → `clientId`, `windowids`.
3. Open `ws://<ws>/ws?stableid=window:<windowId>` with `X-AuthKey`; start ping/pong.
4. `routeannounce` (source = `window:<windowId>`) → `$control`.
5. wshrpc `EventSubCommand` for `waveobj:update`, `config`, `connchange`,
   `blockfile`, `userinput`.
6. HTTP `GetObject` for `client → window → workspace → tab → layout`, then sibling
   tabs, then blocks lazily as the layout renders.
7. wshrpc `GetFullConfigCommand` (`wave.ts:213`).
8. `EventSubCommand` `waveobj:update` scoped to the workspace oref.
9. Mark ready. Thereafter: mutate via HTTP services (apply returned `updates`),
   react to `waveobj:update` / `eventrecv`. **Re-announce + re-subscribe on every
   WS reconnect.**

---

## Module map (Swift) — what implements what

| Swift module | Implements | Protocol §§ |
|---|---|---|
| `WaveProtocol` | RpcMessage codec, WS framer, HTTP service client, auth, ping/pong, reconnect+re-announce | 1 |
| `WaveStore` | oref-keyed object cache, load, subscribe, version-guarded merge, apply inline `updates` | 2 |
| `WaveCommands` | typed wrappers for the §3 RPCs | 3 |
| `WaveTerminal` | Resync, blockfile subscribe, backfill+reconcile, libghostty I/O, resize | 4 |
| `WaveWeb` | WKWebView ↔ block meta | 5 |
| `WaveLayout` | node-tree model, reducer, persist, pendingbackendactions | 6 |
| `WaveApp` (AppKit) | window/tabs/workspaces, chrome, init sequence | 7 |
