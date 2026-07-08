# Wave Native — Integration & Build Guide

How to assemble, build, and ship the native macOS client, what is implemented at
each ROADMAP stage, the known gaps (with concrete fixes), and the order in which
to run the e2e gates.

> Authoritative contracts: `docs/PROTOCOL.md` (wavesrv wire contract),
> `docs/GUARDS.md` (invariants), `docs/STYLE.md` + `Sources/WaveUI/Theme.swift`
> (visual spec), `docs/ROADMAP.md` (stages), `docs/E2E.md` (gates). When code and
> a doc disagree, the code wins — fix the code or amend the doc with a cited reason.

The package targets **macOS / Swift 5.9 / AppKit** and **does not build on Linux**
(WebKit, AppKit, libghostty). All build/run/test steps below assume a Mac.

---

## 1. Mac build steps

### 1.0 Prerequisites
- **Xcode 15+** (Swift 5.9 toolchain).
- **Zig** (current stable) — to build libghostty from source.
- **Go 1.22+** — to build `wavesrv` from the Wave repo at `/workspace`.
- Fonts **Inter** and **Hack** (`.ttf`/`.otf`) to bundle.

### 1.1 Build & link libghostty-vt (Stage 0, the one external dependency)
The terminal block is driven by **libghostty-vt** — Ghostty's headless terminal
core (escape parsing, grid + scrollback state, key/mouse encoding, and a
render-state API for custom renderers). WaveTerminal feeds it the reconciled byte
stream and renders the grid natively with CoreText (it does **not** use Ghostty's
GUI surface / Metal renderer). `Sources/CGhostty` binds the real
`<ghostty/vt.h>`; `Sources/WaveTerminal/{TerminalSink,GhosttyTerminalView}.swift`
use it.

**One command does everything below** (clone + build the right zig + libghostty-vt
+ wavesrv + fonts, all vendored): `scripts/build-deps.sh`. The manual steps:

```sh
git clone https://github.com/ghostty-org/ghostty
cd ghostty
# Ghostty requires zig 0.15.2 EXACTLY. On macOS 26 (Tahoe) the upstream
# ziglang.org 0.15.2 binary CANNOT link (it can't parse the macOS 26 SDK's
# libSystem.tbd). Use Homebrew's patched bottle instead:
#   brew tap --force homebrew/core
#   brew extract --version=0.15.2 zig local/zigpin && brew install local/zigpin/zig@0.15.2
/opt/homebrew/opt/zig@0.15.2/bin/zig build -Doptimize=ReleaseFast -Demit-lib-vt=true --prefix zig-out
# -> zig-out/lib/libghostty-vt.a  and  zig-out/include/ghostty/vt.h (+ subheaders)
```

