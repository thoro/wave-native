# Wave Native — End-to-End Test Harness (Swift)

The native client is only correct if it speaks the real protocol correctly, so the
e2e suite drives a **real `wavesrv`** (no mocks of the broker/DB/pty) and asserts
the observable contract. This is the safety net that lets us refactor the Swift
client freely. Mirrors the project's testing discipline: integration-level e2e for
the service boundary; unit tests for pure logic (offset math, layout reducer).

Framework: **XCTest** (+ optional `swift-snapshot-testing` for UI snapshots).

---

## Core: a real backend per test class

```swift
/// Spawns an isolated wavesrv for tests: random auth key, throwaway data/config
/// dirs, parses WAVESRV-ESTART for the ws/web addresses. Torn down in teardown.
final class WaveServerProcess {
    let webURL: URL          // http://127.0.0.1:<web>
    let wsURL: URL           // ws://127.0.0.1:<ws>/ws
    let authKey: String
    let dataDir: URL         // unique temp dir -> full isolation, parallel-safe

    init() throws { /* spawn, set WAVETERM_AUTH_KEY / DATA_HOME / CONFIG_HOME,
                       read stderr until "WAVESRV-ESTART", capture addrs */ }
    func terminate() { /* SIGTERM, wait, rm dataDir */ }
}
```

Rules:
- **Isolated temp `WAVETERM_DATA_HOME` per test** → no shared state, tests run in
  parallel, no port/file collisions (mirrors the "always testcontainers / never
  fixed host ports" discipline — here, random OS-assigned ports from wavesrv).
- Vendor a known-good `wavesrv` binary (or build it in CI) and pin its version.
- Never assert against a developer's real Wave data dir.

```swift
class WaveE2ECase: XCTestCase {
    var server: WaveServerProcess!
    var client: WaveClient!        // WaveProtocol + WaveStore under test
    override func setUp() async throws {
        server = try WaveServerProcess()
        client = try await WaveClient.connect(web: server.webURL, ws: server.wsURL,
                                              authKey: server.authKey,
                                              route: "window:\(testWindowId)")
    }
    override func tearDown() { client.close(); server.terminate() }
}
```

---

## Gates (one per ROADMAP stage)

### E2E-1 Transport
- Connect, announce `window:<id>`, HTTP `GetClientData`, wsh `GetMeta`/`ResolveIds`.
- Force-close the socket; assert auto-reconnect **and** re-announce **and**
  re-subscribe (subscriptions are per-connection — GUARDS §A).
- Assert ping→pong keeps the socket alive past 15s.

### E2E-2 Object store
- Load `client→window→workspace→tab`. Mutate via `UpdateTabName`.
- Assert the cache updates from the returned `updates` AND from the later
  `waveobj:update`, and that an out-of-order/older-version update is **ignored**
  (GUARDS §B).

### E2E-3 Commands
- create workspace → 3 tabs → reorder (`UpdateWorkspaceTabIds`) → `SetActiveTab`
  → `MoveTab` to another workspace → `CloseTab`.
- Assert object graph; assert `CloseTab` return drives close-window vs switch;
  assert moving the **last** tab is rejected.

### E2E-4 Terminal (the keystone fuzz) ⭐
The authoritative correctness proof. Run a shell command with known output and
assert the byte stream the client feeds libghostty **equals** the shell's actual
stdout — byte-for-byte, no dup/drop — across:
```
a) `printf` of a known string           -> exact match
b) `yes | head -c 5_000_000`            -> fast flood, forces 2MB circular wrap
c) `clear`                              -> truncate handling (GUARDS §T)
d) reconnect WS mid-stream              -> backfill+offset catch-up, no gap/dup
e) resize (rows/cols) then more output  -> termsize propagated, stream intact
```
Implementation: replace libghostty with a **capturing sink** in this test (collect
the decoded bytes), and independently capture the real shell output (run the same
command via a control pty) to compare. Assert equality.
Also unit-test the offset reconciler in isolation with synthetic append/backfill
sequences (subscribe-before-backfill overlap, wrap, truncate).

### E2E-5 Layout
- One terminal → split to 2×2 → resize → close one. Reload client; assert the
  `LayoutState` tree round-trips.
- Have `wsh` (or a `CreateBlock` from another route) add a block; assert it
  appears via `pendingbackendactions` apply-and-clear (GUARDS §L).

### E2E-6 Web block
- Open web block, navigate; assert `url` persisted via `SetMeta`; reload → same
  URL. Two blocks, different `web:partition` → isolated cookies (GUARDS §W).

### E2E-7 Chrome + snapshot
- Open/switch/close/reorder tabs; switch workspaces. Each maps to the right RPC
  and updates the UI.
- **Snapshot tests:** render the window and key components offscreen; diff against
  baseline PNGs captured from the Electron app (default dark) into
  `tests/snapshots/`. Assert: window bg `#222`, 33px blurred strip, 130px pill
  tabs with white-10% active fill, terminal `default-dark` palette on `#000`, 2px
  green focus border, Inter/Hack fonts.

---

## What is NOT mocked
- `wavesrv`, its DB/filestore, the pty/shell controllers, the wps broker — all
  real. We only substitute libghostty with a capturing sink **inside the terminal
  byte-stream test** so we can assert exact bytes.

## CI
- Build `wavesrv` (Go) + the Swift package; run XCTest on a macOS runner.
- Gates E2E-1..6 are headless; E2E-7 needs a windowserver (use a macOS GUI runner
  or `xcodebuild test` with an app host). Keep snapshot baselines in-repo.
- Run the terminal fuzz (E2E-4) with a high iteration count nightly.
