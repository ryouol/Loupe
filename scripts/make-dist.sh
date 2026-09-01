#!/usr/bin/env bash
# Produces one of three deliberately distinct artifacts:
#   *-unsigned.dmg             local/CI smoke only
#   *-signed-unnotarized.dmg   owner validation only
#   Loupe-x.y.z.dmg            signed, notarized, stapled release candidate
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml | head -1)
CODE_VERSION=$(sed -n 's/.*let version = "\(.*\)".*/\1/p' Sources/LoupeCore/Loupe.swift | head -1)
if [[ -z "$VERSION" || "$VERSION" != "$CODE_VERSION" ]]; then
    echo "version mismatch: project.yml=$VERSION vs Loupe.swift=$CODE_VERSION" >&2
    exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)*$ ]]; then
    echo "version is not a safe semantic-version artifact component: $VERSION" >&2
    exit 1
fi

IDENTITY="${LOUPE_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${LOUPE_NOTARY_PROFILE:-}"
if [[ -n "$NOTARY_PROFILE" && -z "$IDENTITY" ]]; then
    echo "notarization requires LOUPE_SIGN_IDENTITY" >&2
    exit 1
fi

if [[ -n "$IDENTITY" ]]; then
    # A signed artifact can install privileged code, so an environment flag
    # must never bypass its full Xcode/XCTest/security gate.
    bash scripts/verify-release.sh
elif [[ "${LOUPE_RELEASE_TESTS_PASSED:-0}" != "1" ]]; then
    LOUPE_ALLOW_TOOLCHAIN_LIMITED_VERIFY="${LOUPE_ALLOW_TOOLCHAIN_LIMITED_VERIFY:-0}" \
        bash scripts/verify-release.sh
fi

if [[ -z "$IDENTITY" ]]; then
    ARTIFACT_NAME="Loupe-${VERSION}-unsigned"
elif [[ -z "$NOTARY_PROFILE" ]]; then
    ARTIFACT_NAME="Loupe-${VERSION}-signed-unnotarized"
else
    ARTIFACT_NAME="Loupe-${VERSION}"
fi

DMG="dist/${ARTIFACT_NAME}.dmg"
STAGING="dist/package-staging"
APP="DerivedData/Build/Products/Release/Loupe.app"
NOTARY_ZIP="dist/.Loupe-${VERSION}-notary.zip"

cleanup() {
    rm -rf "$STAGING"
    rm -f "$NOTARY_ZIP"
}
trap cleanup EXIT

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

[[ -d "$APP" ]] || { echo "build produced no app at $APP" >&2; exit 1; }
file "$APP/Contents/MacOS/Loupe" | grep -q 'arm64' || {
    echo "app executable is not arm64" >&2
    exit 1
}
file "$APP/Contents/MacOS/loupedaemon" | grep -q 'arm64' || {
    echo "helper executable is not arm64" >&2
    exit 1
}
for resource in \
    Samples/demo-session.ndjson \
    Samples/demo-session.system.ndjson \
    Legal/Privacy.txt \
    Legal/Terms.txt \
    Legal/ThirdPartyNotices.txt; do
    flattened_resource="$APP/Contents/Resources/$(basename "$resource")"
    grouped_resource="$APP/Contents/Resources/$resource"
    if [[ ! -f "$flattened_resource" && ! -f "$grouped_resource" ]]; then
        echo "required bundled resource is missing: $resource" >&2
        exit 1
    fi
done

if [[ -n "$IDENTITY" ]]; then
    codesign --verify --deep --strict --verbose=2 "$APP"
    codesign --verify --strict --verbose=2 "$APP/Contents/MacOS/loupedaemon"

    if [[ -n "$NOTARY_PROFILE" ]]; then
        APP_SIGNATURE=$(codesign -dv --verbose=4 "$APP" 2>&1)
        HELPER_SIGNATURE=$(codesign -dv --verbose=4 "$APP/Contents/MacOS/loupedaemon" 2>&1)
        APP_TEAM=$(printf '%s\n' "$APP_SIGNATURE" | sed -n 's/^TeamIdentifier=//p' | head -1)
        HELPER_TEAM=$(printf '%s\n' "$HELPER_SIGNATURE" | sed -n 's/^TeamIdentifier=//p' | head -1)

        if [[ -z "$APP_TEAM" || "$APP_TEAM" == "not set" || "$APP_TEAM" != "$HELPER_TEAM" ]]; then
            echo "final app/helper signatures must have the same non-empty TeamIdentifier" >&2
            exit 1
        fi
        printf '%s\n' "$APP_SIGNATURE" | grep -q '^Authority=Developer ID Application:' || {
            echo "final app signature is not a Developer ID Application signature" >&2
            exit 1
        }
        printf '%s\n' "$HELPER_SIGNATURE" | grep -q '^Authority=Developer ID Application:' || {
            echo "final helper signature is not a Developer ID Application signature" >&2
            exit 1
        }

        # Notarize and staple the app before copying it into the disk image.
        # A ticket stapled only to the outer DMG is insufficient evidence
        # that the installed app works offline after the image is detached.
        mkdir -p dist
        rm -f "$NOTARY_ZIP"
        ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
        xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
        xcrun stapler validate "$APP"
        codesign --verify --deep --strict --verbose=2 "$APP"
        spctl --assess --type execute --verbose=2 "$APP"
    fi
else
    echo "UNSIGNED SMOKE ARTIFACT: helper installation is disabled and Gatekeeper will reject it." >&2
fi

mkdir -p dist
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Loupe.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG" "$DMG.sha256"
hdiutil create -volname "Loupe" -srcfolder "$STAGING" -ov -format UDZO -quiet "$DMG"
hdiutil verify "$DMG"

if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

shasum -a 256 "$DMG" > "$DMG.sha256"
if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "Release candidate produced: $DMG"
else
    echo "Non-release validation artifact produced: $DMG"
fi
