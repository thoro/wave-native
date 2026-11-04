#!/usr/bin/env bash
# Copyright 2026, Command Line Inc.
# SPDX-License-Identifier: Apache-2.0
#
# fetch-wavesrv.sh — download the prebuilt wavesrv backend + wsh binaries from a
# thoro/wavesrv GitHub release into bin/, where bundle-app.sh picks them up. This is
# how a standalone checkout (and the release CI) gets them; inside a wavesrv checkout
# build-deps.sh / build-wsh.sh build them from source instead.
#
#   ./scripts/fetch-wavesrv.sh          # the release pinned in WAVESRV_VERSION
#   ./scripts/fetch-wavesrv.sh 0.0.2    # a specific release
#
# Replaces every bin/wsh-*: bundle-app.sh ships all of them, but wavesrv only resolves
# the ones stamped with its own version, so a leftover set from another build is dead
# weight at best.
set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(tr -d '[:space:]' < "$NATIVE_DIR/WAVESRV_VERSION")}"
VERSION="${VERSION#v}"
BASE_URL="https://github.com/thoro/wavesrv/releases/download/v$VERSION"

# wavebase.SupportedWshBinaries, in the release's file-name spelling (amd64 -> x64).
WSH_TARGETS=(
  darwin.arm64
  darwin.x64
  linux.arm64
  linux.x64
  windows.arm64.exe
  windows.x64.exe
)

# Download everything first so a failed fetch leaves the current bin/ untouched.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fetch() {
  echo "==> fetching $1"
  curl -fsSL --retry 3 -o "$tmp/$1" "$BASE_URL/$1"
}
fetch wavesrv.arm64
for target in "${WSH_TARGETS[@]}"; do
  fetch "wsh-$VERSION-$target"
done

mkdir -p "$NATIVE_DIR/bin"
rm -f "$NATIVE_DIR"/bin/wsh-*
chmod +x "$tmp"/*
mv "$tmp"/* "$NATIVE_DIR/bin/"
echo "==> wavesrv $VERSION -> bin/"
