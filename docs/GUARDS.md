# Wave Native — Implementation Guards

Non-negotiable invariants the Swift client MUST uphold to be protocol-correct
against `wavesrv`. These are the things that, if gotten wrong, produce subtle
corruption (duplicated/dropped terminal output, stale UI, silent disconnects)
rather than loud failures. Each guard cites the source of truth in `/workspace`
and should be encoded as a `precondition`/`assert` or a focused unit/e2e test.

Legend: **[MUST]** correctness · **[MUST-NOT]** forbidden · **[CHECK]** test/assert.

---

## A. Transport

- **[MUST]** Send the `X-AuthKey` header on the WS upgrade **and** every `/wave/*`
  HTTP request. Missing/invalid key → connection rejected
  (`pkg/web/ws.go:258-264`, `pkg/web/web.go:411-416`).
- **[MUST]** Frame outbound ws messages as `{ "wscommand":"rpc", "message":… }`
  and parse inbound as `{ "eventtype":"rpc", "data":… }`. The framing is
  **asymmetric** — using the same shape both ways breaks silently
  (`frontend/app/store/ws.ts:247-254` vs `pkg/web/ws.go:288-294`).
- **[MUST]** Reply `{ "type":"pong" }` to every `{ "type":"ping" }` within the
  15s read deadline or the server drops the socket (`pkg/web/ws.go:148-177`).
- **[MUST]** Pass `?stableid=<routeid>` on the `/ws` URL (`pkg/web/ws.go:254-257`).
- **[MUST]** On **every (re)connect**, send `routeannounce` to `$control` with
  `source=<routeid>` BEFORE issuing routed calls. After a reconnect you must also
  **re-subscribe all events** — the server forgets subscriptions per connection
  (`frontend/app/store/wshrpcutil.ts:24-26`).
- **[MUST]** Match responses by `resid == reqid`. Treat `cont:true` as "more
  chunks coming" and only complete the request on the first non-`cont` reply
  (`pkg/wshutil/wshrpc.go:381-447`).
- **[CHECK]** A request with no `reqid` gets no response — never await one.

## B. Object store

- **[MUST]** Apply `WebReturnType.updates` from **every** HTTP service response
  into the same cache used by event updates. Skipping this leaves the UI stale
  after mutations even though the call "succeeded" (`frontend/app/store/wos.ts:136`).
- **[MUST]** Version-guarded merge: drop any update whose `obj.version <=
  cached.version`. Out-of-order delivery is normal; without the guard you flicker
  back to stale state (`wos.ts:272`).
- **[MUST]** Event subscription **scope is the oref string** (e.g.
  `workspace:<oid>`), not a bare id (`pkg/wps/wps.go:241`).
- **[MUST-NOT]** Assume `Workspace.pinnedtabids` exists — it does not. Tab order
  is `Workspace.tabids`, changed only via `UpdateWorkspaceTabIdsCommand`
  (`pkg/waveobj/wtype.go:174`).

## C. Lifecycle / commands

- **[MUST]** `SetActiveTab` is the trigger that makes the backend start the active
  tab's block controllers — call it on tab switch, not just locally
  (`workspaceservice.go:173`).
- **[MUST]** Honor `CloseTab`'s return `{ closewindow, newactivetabid }`: if
  `closewindow` is set, close the window; otherwise switch to `newactivetabid`
  (`workspaceservice.go:218`).
- **[MUST-NOT]** Move the **last** tab out of a workspace (backend rejects;
  mirror the FE guard `tabCount > 1`).

## T. Terminal output reconciliation ⭐ (highest-risk guard)

The terminal "term" file is a **circular 2 MB** buffer. Output arrives by two
paths that must be merged into one ordered byte stream with **no gaps and no
duplicates**. This is the single most error-prone part of the client.

- **[MUST]** Subscribe to the `blockfile` event (scope `block:<id>`) **before**
  issuing the backfill `GET`. Buffer any live `append` events that arrive during
  the GET (`termwrap.ts:382-448`).
