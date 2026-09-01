#!/usr/bin/env bash
# Copyright 2026, Command Line Inc.
# SPDX-License-Identifier: Apache-2.0
#
# bundle-app.sh — wrap the SwiftPM executable in a real macOS .app bundle
# (docs/INTEGRATION.md §1.4): native traffic-light window, bundled wavesrv +
# fonts, Info.plist, ad-hoc code signature. Output: dist/WaveNative.app.
#
#   ./scripts/bundle-app.sh                 # release build, then bundle
#   ./scripts/bundle-app.sh debug           # debug build, then bundle
#   ./scripts/bundle-app.sh debug --no-build # bundle the existing debug binary
#
# The bundle identity + data home are overridable so a side-by-side *test* build
# can be produced (differently named .app, isolated settings dir — see the `test*`
# targets in the Makefile). When WAVE_DATA_HOME is set it is baked into the app's
# Info.plist LSEnvironment so even a double-click launch (not just a shell run,
# per docs/LIVE-UPGRADE-TESTING.md) uses the isolated home:
#   WAVE_APP_NAME          bundle basename         (default: WaveNative)
#   WAVE_APP_DISPLAY_NAME  CFBundleName/DisplayName (default: Wave Native)
#   WAVE_APP_BUNDLE_ID     CFBundleIdentifier       (default: dev.commandline.wave-native)
#   WAVE_DATA_HOME         WAVETERM_DATA_HOME baked into the bundle (default: unset)
#   WAVE_CONFIG_HOME       WAVETERM_CONFIG_HOME baked in (default: <WAVE_DATA_HOME>/config)
#
# libghostty-vt is linked statically, so nothing extra needs bundling for it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

CONFIG="release"
BUILD=1
for arg in "$@"; do
    case "$arg" in
        release|debug) CONFIG="$arg" ;;
        --no-build) BUILD=0 ;;
        *) echo "unknown arg: $arg" >&2; exit 1 ;;
    esac
done

FLAGS=(-Xcc -Ivendor/libghostty/include -Xlinker -Lvendor/libghostty/lib)
if [ "$BUILD" -eq 1 ]; then
    echo "==> building ($CONFIG)…"
    swift build -c "$CONFIG" "${FLAGS[@]}"
fi

BIN="$DIR/.build/$(uname -m)-apple-macosx/$CONFIG/WaveApp"
if [ ! -x "$BIN" ]; then
    echo "error: $BIN not found — build first (omit --no-build)." >&2
    exit 1
fi

APP_NAME="${WAVE_APP_NAME:-WaveNative}"
APP_DISPLAY_NAME="${WAVE_APP_DISPLAY_NAME:-Wave Native}"
APP_BUNDLE_ID="${WAVE_APP_BUNDLE_ID:-dev.commandline.wave-native}"
DATA_HOME_OVERRIDE="${WAVE_DATA_HOME:-}"
CONFIG_HOME_OVERRIDE="${WAVE_CONFIG_HOME:-}"
if [ -n "$DATA_HOME_OVERRIDE" ] && [ -z "$CONFIG_HOME_OVERRIDE" ]; then
    CONFIG_HOME_OVERRIDE="$DATA_HOME_OVERRIDE/config"
fi

APP="$DIR/dist/$APP_NAME.app"
RES="$APP/Contents/Resources"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES/Fonts"

cp "$BIN" "$APP/Contents/MacOS/WaveApp"
# main.swift resolves Bundle.main.url(forResource:"wavesrv") — bundle it as exactly
# "wavesrv" (no extension).
cp "$DIR/bin/wavesrv.arm64" "$RES/wavesrv"
chmod +x "$RES/wavesrv"
# Durable shells need the wsh "jobmanager" daemon (darwin.arm64), and remote SSH
# connections need the other-platform wsh binaries wavesrv installs onto the
# remote host. wavesrv resolves them all at
# $WAVETERM_APP_PATH/bin/wsh-<WaveVersion>-<os>.<arch> (main.swift sets
# WAVETERM_APP_PATH to this Resources dir for the bundle). Copy every versioned
# wsh in bin/, preserving names so they match the WaveVersion the bundled wavesrv
# was built with (dev builds ship 0.0.0; a release ships the tagged version).
if ls "$DIR"/bin/wsh-* >/dev/null 2>&1; then
    mkdir -p "$RES/bin"
    for wsh_src in "$DIR"/bin/wsh-*; do
        cp "$wsh_src" "$RES/bin/$(basename "$wsh_src")"
        chmod +x "$RES/bin/$(basename "$wsh_src")"
    done
    if ! ls "$DIR"/bin/wsh-*-darwin.arm64 >/dev/null 2>&1; then
        echo "warning: bin/wsh-*-darwin.arm64 missing — durable local shells will be unavailable (run scripts/build-wsh.sh)" >&2
    fi
else
    echo "warning: bin/wsh-* not found — durable shells and remote wsh will be unavailable (run scripts/build-wsh.sh)" >&2
fi
cp "$DIR/Fonts/"*.ttf "$DIR/Fonts/"*.otf "$RES/Fonts/" 2>/dev/null || true
# App icon (same as Electron Wave — vendored from build/icon.icns into Resources/).
cp "$DIR/Resources/AppIcon.icns" "$RES/AppIcon.icns" 2>/dev/null \
    || echo "warning: Resources/AppIcon.icns not found — app will use the default icon" >&2

# Version the package by git commit: CFBundleVersion = <short-sha>[-dirty], which the
# About panel shows as "Version <CFBundleShortVersionString> (<CFBundleVersion>)".
COMMIT="$(git -C "$DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
git -C "$DIR" diff --quiet 2>/dev/null || COMMIT="${COMMIT}-dirty"
SHORTVER="${WAVE_SHORT_VERSION:-0.1.0}"

# Bake the isolated data/config home into the bundle so double-click launches (which
# don't inherit a shell WAVETERM_DATA_HOME) still land in the test home. main.swift
# reads these env vars; LSEnvironment is applied by LaunchServices on `open`.
LSENV=""
if [ -n "$DATA_HOME_OVERRIDE" ]; then
    LSENV="
    <key>LSEnvironment</key>
    <dict>
        <key>WAVETERM_DATA_HOME</key><string>${DATA_HOME_OVERRIDE}</string>
        <key>WAVETERM_CONFIG_HOME</key><string>${CONFIG_HOME_OVERRIDE}</string>
    </dict>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>WaveApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>${APP_BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${APP_DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_DISPLAY_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${SHORTVER}</string>
    <key>CFBundleVersion</key><string>${COMMIT}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>${APP_BUNDLE_ID}.deeplink</string>
            <key>CFBundleURLSchemes</key><array><string>wave-native</string></array>
        </dict>
    </array>${LSENV}
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS lets it launch locally (no Developer ID / notarization).
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warn: codesign failed (app may still run locally)"

echo "==> done: $APP"
echo "    open it:   open '$APP'"
if [ -n "$DATA_HOME_OVERRIDE" ]; then
    echo "    data home: $DATA_HOME_OVERRIDE (isolated test home, baked into LSEnvironment)"
else
    echo "    (isolated data home ~/Library/Application Support/waveterm-native; first"
    echo "     real tab is empty until you click +)"
fi
