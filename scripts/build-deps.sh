#!/usr/bin/env bash
# Copyright 2026, Command Line Inc.
# SPDX-License-Identifier: Apache-2.0
#
# build-deps.sh — fetch + build the external dependencies the native macOS Wave
# client needs (docs/INTEGRATION.md §1). Idempotent; safe to re-run.
#
#   1. zig 0.15.2          — Ghostty's required toolchain (Homebrew bottle, the
#                            macOS-26/Tahoe-patched build; the upstream ziglang.org
#                            0.15.2 binary CANNOT link against the macOS 26 SDK).
#   2. libghostty-vt       — Ghostty's headless terminal core (escape parsing, grid,
#                            key encoding). Built static + dylib + headers and
#                            vendored under vendor/libghostty/.
#   3. wavesrv             — the Go backend the client drives (-> bin/wavesrv.arm64).
#   4. Inter + Hack fonts  — required for the STYLE snapshot baselines (-> Fonts/).
#
# Run from anywhere; paths are resolved relative to this script.
set -euo pipefail

NATIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$NATIVE_DIR/.." && pwd)"     # the Go wavesrv repo
VENDOR="$NATIVE_DIR/vendor"
GHOSTTY_DIR="$VENDOR/ghostty"
GHOSTTY_VERSION_TAG="${GHOSTTY_TAG:-main}"

echo "==> native dir: $NATIVE_DIR"
echo "==> wavesrv repo: $REPO_ROOT"

# --- 1. zig 0.15.2 (Homebrew, macOS-26 patched) ------------------------------
ZIG="$(/usr/bin/which zig@0.15.2 2>/dev/null || true)"
if [ -x /opt/homebrew/opt/zig@0.15.2/bin/zig ]; then
  ZIG=/opt/homebrew/opt/zig@0.15.2/bin/zig
fi
if [ -z "${ZIG:-}" ] || ! "$ZIG" version 2>/dev/null | grep -q '^0\.15\.2$'; then
  echo "==> installing zig 0.15.2 via Homebrew (extracted from homebrew/core)"
  brew tap --force homebrew/core
  brew tap-new local/zigpin 2>/dev/null || true
  brew extract --version=0.15.2 zig local/zigpin 2>/dev/null || true
  brew install local/zigpin/zig@0.15.2
  ZIG=/opt/homebrew/opt/zig@0.15.2/bin/zig
fi
echo "==> zig: $ZIG ($("$ZIG" version))"

# --- 2. libghostty-vt --------------------------------------------------------
if [ ! -d "$GHOSTTY_DIR" ]; then
  echo "==> cloning ghostty ($GHOSTTY_VERSION_TAG)"
  git clone --depth 1 --branch "$GHOSTTY_VERSION_TAG" https://github.com/ghostty-org/ghostty "$GHOSTTY_DIR"
fi
echo "==> building libghostty-vt (static + dylib + headers)"
( cd "$GHOSTTY_DIR" && rm -rf zig-out && \
  "$ZIG" build -Doptimize=ReleaseFast -Demit-lib-vt=true --prefix zig-out )

echo "==> vendoring libghostty artifacts -> $VENDOR/libghostty"
mkdir -p "$VENDOR/libghostty/lib" "$VENDOR/libghostty/include"
cp "$GHOSTTY_DIR"/zig-out/lib/libghostty-vt.a "$VENDOR/libghostty/lib/"
cp "$GHOSTTY_DIR"/zig-out/lib/libghostty-vt.*.dylib "$VENDOR/libghostty/lib/"
rm -rf "$VENDOR/libghostty/include/ghostty"
cp -R "$GHOSTTY_DIR"/zig-out/include/ghostty "$VENDOR/libghostty/include/"
git -C "$GHOSTTY_DIR" rev-parse HEAD > "$VENDOR/libghostty/GHOSTTY_REV.txt"

# --- 3. wavesrv --------------------------------------------------------------
echo "==> building wavesrv (CGO, sqlite) -> $NATIVE_DIR/bin/wavesrv.arm64"
( cd "$REPO_ROOT" && CGO_ENABLED=1 GOARCH=arm64 \
  go build -tags "osusergo,sqlite_omit_load_extension" \
  -o "$NATIVE_DIR/bin/wavesrv.arm64" cmd/server/main-server.go )

# --- 3b. wsh -----------------------------------------------------------------
# Durable shells exec a detached "wsh jobmanager" daemon that holds the local PTY
# so it survives a wavesrv restart, and wavesrv installs wsh onto remote SSH
# hosts. build-wsh.sh cross-compiles every supported os/arch into bin/
# (wavesrv resolves them under $WAVETERM_APP_PATH/bin; cwd-relative in dev runs).
"$NATIVE_DIR/scripts/build-wsh.sh"

# --- 4. fonts ----------------------------------------------------------------
FONTS="$NATIVE_DIR/Fonts"
if ! ls "$FONTS"/Hack-Regular.ttf >/dev/null 2>&1; then
  echo "==> downloading Hack font"
  mkdir -p "$FONTS" && tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/hack.zip" "https://github.com/source-foundry/Hack/releases/download/v3.003/Hack-v3.003-ttf.zip"
  unzip -o -j "$tmp/hack.zip" "*.ttf" -d "$FONTS" >/dev/null
  rm -rf "$tmp"
fi
if ! ls "$FONTS"/Inter-Regular.otf >/dev/null 2>&1; then
  echo "==> downloading Inter font"
  mkdir -p "$FONTS" && tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/inter.zip" "https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip"
  unzip -o -j "$tmp/inter.zip" "*/Inter-Regular.otf" "*/Inter-Bold.otf" "*/Inter-Medium.otf" "*/Inter-SemiBold.otf" -d "$FONTS" >/dev/null
  rm -rf "$tmp"
fi

echo
echo "==> DONE. Artifacts:"
echo "    zig            : $ZIG"
echo "    libghostty-vt  : $VENDOR/libghostty/{lib,include}"
echo "    wavesrv        : $NATIVE_DIR/bin/wavesrv.arm64"
echo "    fonts          : $FONTS"
echo
echo "Build the Swift package against libghostty-vt with:"
echo "    swift build \\"
echo "      -Xcc     -I$VENDOR/libghostty/include \\"
echo "      -Xlinker -L$VENDOR/libghostty/lib \\"
echo "      -Xlinker -lghostty-vt"
echo "Run the app with the bundled backend:"
echo "    WAVE_NATIVE_WAVESRV=$NATIVE_DIR/bin/wavesrv.arm64 swift run WaveApp <same -Xcc/-Xlinker flags>"