The build script vendors the artifacts to `vendor/libghostty/{lib,include}`.
Build/run the package with the header + (static) library search paths (the
modulemap's `link "ghostty-vt"` emits `-lghostty-vt`):

```sh
swift build \
  -Xcc     -Ivendor/libghostty/include \
  -Xlinker -Lvendor/libghostty/lib -lghostty-vt
# swift run WaveApp ...same -Xcc/-Xlinker flags, plus WAVE_NATIVE_WAVESRV=bin/wavesrv.arm64
```

Only `libghostty-vt.a` is vendored (not the `.dylib`), so it links **statically** —
no `@rpath`/copy-files phase needed. In **Xcode**: set `HEADER_SEARCH_PATHS` →
`vendor/libghostty/include`, `LIBRARY_SEARCH_PATHS` → `vendor/libghostty/lib`, and
add `libghostty-vt.a` under *Link Binary With Libraries*.

> The whole package (WaveUI/WaveApp/WaveE2ETests) transitively depends on
> `CGhostty`, so **nothing in the app or test target links without libghostty-vt on
> the search path** — do this first.

### 1.2 Build wavesrv (the backend the client drives)
From the Wave repo at `/workspace` (entry `cmd/server/main-server.go`):

```sh
cd /workspace
go build -o /usr/local/bin/wavesrv ./cmd/server
```

Either **bundle** it into the `.app` (`Contents/Resources/wavesrv` — `main.swift`
resolves `Bundle.main.url(forResource:"wavesrv")`), or for dev/CI export
`WAVE_NATIVE_WAVESRV=/usr/local/bin/wavesrv` (checked first by `main.swift` and by
the e2e harness). With neither, `main.swift` falls back to `wavesrv` on `PATH`.

### 1.3 Bundle Inter + Hack fonts (STYLE §2)
`Theme.swift` falls back to system fonts if these are absent, which **breaks the
snapshot baselines**. To ship them:
- Add `Inter-*.otf` + `Hack-*.ttf` to the app target's *Copy Bundle Resources*.
- Add `ATSApplicationFontsPath` = `.` (or `Fonts`) to `Info.plist` so AppKit
  registers them on launch; or register at startup with
  `CTFontManagerRegisterFontsForURL` over the bundled font URLs.

### 1.4 Produce a real `.app`
`swift run WaveApp` is enough to verify launch, but a shippable client needs a
proper bundle (native traffic lights, font registration, bundled `wavesrv`,
`Info.plist`). Wrap the SwiftPM executable in an **Xcode app target** (or a
post-build bundler) — `runWaveApp` already creates the `NSApplication`,
`hiddenInset` window (`WaveWindow.swift`), and drives the PROTOCOL §7 init.

---

## 2. ROADMAP stage → files map

| Stage | Module(s) | Implementation files | Tests / gate files |
|---|---|---|---|
| **0** Skeleton & toolchain | package, CGhostty, Theme | `Package.swift`, `Sources/CGhostty/{module.modulemap,ghostty_shim.h}`, `Sources/WaveUI/Theme.swift`, `Sources/WaveApp/{main.swift,ComposedBlockViewProvider.swift}` | — |
| **1** Transport `WaveProtocol` (§1, GUARDS A/P) | WaveProtocol, WaveCore | `Sources/WaveProtocol/{WSFraming,WSChannel,WaveProcess,HTTPServiceClient,WaveTransportClient}.swift`; `Sources/WaveCore/{WireTypes,ServerAddrs,Errors,Base64,Protocols}.swift` | `WaveProtocolTests.swift`, `WaveCoreTests.swift`; **E2E-1** `WaveE2EGateTests.swift` |
| **2** Object store `WaveStore` (§2, GUARDS B) | WaveStore, WaveCore | `Sources/WaveStore/ObjectStore.swift`; `Sources/WaveCore/{WaveObj,Models,JSONValue,ORef}.swift` | `WaveStoreTests.swift`; **E2E-2** `WaveE2EGateTests.swift` |
| **3** Commands `WaveCommands` (§3, GUARDS C) | WaveCommands | `Sources/WaveCommands/WaveCommands.swift` | `WaveCommandsTests.swift`; **E2E-3** `WaveE2EGateTests.swift` |
| **4** Terminal `WaveTerminal` (§4, GUARDS T) ⭐ | WaveTerminal | `Sources/WaveTerminal/{TerminalReconciler,TerminalSink,TerminalController}.swift` | `WaveTerminalTests.swift`, `TerminalReconcilerFuzzTests.swift`; **E2E-4** `TerminalE2ETests.swift` (+ `E2EHarness.swift`) |
| **5** Layout `WaveLayout` (§6, GUARDS L) | WaveLayout | `Sources/WaveLayout/{LayoutTree,LayoutAction,LayoutReducer,LayoutModel}.swift` | `WaveLayoutTests.swift`; **E2E-5** `WaveLayoutE2ETests.swift` |
| **6** Web `WaveWeb` (§5, GUARDS W) | WaveWeb | `Sources/WaveWeb/{WebBlockState,WebPartitionStore,WebBlockModel,WebBlockView}.swift` | `WebBlockStateTests.swift`; **E2E-6** `WebBlockE2ETests.swift` |
| **7** Chrome `WaveUI` + `WaveApp` (§7, STYLE, GUARDS C) | WaveUI, WaveApp | `Sources/WaveUI/{ServiceClient,BlockViewProvider,BlockFrameView,LayoutTreeView,DragViews,TabPillView,TabBarView,WorkspaceSwitcherView,AppCoordinator,WaveWindow,WaveWindowController,AppEntry}.swift`; `Sources/WaveApp/{main,ComposedBlockViewProvider}.swift` | `WaveUITests.swift`; **E2E-7** `ChromeE2ETests.swift`, `SnapshotTests.swift` (+ `SnapshotSupport.swift`, `RecordingTransport.swift`), `tests/snapshots/` |

Shared test harness: `Tests/WaveE2ETests/WaveServerProcess.swift` (canonical real
`wavesrv` per test) + `E2EHarness.swift` (terminal fixture, sink, bridge).

---

## 3. Gap list — how to close each

Severity and locations from the adversarial audit. Items marked **[fixed]** were
closed in this pass (see §5).

### G1 — Terminal offset reconciler drops bytes (critical)
`Sources/WaveTerminal/TerminalReconciler.swift` · `applyBackfill`
**Problem:** the buffered (pre-backfill) appends are anchored at `requestedOffset`
(`cursor = requestedOffset`). That is only correct when the file tail at subscribe
time equals `requestedOffset`. On a remount of an already-populated, still-producing
terminal (`mount()` always backfills from 0) or any reconnect where output was
produced during the outage, `fileTailAtSubscribe > requestedOffset`, so a live
`append` racing the GET is computed with offset `<< Size` and silently discarded by
the `chunkEnd <= info.size` branch. Result: a silent gap; `absOffset` is then stuck
at `info.size` so all later appends are mis-anchored too. `WSFileEventData` carries
no per-append offset (`pkg/wps/wpstypes.go:87-92`), so a `requestedOffset`-based
reconstruction cannot be correct.

**Fix (client-only, correct):** anchor by **content overlap**, not by
`requestedOffset`. Appends are a contiguous suffix of the file; because we subscribe
*before* the GET, the buffered concatenation begins at the tail-at-subscribe `S0`
and its prefix `[S0, Size)` is byte-identical to the **tail of the backfill**. In
`applyBackfill`:
1. Let `B = concat(buffered)`.
2. Find the largest `k`, `0 ≤ k ≤ min(data.count, B.count)`, such that
   `data.suffix(k) == B.prefix(k)`.
3. Emit `data` then `B.dropFirst(k)`; set `absOffset = info.size + (B.count - k)`.
   (Worked example from the audit — `Size=1500`, buffered `D=[1500,1550)` of new
   content — gives `k=0`, so `D` is kept and `absOffset=1550`. The current code
   drops `D`.) Empty buffer ⇒ `k=0`, unchanged behavior. The fresh-mount `Size==0`
   case stays correct.

**Fix (robust, server-side, recommended in addition):** add an absolute `offset`
to `WSFileEventData` at the publisher (`pkg/blockcontroller/blockcontroller.go:369-389`,
type `pkg/wps/wpstypes.go:87-92`) and decode it in
`TerminalController.handleFileEvent`; then dedup by true offset with no content
matching. This also removes the one pathological-content corner of the client-only fix.

### G2 — Reconciler fuzz can't catch G1 (high)
`Tests/WaveE2ETests/TerminalReconcilerFuzzTests.swift`
**Problem:** `testFuzz…NoGapNoDup` sets the buffered bytes to start exactly at
`requested`, and `testFuzzReconnectCatchUpAcrossEpochs` sets `requested = consumed =
truth.count` ("file tail at subscribe == consumed"), i.e. it never models output
produced during the outage — the exact case G1 breaks.
**Fix:** add a property that sets `fileTailAtSubscribe > requested` (produce
`outageBytes` so `Size = requested + overlap + outageBytes`), build the buffered
region to start at the real tail, and assert the reconciled stream equals
`truth[requested...]` exactly. This must **fail against the current code** (proving
G1) and pass after the G1 fix.

### G3 — `handleReconnect` never wired in production (high)
`Sources/WaveTerminal/TerminalController.swift` (+ `Sources/WaveCore/Protocols.swift`,
`Sources/WaveProtocol/WaveTransportClient.swift`, `Sources/WaveUI/AppCoordinator.swift`)
**Problem:** `TerminalController.handleReconnect()` is called only from tests. In
production the transport auto-reconnects and `resubscribeAll()`s, so live appends
resume into the still-loaded reconciler via `append()` and **contiguously skip every
byte produced while the socket was down** — a permanent silent gap. `handleEvent`
ignores `connChange` ("not chrome concerns yet", `AppCoordinator.swift` ~L192) and
the transport exposes no reconnect signal.
**Fix:**
1. Add `var onReconnect: (@Sendable () -> Void)? { get set }` to `WaveTransport`
   (`Protocols.swift`).
2. In `WaveTransportClient.establish()` track first-connect vs reconnect (a
   `hasConnectedOnce` flag); after `resubscribeAll()` + `_connected = true`, if it
   was a reconnect, invoke `onReconnect` (hop off the lock).
3. Have the owner of the live `TerminalController`s register `onReconnect` and call
   `controller.handleReconnect()` for each mounted terminal. Once G1 is fixed the
   re-backfill from `currentOffset` catches up correctly.

### G4 — No real `BlockViewProvider` (critical) — **[fixed]**
`Sources/WaveUI/BlockViewProvider.swift`, `Sources/WaveApp/ComposedBlockViewProvider.swift`
**Was:** only `DefaultBlockViewProvider` (a placeholder panel) existed; nothing
constructed real terminal/web views.
**Done (web):** `ComposedBlockViewProvider` renders **web** blocks via
`WebBlockView`/`WebBlockModel`, injected through `runWaveApp(provider:)`.
**Done (terminal):** the `"term"` case now builds a real stack against
**libghostty-vt**: `GhosttySink` owns a `GhosttyTerminal` (`ghostty_terminal_new`,
`…_vt_write`, `…_resize`, `…_reset`) and routes query responses out via the
write-pty callback; `GhosttyTerminalView` (new) reads the grid with the
render-state API and draws it with CoreText, and encodes AppKit key events to pty
bytes; `TerminalController` drives PROTOCOL §4. The whole package builds **and
links** against `libghostty-vt.a`.
**Remaining (renderer fidelity, non-blocking):** the CoreText renderer is a first
cut — no bold/italic font variants, underline/strikethrough decorations,
selection rendering, mouse reporting, or the Kitty keyboard protocol (it maps keys
directly instead of via libghostty-vt's key encoder). See
`Sources/WaveTerminal/GhosttyTerminalView.swift` header for the exact list.

### G5 — Executable was a no-op (critical) — **[fixed]**
`Sources/WaveApp/main.swift`, `Package.swift`
**Was:** `main.swift` was `_ = WaveUIModule.implements` (started no app); the false
comment claimed `WaveTransportClient`/`ObjectStore` had no public constructor, and
`WaveApp` depended only on `WaveUI`.
**Done:** `WaveApp` now also depends on `WaveProtocol`/`WaveStore`/`WaveWeb`;
`main.swift` resolves the wavesrv path, constructs `WaveTransportClient(wavesrvPath:)`
+ `ObjectStore(transport:)`, and calls `runWaveApp(transport:store:provider:)`.

### G6 — `web:partition` not isolated for persistent stores on macOS 13 (medium)
`Sources/WaveWeb/WebPartitionStore.swift`
**Problem:** `WKWebsiteDataStore(forIdentifier:)` is macOS 14+. On the macOS-13
target, `persist:NAME` partitions fall back to `WKWebsiteDataStore.default()`, so
distinct blocks **share cookies** — GUARDS §W [MUST] is unmet for the persistent case.
**Fix:** bump the deployment target to **macOS 14** in `Package.swift`
(`platforms: [.macOS(.v14)]`) and drop the `#available` fallback so persistent
partitions always map to a distinct `forIdentifier:` store (use a deterministic
UUIDv5 of the name as identifier — already computed in `makeStore`). Amend STYLE
§6 / PROTOCOL note that the target is macOS 14. (Ephemeral named partitions are
already isolated on all versions.)

### G7 — E2E-6 partition isolation not actually verified (medium)
`Tests/WaveE2ETests/WebBlockE2ETests.swift`
**Problem:** `testDistinctPartitionsAreIsolated` only asserts data-store *identity*
with *ephemeral* partitions; the real "different `web:partition` → separate cookies"
round-trip is deferred to the GUI lane.
**Fix (GUI lane):** in a windowserver runner, load a page in block A's `WKWebView`
that sets `document.cookie`, then assert block B's `WKWebView` does **not** see it;
with the G6 macOS-14 change, also assert a `persist:` cookie survives recreating the
store by identifier.

### G8 — No snapshot baselines committed (medium)
`Tests/snapshots/` (only `README.md`)
**Problem:** `SnapshotTests.assertBaseline` diffs are inert; the "looks like
Electron" net doesn't exist. Only the literal-`Theme` assertions run.
**Fix:** capture the Electron baselines per `Tests/snapshots/README.md`
(`screencapture -R` at zoom 1.0 from a clean default-dark profile) → commit
`electron-*.png`; run `SnapshotTests` once with `WAVE_NATIVE_RECORD_SNAPSHOTS=1` to
record native `*-default.png`, verify against Electron (window bg `#222`, 33px
strip, 130px pills, 2px `#58c142` focus border, terminal `default-dark` on `#000`,
Inter/Hack), then commit. Requires §1.3 fonts bundled or the diffs drift.

### G9 — E2E-4 reconnect gate passes only by timing luck (medium)
`Tests/WaveE2ETests/TerminalE2ETests.swift` · `testReconnectMidStreamCatchUp`
**Problem:** correctness depends on no live append racing between reconciler reset
and `applyBackfill` (buffered-empty is coincidentally correct). Under load an
append races, hits G1, and the contiguity assert fails — non-deterministic.
**Fix:** depends on **G1 + G3**. After both, drive >0 output that genuinely races
`applyBackfill` during the outage and assert exact contiguity; the gate then proves
§T reconnect catch-up deterministically.

### H1 — Duplicate `WaveServerProcess` broke the whole test target (build-blocker) — **[fixed]**
`Tests/WaveE2ETests/E2EHarness.swift`
**Was:** `E2EHarness.swift` and `WaveServerProcess.swift` both declared
`WaveServerProcess` (different APIs) → duplicate symbol, entire `WaveE2ETests`
target failed to compile.
**Done:** removed the duplicate from `E2EHarness.swift`; `TerminalE2EFixture` now
uses the canonical `WaveServerProcess(binaryPath:)` (sync init) from
`WaveServerProcess.swift`.

### H2 — Inconsistent wavesrv-locator env vars (low)
The canonical harness + `main.swift` read **`WAVE_NATIVE_WAVESRV`**;
`E2EHarness.requireWavesrvBinary()` reads **`WAVE_E2E_WAVESRV` / `WAVE_WAVESRV_PATH`
/ `WAVESRV_PATH`**. So the terminal fixture (E2E-4) and the other gates can be
"skipped" independently depending on which var is set.
**Fix:** unify — have `requireWavesrvBinary()` also accept `WAVE_NATIVE_WAVESRV`
(or have `locateBinaryOrSkip()` accept the `WAVE_E2E_*` set). Until then, **export
all of them to the same path** in CI.

---

## 4. E2E gate run order

Gates are contract-first and staged; run in order, each must be green before the
next (ROADMAP "working agreement").

**No backend required (always run, fast):**
- Unit/logic: `WaveCoreTests`, `WaveProtocolTests`, `WaveStoreTests`,
  `WaveCommandsTests`, `WaveTerminalTests`, `WaveLayoutTests`, `WebBlockStateTests`,
  `WaveUITests`.
- **Reconciler fuzz** `TerminalReconcilerFuzzTests` (the §T correctness proof in
  isolation — prints its seed on failure).

**Real-backend gates (need a built `wavesrv` + the env var, §1.2):**
1. **E2E-1** Transport — `WaveE2EGateTests` (connect/announce/round-trip, ping/pong
   past 15s, force-drop → auto-reconnect + re-announce + re-subscribe). GUARDS A/P.
2. **E2E-2** Store — `WaveE2EGateTests` (inline `updates` + live `waveobj:update`,
   version-guarded merge). GUARDS B.
3. **E2E-3** Commands — `WaveE2EGateTests` (create/reorder/setactive/move/close;
   last-tab-move rejected; `closewindow`/`newactivetabid` honored). GUARDS C.
4. **E2E-4** Terminal ⭐ — `TerminalE2ETests` (printf exact bytes, >2 MB wrap,
   clear/truncate, reconnect catch-up, resize). GUARDS T (+A). *Note G1/G9 before
   trusting the reconnect sub-case.*
5. **E2E-5** Layout — `WaveLayoutE2ETests` (tree round-trips a reload;
   backend-created block appears via `pendingbackendactions` apply-and-clear). GUARDS L.
6. **E2E-6** Web — `WebBlockE2ETests` (navigate → `SetMeta` persist → reload same
   URL; partition store distinctness). GUARDS W. *Cookie round-trip = GUI lane, G7.*

**GUI lane (windowserver / `xcodebuild test` with an app host):**
7. **E2E-7** Chrome + snapshot — `ChromeE2ETests` (tab/workspace ops → correct RPCs
   + UI) and `SnapshotTests` (pixel-diff vs Electron). STYLE + GUARDS C. *Needs the
   committed baselines, G8, and bundled fonts, §1.3.*

CI: build `wavesrv` (Go) + the Swift package (with libghostty flags), export the
locator env var(s) (H2), run E2E-1..6 headless, run E2E-7 + snapshots on a GUI
runner, run the terminal fuzz at high iteration count nightly.

---

## 5. What changed in this pass (Swift fixes applied)

Trivial / build-blocking fixes only; the non-trivial gaps (G1, G2, G3, G6, G7, G8,
G9 and the terminal half of G4) are documented above for follow-up.

- **`Sources/WaveApp/main.swift`** — replaced the no-op body with the real
  composition: resolve wavesrv path (`WAVE_NATIVE_WAVESRV` → bundled → PATH),
  construct `WaveTransportClient` + `ObjectStore`, call
  `runWaveApp(transport:store:provider:)`. Removed the false "no public
  constructor" comment. (Closes **G5**.)
- **`Sources/WaveApp/ComposedBlockViewProvider.swift`** — new. A real
  `BlockViewProvider` that renders `"web"` blocks via `WebBlockView`/`WebBlockModel`
  and falls back to the placeholder for `"term"` (libghostty-gated). (Closes the
  web half of **G4**.)
- **`Package.swift`** — `WaveApp` target now depends on
  `["WaveUI", "WaveProtocol", "WaveStore", "WaveWeb"]` so the composition root can
  build the concrete objects + provider. (Supports **G5/G4**.)
- **`Tests/WaveE2ETests/E2EHarness.swift`** — removed the duplicate
  `WaveServerProcess` class (left a pointer comment) and changed
  `TerminalE2EFixture.make()` to use the canonical sync `WaveServerProcess(binaryPath:)`.
  (Closes **H1** — the whole `WaveE2ETests` target now compiles.)
