#!/usr/bin/env bash
# Copyright 2026, Command Line Inc.
# SPDX-License-Identifier: Apache-2.0
#
# run.sh — build (if needed) and launch the native Wave client for manual testing.
#
# Uses an ISOLATED data home (~/Library/Application Support/waveterm-native) so it
# never touches a real Electron Wave install. A first-launch starter tab is empty
# (the backend seeds the starter layout only after Electron's onboarding), so we
# open a fresh tab automatically via WAVE_NATIVE_DEBUG_NEWTAB so you land on a live
# terminal — you can also just click the "+" to make more.
#
# Quit with Cmd+Q. Reset state with:  rm -rf ~/Library/Application\ Support/waveterm-native
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

FLAGS=(-Xcc -Ivendor/libghostty/include -Xlinker -Lvendor/libghostty/lib)

if [ "${1:-}" != "--no-build" ]; then
    echo "==> building (pass --no-build to skip)…"
    swift build "${FLAGS[@]}"
fi

BIN="$DIR/.build/arm64-apple-macosx/debug/WaveApp"
if [ ! -x "$BIN" ]; then
    echo "error: $BIN not found — run 'swift build ${FLAGS[*]}' first." >&2
    exit 1
fi
if [ ! -x "$DIR/bin/wavesrv.arm64" ]; then
    echo "error: bin/wavesrv.arm64 not found — run scripts/build-deps.sh first." >&2
    exit 1
fi

echo "==> launching WaveApp (isolated home, opens a terminal tab)…"
exec env \
    WAVE_NATIVE_WAVESRV="$DIR/bin/wavesrv.arm64" \
    WAVE_NATIVE_FONTS="$DIR/Fonts" \
    WAVE_NATIVE_ICON="$DIR/Resources/AppIcon.icns" \
    WAVE_NATIVE_DEBUG_NEWTAB=1 \
    "$BIN"
