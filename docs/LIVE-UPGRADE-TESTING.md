# Live-Upgrade Testing (wave-native)

How to test the seamless live-upgrade behavior using two builds with different
**fake version strings**.

## Concept

- `wavesrv` (the Go backend) is launched **detached** and **survives** the app
  exiting (stdin = O_RDWR FIFO, stderr → a log file, not a pipe). A new app launch
  attaches to the running `wavesrv` via `<dataHome>/wavesrv-running.json`.
- The app is **single-instance per data home**, gated by `AppInstanceGate` over a
  unix control socket (`AppSingleInstance`). The version each instance reports is
  `WAVE_NATIVE_VERSION` (env override) or the built-in `WaveProtocolConst.nativeVersion()`.

| Launch scenario | Behavior |
| --- | --- |
| No instance running | Normal first launch: spawn `wavesrv`, open the window(s). |
| Running instance, **same** version | The new process asks the running one to **open a new window**, then exits. No second UI. |
| Running instance, **different** version (an upgrade) | The new process tells the old one to **shut down its UI + exit** (windows close), waits for its lock, then **takes over** — `wavesrv` is restarted/upgraded too, but durable local PTYs survive via the job-manager re-adoption, and the new instance **restores the same windows** (one per previously-open workspace). |

## Setting the fake version

Set `WAVE_NATIVE_VERSION` per launch. Two distinct values simulate "old" vs "new".

```bash
NATIVE=/path/to/wave-native
BIN="$NATIVE/.build/arm64-apple-macosx/debug/WaveApp"   # or dist/WaveNative.app/Contents/MacOS/WaveApp
WSRV="$NATIVE/bin/wavesrv.arm64"
```

## Recipe A — different version (the upgrade takeover)

1. **Run v1** and set up state:
   ```bash
   WAVE_NATIVE_VERSION=v1 WAVE_NATIVE_WAVESRV="$WSRV" "$BIN" &
   ```
   Open a couple of workspaces/windows; in a terminal run something with visible,
   long-lived state, e.g. `while true; do date; sleep 1; done`, and `top` in another.
   Note the `wavesrv` pid:
   ```bash
   cat "$HOME/Library/Application Support/waveterm-native/wavesrv-running.json"
   ```

2. **Open v2** (a different version) — simulating double-clicking the upgraded `.app`:
   ```bash
   WAVE_NATIVE_VERSION=v2 WAVE_NATIVE_WAVESRV="$WSRV" "$BIN" &
   ```

3. **Expected**:
   - The v1 windows **close** (its UI shuts down and v1 exits).
   - `wavesrv` **restarts** (a new pid in the descriptor) — but the durable local
     PTYs survive (the `wsh jobmanager` daemons are SIGHUP-ignored and re-adopted).
   - v2 **restores the same windows** (one per workspace that was open) and the
     terminals **resume** — the `date` loop keeps printing, `top` is still running.

4. **Verify the version handoff** — the descriptor's `version` field now reflects the
   primary that owns `wavesrv`, and changes from `v1` to `v2` across the takeover:
   ```bash
   DH="$HOME/Library/Application Support/waveterm-native"
   python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print("version=",d.get("version")," pid=",d["pid"])' \
     "$DH/wavesrv-running.json"
   ```

## Recipe B — same version (new window)

1. Run v1 (as above), open a window.
2. Launch **the same version again**:
   ```bash
   WAVE_NATIVE_VERSION=v1 WAVE_NATIVE_WAVESRV="$WSRV" "$BIN" &
   ```
3. **Expected**: no second app process stays up — the running v1 instance simply
   **opens a new window**; the second launch exits immediately.

## Recipe C — wavesrv survives an app-only restart

1. Run v1, open a terminal with state.
2. Quit the app (Cmd-Q / kill the WaveApp process).
3. Confirm `wavesrv` is **still alive** (`ps -p <pid>` from the descriptor).
4. Relaunch v1 → it **attaches** to the same `wavesrv` (descriptor pid unchanged) and
   the terminals resume.

## Side-by-side test build (`make testapp`)

The env overrides above work for a shell launch, but a **double-click** launch doesn't
inherit a shell `WAVETERM_DATA_HOME`. For a build you can run alongside the real app,
use the test target:

```bash
make testapp     # builds dist/WaveNativeTest.app + opens it
make testbundle  # same build, release config, without launching
```

It produces a differently-named bundle — `WaveNativeTest.app` / "Wave Native (Test)" /
id `dev.commandline.wave-native.test` — whose Info.plist bakes
`WAVETERM_DATA_HOME`/`WAVETERM_CONFIG_HOME` = `~/Library/Application Support/waveterm-native-test`
into `LSEnvironment`, so even a Finder open lands in the isolated home. Because it's a
distinct data home it forms its own single-instance group and never touches the real
`waveterm-native` state. Override the identity/home with the `WAVE_APP_NAME`,
`WAVE_APP_DISPLAY_NAME`, `WAVE_APP_BUNDLE_ID`, `WAVE_DATA_HOME`, `WAVE_CONFIG_HOME`
env vars to `scripts/bundle-app.sh`.

## Notes / gotchas

- Everything uses the isolated data home `~/Library/Application Support/waveterm-native`
  (override with `WAVETERM_DATA_HOME`). All instances that share a data home form one
  single-instance group, so use the SAME data home for both launches.
- Per-data-home control files written by the gate:
  - `wave-native-app.lock` — the flock the live primary holds for its lifetime.
  - `wave-native.sock` — the primary's control socket (`OPEN` / `SHUTDOWN` ops).
  - `wave-native-open-windows.json` — best-effort record of the open workspaces (the
    authoritative restore source is the backend `client.windowids`, which survives the
    wavesrv restart).
  - `wavesrv-running.json` — the running-server descriptor (now includes `version`).
- If a launch wedges, clean `wavesrv-running.json`, `wavesrv.lock`, `wavesrv.stdin.fifo`,
  `wave-native-app.lock`, `wave-native.sock`, and `pkill -f wavesrv`.
- For a real `.app` upgrade, ship the two builds with different baked-in
  `WaveProtocolConst.nativeVersion()` values (or keep using the env override for
  testing).