- **[MUST]** Track an **absolute byte offset**. The backfill GET returns the file
  up to its `Size` at request time (via `X-ZoneFileInfo`). The authoritative rule:
  > apply the backfill bytes up to `Size`, then apply only buffered/live `append`
  > events whose cumulative absolute offset **>= `Size`**; discard the overlap.
  (`termwrap.ts:502-525`).
- **[MUST]** Handle `fileop == "truncate"` as "clear the terminal + reset offset"
  (circular wrap / clear-screen). Treat unknown `fileop` as a hard error in debug.
- **[MUST]** Respect the circular start clamp: if you GET with an offset older than
  `DataStartIdx`, the server clamps; recompute from the returned info rather than
  assuming your offset was honored (`filestore/blockstore.go:78-83`).
- **[MUST-NOT]** Re-feed the optional `cache:term:full` snapshot AND the `term`
  file — pick one path. We use `term` from offset; ignore the cache file.
- **[CHECK]** Fuzz with a fast producer (`yes`), a `clear`, a >2 MB burst (forces
  wrap), and a mid-stream WS reconnect. Assert the rendered byte stream equals the
  shell's actual output stream exactly.
- **[MUST]** base64 is **std** encoding both directions (`inputdata64`,
  `data64`). Decode/encode with std, not url-safe (`term-model.ts:509-512`).
- **[MUST]** Send `termsize` on Resync (initial) and on every resize; default
  `{rows:25, cols:80}` if unknown (`blockcontroller.go:358-367`).

## L. Layout

- **[MUST]** Treat `LayoutState` as a **separate object** from `Tab`; load/save it
  via its own oref (`Tab.layoutstate`), not as part of the tab
  (`wtype.go:193`).
- **[MUST]** On load, apply `pendingbackendactions` to your local tree, then
  persist the object back with that array **cleared** — this is how a
  backend-created block (e.g. a `wsh` command opening a block) appears in your
  tiles (`wcore/layout.go:82-142`).
- **[MUST]** Persist the **whole** `LayoutState` object on change (debounce ~100ms)
  — there is no granular layout RPC (`layoutModel.ts:576-594`).
- **[MUST]** Node `size` defaults to `10`; `flexDirection` is `"row"|"column"`
  (`frontend/layout/lib/types.ts:296-302`).

## W. Web block

- **[MUST]** Persist navigation: on WKWebView `didFinish`, write
  `SetMetaCommand { oref: block:<id>, meta: { url } }` so the URL survives reload
  (`webview.tsx:382-386`).
- **[MUST]** Map `web:partition` → a distinct `WKWebsiteDataStore` so per-block
  sessions/cookies stay isolated (mirrors the `<webview>` partition).

## P. Process / spawn

- **[MUST]** Generate a fresh random `WAVETERM_AUTH_KEY` per launch and pass it to
  `wavesrv` via env; never hardcode (`emain/authkey.ts:9`).
- **[MUST]** Point `WAVETERM_DATA_HOME` / `WAVETERM_CONFIG_HOME` at the real Wave
  data dir if you want to share state with the Electron app, or a separate dir for
  an isolated native instance — decide explicitly, don't inherit ambiguously.
- **[CHECK]** Parse the `WAVESRV-ESTART` stderr line robustly; fail fast with a
  clear error if it doesn't appear within a timeout.

---

## How these are enforced

1. Encode A/B/T/L invariants as `precondition`s in the relevant Swift types
   (e.g. the offset reconciler asserts monotonic non-overlapping appends).
2. The e2e harness (see `E2E.md`) drives a real `wavesrv` and asserts the
   observable contract for each guard — especially **§T** (terminal bytes) and
   **§B** (cache freshness after mutations).
3. Any time the code diverges from a guard, fix the code or amend this file with a
   cited reason — never silently weaken a guard.
