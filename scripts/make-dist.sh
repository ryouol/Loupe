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
CHECKSUM="${DMG}.sha256"
APP="DerivedData/Build/Products/Release/Loupe.app"

# All mutable packaging work lives under a unique, hidden directory on the
# same filesystem as the published artifact. That makes the final rename
# atomic and, more importantly, leaves an already-validated release untouched
# when any build, signing, notarization, stapling, or assessment step fails.
mkdir -p dist
CANDIDATE_ROOT=$(mktemp -d "dist/.${ARTIFACT_NAME}.candidate.XXXXXX")
CANDIDATE_DMG="${CANDIDATE_ROOT}/${ARTIFACT_NAME}.dmg"
CANDIDATE_CHECKSUM="${CANDIDATE_ROOT}/${ARTIFACT_NAME}.dmg.sha256"
STAGING="${CANDIDATE_ROOT}/package-staging"
NOTARY_ZIP="${CANDIDATE_ROOT}/Loupe-${VERSION}-notary.zip"
PRIOR_DMG="${CANDIDATE_ROOT}/prior.dmg"
PRIOR_CHECKSUM="${CANDIDATE_ROOT}/prior.dmg.sha256"
HAD_PRIOR_DMG=0
HAD_PRIOR_CHECKSUM=0
PUBLISH_STARTED=0
PUBLISH_COMPLETE=0

cleanup() {
    status=$?
    if [[ "$status" -ne 0 && "$PUBLISH_STARTED" -eq 1 && "$PUBLISH_COMPLETE" -eq 0 ]]; then
        if [[ "$HAD_PRIOR_DMG" -eq 1 ]]; then
            mv -f "$PRIOR_DMG" "$DMG"
        else
            rm -f "$DMG"
        fi
        if [[ "$HAD_PRIOR_CHECKSUM" -eq 1 ]]; then
            mv -f "$PRIOR_CHECKSUM" "$CHECKSUM"
        fi
    fi
    rm -rf "$CANDIDATE_ROOT"
    trap - EXIT
    exit "$status"
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

mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Loupe.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Loupe" -srcfolder "$STAGING" -ov -format UDZO -quiet "$CANDIDATE_DMG"
hdiutil verify "$CANDIDATE_DMG"

if [[ -n "$IDENTITY" ]]; then
    codesign --force --timestamp --sign "$IDENTITY" "$CANDIDATE_DMG"
    codesign --verify --strict --verbose=2 "$CANDIDATE_DMG"
    hdiutil verify "$CANDIDATE_DMG"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$CANDIDATE_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$CANDIDATE_DMG"
    xcrun stapler validate "$CANDIDATE_DMG"
    # Stapling mutates the image, so validate the final candidate bytes again.
    codesign --verify --strict --verbose=2 "$CANDIDATE_DMG"
    hdiutil verify "$CANDIDATE_DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$CANDIDATE_DMG"
fi

# Publishing is the sole operation that replaces an existing valid image.
# mv(1) is atomic here because the candidate and destination share `dist/`.
if [[ -f "$DMG" ]]; then
    cp -p "$DMG" "$PRIOR_DMG"
    HAD_PRIOR_DMG=1
fi
if [[ -f "$CHECKSUM" ]]; then
    cp -p "$CHECKSUM" "$PRIOR_CHECKSUM"
    HAD_PRIOR_CHECKSUM=1
fi
PUBLISH_STARTED=1
mv -f "$CANDIDATE_DMG" "$DMG"
shasum -a 256 "$DMG" > "$CANDIDATE_CHECKSUM"
mv -f "$CANDIDATE_CHECKSUM" "$CHECKSUM"
PUBLISH_COMPLETE=1
if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "Release candidate produced: $DMG"
else
    echo "Non-release validation artifact produced: $DMG"
fi
