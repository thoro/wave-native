#!/usr/bin/env bash
# Isolated driver-test launcher. Runs the app under a SEPARATE data home + config
# home + control socket so it forms its own single-instance group and never touches a
# real user instance running on the default home. Cleanup kills ONLY this harness's
# own app (by pidfile) and its own wavesrv (by the test descriptor's pid) — NEVER a
# broad `pkill WaveApp`/`pkill wavesrv` that would also kill the user's app.
#
# Usage:
#   scripts/drive.sh launch        # (re)launch into the test home, wait for the
#                                   # driver socket, print its path on stdout
#   scripts/drive.sh kill          # stop only this harness's app + wavesrv
#   scripts/drive.sh wipe          # kill + delete the test home (fresh next launch)
#
# Env knobs: RESET=1 (wipe state on launch), NEWTAB=0 (no debug newtab),
#   WAVE_TEST_HOME / WAVE_TEST_CFG / WAVE_TEST_SOCK to relocate.
set -u

NATIVE="$(cd "$(dirname "$0")/.." && pwd)"
TESTHOME="${WAVE_TEST_HOME:-/tmp/wave-native-test/data}"
TESTCFG="${WAVE_TEST_CFG:-/tmp/wave-native-test/config}"
SOCK="${WAVE_TEST_SOCK:-/tmp/wave-native-test/drive.sock}"
PIDFILE="$TESTHOME/.driveapp.pid"
DESC="$TESTHOME/wavesrv-running.json"
BIN="$NATIVE/.build/arm64-apple-macosx/debug/WaveApp"

kill_own() {
    [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
    rm -f "$PIDFILE"
    # The test wavesrv is detached (survives the app); kill it by its recorded pid.
    if [ -f "$DESC" ]; then
        local p
        p=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['pid'])" "$DESC" 2>/dev/null)
        [ -n "${p:-}" ] && kill "$p" 2>/dev/null
    fi
}

case "${1:-launch}" in
    kill) kill_own; exit 0 ;;
    wipe) kill_own; sleep 1; rm -rf "$TESTHOME" "$TESTCFG" "$SOCK"; exit 0 ;;
    launch) : ;;
    *) echo "usage: drive.sh {launch|kill|wipe}" >&2; exit 2 ;;
esac

kill_own
sleep 1
[ "${RESET:-0}" = "1" ] && rm -rf "$TESTHOME" "$TESTCFG"
mkdir -p "$TESTHOME" "$TESTCFG" "$(dirname "$SOCK")"
rm -f "$SOCK"

WAVE_NATIVE_WAVESRV="$NATIVE/bin/wavesrv.arm64" \
WAVE_NATIVE_FONTS="$NATIVE/Fonts" \
WAVETERM_DATA_HOME="$TESTHOME" \
WAVETERM_CONFIG_HOME="$TESTCFG" \
WAVE_NATIVE_VERSION="drive-test" \
WAVE_NATIVE_ICON="$NATIVE/Resources/AppIcon.icns" \
WAVE_NATIVE_DEBUG_NEWTAB="${NEWTAB:-1}" \
WAVE_NATIVE_TEST_SOCK="$SOCK" \
"$BIN" >"$TESTHOME/app.log" 2>&1 &
echo $! >"$PIDFILE"

for _ in $(seq 1 60); do [ -S "$SOCK" ] && break; sleep 0.5; done
[ -S "$SOCK" ] || { echo "drive.sh: socket never appeared (see $TESTHOME/app.log)" >&2; exit 1; }
echo "$SOCK"
