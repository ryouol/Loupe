#!/usr/bin/env bash
# Builds a distributable Loupe DMG for direct download (no App Store).
#
#   make dist                             unsigned dev build (local testing only)
#   LOUPE_SIGN_IDENTITY="Developer ID Application: …" make dist
#                                         signed, ready to notarize
#   LOUPE_NOTARY_PROFILE=loupe-notary … make dist
#                                         signed + notarized + stapled
#
# See docs/distribution.md for one-time credential setup.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)
CODE_VERSION=$(sed -n 's/.*let version = "\(.*\)".*/\1/p' Sources/LoupeCore/Loupe.swift | head -1)
if [[ "$VERSION" != "$CODE_VERSION" ]]; then
    echo "version mismatch: project.yml=$VERSION vs Loupe.swift=$CODE_VERSION" >&2
    echo "bump both before cutting a release." >&2
    exit 1
fi
DMG="dist/Loupe-${VERSION}.dmg"
IDENTITY="${LOUPE_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${LOUPE_NOTARY_PROFILE:-}"

xcodegen generate

SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO)
if [[ -n "$IDENTITY" ]]; then
    SIGN_ARGS=(
        CODE_SIGNING_ALLOWED=YES
        CODE_SIGN_STYLE=Manual
        "CODE_SIGN_IDENTITY=${IDENTITY}"
    )
fi

xcodebuild build \
    -scheme Loupe -configuration Release -destination 'platform=macOS' \
    -derivedDataPath DerivedData -quiet "${SIGN_ARGS[@]}"

APP="DerivedData/Build/Products/Release/Loupe.app"
[[ -d "$APP" ]] || { echo "build produced no app at $APP" >&2; exit 1; }

if [[ -n "$IDENTITY" ]]; then
    codesign --verify --deep --strict "$APP"
    echo "Signature verified."
else
    echo "WARNING: unsigned build — fine for local testing, but Gatekeeper" >&2
    echo "will refuse it on other machines. Set LOUPE_SIGN_IDENTITY to ship." >&2
fi

STAGING="dist/staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Loupe" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGING"

if [[ -n "$NOTARY_PROFILE" ]]; then
    [[ -n "$IDENTITY" ]] || { echo "notarization requires a signed build" >&2; exit 1; }
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "Notarized and stapled."
fi

echo "Ready: $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
