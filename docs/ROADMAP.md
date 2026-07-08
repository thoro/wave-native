# Wave Native — Implementation Workflow (end-to-end, Swift)

A staged build plan. Each stage has a **deliverable**, the **guards** it must
satisfy (see `GUARDS.md`), and an **e2e gate** (see `E2E.md`) that must be green
before moving on. The ordering front-loads the two genuine risks (transport, then
terminal reconciliation) so we fail fast on the hard parts.

Principle: **contract-first, UI-last.** We prove the protocol against a real
`wavesrv` headlessly before drawing a single pixel, then layer UI on a verified
core. Every stage is independently testable.

---

## Stage 0 — Project skeleton & toolchain
**Deliverable:** Xcode project (or SwiftPM package + app target), libghostty
linked and rendering a static grid, Inter + Hack bundled, `Theme.swift` in.
**Gate:** app launches to an empty window using `Theme.windowBackground`; a
libghostty view renders "hello" with the `default-dark` palette + Hack 12.
**Risk:** libghostty embedding/build. De-risk this first — it's the one external
dependency.

## Stage 1 — Transport (`WaveProtocol`)  ⭐ risk #3
**Deliverable:** spawn `wavesrv` (env + `WAVESRV-ESTART` parse), HTTP service
client, WS client (asymmetric framing), `RpcMessage` codec, reqid/resid matching,
`cont` streaming, ping/pong, `routeannounce`, auth header, reconnect+re-announce.
**Guards:** A (all). 
**Gate E2E-1:** spawn a real `wavesrv`, connect, announce `window:<id>`,
round-trip `GetClientData` over HTTP and a `ResolveIds`/`GetMeta` over wsh; kill
the socket and confirm auto-reconnect + re-announce + re-subscribe.

## Stage 2 — Object store (`WaveStore`)
**Deliverable:** oref-keyed observable cache; `load(oref)`; `waveobj:update`
subscription (scope = oref); version-guarded merge; apply inline `updates` from
every HTTP response.
**Guards:** B (all).
**Gate E2E-2:** load `client→window→workspace→tab`; mutate tab name via
`UpdateTabName`; assert the cache reflects it from BOTH the returned `updates` and
a subsequent `waveobj:update`, with no version regressions.

## Stage 3 — Workspace/Tab/Window commands (`WaveCommands`)
**Deliverable:** typed wrappers for §3 RPCs (create/close/switch/setactive/move/
reorder workspace+tab+window+block).
**Guards:** C (all).
**Gate E2E-3:** create workspace → create 3 tabs → reorder → set active → move a
tab to another workspace → close tabs; assert object graph + `closewindow`/
`newactivetabid` handling; assert "can't move last tab" is rejected.

## Stage 4 — Terminal (`WaveTerminal`)  ⭐ risk #1 (the big one)
**Deliverable:** on a terminal block — `ControllerResync`, subscribe `blockfile`
**before** backfill, HTTP backfill, absolute-offset reconciliation, feed bytes to
libghostty, libghostty key output → `ControllerInput` (base64 std), resize.
**Guards:** T (all) — especially the offset rule and truncate handling.
**Gate E2E-4 (fuzz):** drive a real shell; assert the byte stream libghostty
receives equals the shell's actual stdout exactly under: (a) `yes` flood, (b)
`clear`, (c) >2 MB burst (circular wrap), (d) WS reconnect mid-stream, (e) resize.
Zero dup/drop. **This gate is the project's main correctness proof.**

## Stage 5 — Layout (`WaveLayout`)
**Deliverable:** `LayoutState` model (separate object), tree reducer (split/
insert/delete/resize), debounced whole-object persist, apply-and-clear
`pendingbackendactions`.
**Guards:** L (all).
**Gate E2E-5:** open a tab with one terminal; split into a 2×2 of terminals;
resize; close one; reload the app and assert the tree round-trips; have `wsh`
create a block on the tab and assert it appears via `pendingbackendactions`.

## Stage 6 — Web block (`WaveWeb`)
**Deliverable:** WKWebView bound to block meta; load `meta.url`; persist on
`didFinish`; `web:partition`→`WKWebsiteDataStore`; back/forward/reload/zoom.
**Guards:** W (all).
**Gate E2E-6:** open a web block, navigate, assert `url` persisted via `SetMeta`;
reload app → same URL; two blocks with different partitions keep separate cookies.

## Stage 7 — Window chrome (`WaveApp`, AppKit)
**Deliverable:** hiddenInset window, the tab strip (33px, blurred, drag region),
pill tabs (130px, white-10% active), new-tab "+", workspace switcher dropdown,
full init sequence (§7), `SetActiveTab` on switch.
**Guards:** STYLE.md acceptance; C (SetActiveTab).
**Gate E2E-7 + snapshot:** open/switch/close/reorder tabs and switch workspaces
all work; capture screenshots into `tests/snapshots/` and diff against the
Electron app (window bg, strip, tabs, focus border, fonts, terminal palette).

## Stage 8 — Polish & parity sweep
**Deliverable:** keyboard shortcuts (Cmd+T/W/1–9, tab/workspace switch), focus
border on active block, scrollbars, modal shadows, cursor block/no-blink.
**Gate:** side-by-side parity review vs Electron; all earlier e2e gates still
green.

---

## Risk-ordered effort (where the time actually goes)
1. **Stage 4 (terminal reconciliation)** — LARGE, the #1 unknown. Spec one
   authoritative offset rule (GUARDS §T) and fuzz it hard.
2. **Stage 5 (layout reducer + pending-actions)** — LARGE; tree math + handshake.
3. **Stages 1–2 (transport + store)** — MEDIUM; prerequisite for everything.
4. **Stages 3, 6, 7** — SMALL/MEDIUM; mostly direct mappings.
5. **Stage 0 (libghostty embed)** — MEDIUM external risk; do it first.

## Working agreement
- Contract-first: no stage proceeds until its e2e gate is green.
- Guards are encoded as `precondition`/asserts + tests, not just prose.
- Each stage is a separate PR/commit on the native repo.
- When code and `PROTOCOL.md`/`GUARDS.md` disagree, fix code or amend the doc with
  a cited reason — never silently drift.
