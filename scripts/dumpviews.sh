#!/usr/bin/env bash
# Dump the RUNNING wave-native app's live view hierarchy (every window) via the
# always-on control socket — no relaunch, no test driver. Optionally include the
# hit-test chain at a content point (top-left origin, like a window screenshot).
#
#   scripts/dumpviews.sh                      # -> <dataHome>/wave-native-viewdump.txt
#   scripts/dumpviews.sh /tmp/dump.txt
#   scripts/dumpviews.sh /tmp/dump.txt 640 400   # + hit chain at (640,400) in the key window
#
# DATA_HOME overrides the default production data directory (e.g. a drive.sh test
# instance: DATA_HOME=/tmp/wave-native-test/data).
set -euo pipefail
data_home="${DATA_HOME:-$HOME/Library/Application Support/waveterm-native}"
sock="$data_home/wave-native.sock"
[ -S "$sock" ] || { echo "no control socket at $sock (is wave-native running?)" >&2; exit 1; }
reply=$(printf 'DUMPVIEWS %s\n' "$*" | nc -U "$sock" | grep -v '^VERSION ')
echo "$reply"
case "$reply" in
    DUMP\ *) exit 0 ;;
    *) exit 1 ;;
esac
