#!/usr/bin/env bash
# Copyright 2026, Command Line Inc.
# SPDX-License-Identifier: Apache-2.0
#
# build-wsh.sh — cross-compile the wsh binary for every platform wavesrv can
# install it to (wavebase.SupportedWshBinaries). The darwin.arm64 build backs
# local durable shells; the others are what conncontroller copies to REMOTE
# hosts over SSH (GetLocalWshBinaryPath resolves
# $WAVETERM_APP_PATH/bin/wsh-<version>-<os>.<x64|arm64>[.exe]).
#
# Run from anywhere; paths resolve relative to this script. WAVE_VERSION
# overrides the version stamp (default 0.0.0, matching the dev wavesrv).
set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$NATIVE_DIR/.." && pwd)"
VERSION="${WAVE_VERSION:-0.0.0}"
BUILD_TIME="$(date +'%Y%m%d%H%M')"

PLATFORMS=(
  darwin/arm64
  darwin/amd64
  linux/arm64
  linux/amd64
  windows/arm64
  windows/amd64
)

mkdir -p "$NATIVE_DIR/bin"
for platform in "${PLATFORMS[@]}"; do
  goos="${platform%/*}"
  goarch="${platform#*/}"
  # File names use the frontend arch spelling (amd64 -> x64), same as
  # shellutil.GetLocalWshBinaryPath and the Electron Taskfile.
  archname="$goarch"
  [ "$goarch" = "amd64" ] && archname="x64"
  ext=""
  [ "$goos" = "windows" ] && ext=".exe"
  out="$NATIVE_DIR/bin/wsh-$VERSION-$goos.$archname$ext"
  echo "==> building wsh $goos/$goarch -> ${out#"$NATIVE_DIR"/}"
  ( cd "$REPO_ROOT" && CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
    go build -ldflags="-s -w -X main.BuildTime=$BUILD_TIME -X main.WaveVersion=$VERSION" \
    -o "$out" ./cmd/wsh )
done
