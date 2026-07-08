#!/usr/bin/env bash
# Sign (Developer ID + hardened runtime) and notarize dist/WaveNative.app for
# distribution to other Macs. Run this AFTER scripts/bundle-app.sh — codesigning must
# be the LAST step (re-bundling re-signs ad-hoc and discards this signature).
#
# One-time prereqs:
#   - a "Developer ID Application" cert in the login keychain
#       (security find-identity -v -p codesigning  →  should list it)
#   - a stored notary profile:
#       xcrun notarytool store-credentials "wave-notary" \
#         --apple-id "<you@appleid>" --team-id 22GZ9VYGB5 \
#         --password <app-specific-password>     # appleid.apple.com → App-Specific Passwords
#
# Overrides: WAVE_SIGN_IDENTITY, WAVE_NOTARY_PROFILE. Pass --sign-only to skip notarize.
# CI auth (no stored profile): set WAVE_NOTARY_KEY (path to an App Store Connect .p8),
# WAVE_NOTARY_KEY_ID, and WAVE_NOTARY_ISSUER to notarize with an API key instead.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$DIR/dist/WaveNative.app"
IDENTITY="${WAVE_SIGN_IDENTITY:-Developer ID Application: Thomas Rosenstein (22GZ9VYGB5)}"
PROFILE="${WAVE_NOTARY_PROFILE:-wave-notary}"
SIGN_ONLY=0
[ "${1:-}" = "--sign-only" ] && SIGN_ONLY=1

[ -d "$APP" ] || { echo "no $APP — run scripts/bundle-app.sh first" >&2; exit 1; }

# Sign nested code BEFORE the outer app, all with the hardened runtime + a secure
# timestamp (both required for notarization). Notarization rejects ANY unsigned nested
# Mach-O, so sign every bundled helper: wavesrv AND the durable-shell wsh job-manager
# under Resources/bin/.
echo "==> signing nested wavesrv"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Resources/wavesrv"

if [ -d "$APP/Contents/Resources/bin" ]; then
    echo "==> signing bundled helper binaries (Resources/bin/*)"
    find "$APP/Contents/Resources/bin" -type f -perm -u+x -print0 \
        | xargs -0 -I{} codesign --force --options runtime --timestamp --sign "$IDENTITY" "{}"
fi

echo "==> signing app"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"

echo "==> verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

if [ "$SIGN_ONLY" = "1" ]; then
    echo "==> --sign-only: skipping notarization"
    exit 0
fi

echo "==> notarizing (zip → submit --wait → staple)"
ZIP="$DIR/dist/WaveNative.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
# Auth: an App Store Connect API key (WAVE_NOTARY_KEY=.p8 + key-id + issuer) when set —
# this is what CI uses, since a stored keychain profile doesn't exist on a runner —
# otherwise the local stored notary profile.
if [ -n "${WAVE_NOTARY_KEY:-}" ]; then
    xcrun notarytool submit "$ZIP" \
        --key "$WAVE_NOTARY_KEY" \
        --key-id "$WAVE_NOTARY_KEY_ID" \
        --issuer "$WAVE_NOTARY_ISSUER" \
        --wait
else
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
fi
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "==> done — Gatekeeper assessment:"
spctl -a -vvv --type exec "$APP" || true
echo "Ship: ditto -c -k --keepParent '$APP' WaveNative.zip   (or a .dmg)"
