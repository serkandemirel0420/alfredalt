#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AlfredAlternative"
APP_BUNDLE="$ROOT_DIR/.build/$APP_NAME.app"
DMG_DIR="$ROOT_DIR/.build"
REPO_SLUG="serkandemirel0420/alfredalt"

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        echo "error: '$cmd' is required but not installed"
        exit 1
    fi
}

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "error: required environment variable '$name' is not set"
        exit 1
    fi
}

find_default_signing_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application:/ { print $2; exit }'
}

VERSION=$(grep '^version' "$ROOT_DIR/Cargo.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')
if [[ -z "$VERSION" ]]; then
    echo "error: could not read version from Cargo.toml"
    exit 1
fi

TAG="v$VERSION"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="$DMG_DIR/$DMG_NAME"
MACOS_SIGNING_IDENTITY="${MACOS_SIGNING_IDENTITY:-${APPLE_SIGNING_IDENTITY:-}}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-${APPLE_NOTARY_PROFILE:-}}"
NOTES_FILE=""
STAGING_DIR=""

cleanup() {
    if [[ -n "$NOTES_FILE" && -f "$NOTES_FILE" ]]; then
        rm -f "$NOTES_FILE"
    fi
    if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
        rm -rf "$STAGING_DIR"
    fi
}
trap cleanup EXIT

require_cmd make
require_cmd gh
require_cmd hdiutil
require_cmd codesign
require_cmd xcrun
require_cmd spctl
require_cmd security

if [[ -z "$MACOS_SIGNING_IDENTITY" ]]; then
    MACOS_SIGNING_IDENTITY="$(find_default_signing_identity)"
fi

USE_NOTARY_PROFILE=false
if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
    USE_NOTARY_PROFILE=true
fi

HAS_APPLE_CREDENTIALS=false
if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
    HAS_APPLE_CREDENTIALS=true
fi

CAN_NOTARIZE=false
if [[ "$USE_NOTARY_PROFILE" == true || "$HAS_APPLE_CREDENTIALS" == true ]]; then
    CAN_NOTARIZE=true
fi

SIGNED_RELEASE=false
if [[ -n "$MACOS_SIGNING_IDENTITY" && "$CAN_NOTARIZE" == true ]]; then
    SIGNED_RELEASE=true
fi

echo "==> Building $APP_NAME v$VERSION ..."
make -C "$ROOT_DIR" build-app

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "error: app bundle not found at $APP_BUNDLE"
    exit 1
fi

if ! gh auth status &>/dev/null; then
    echo "error: gh is not authenticated. Run: gh auth login"
    exit 1
fi

if [[ "$SIGNED_RELEASE" == true ]]; then
    echo "==> Signed/notarized mode enabled"
    echo "==> Signing app bundle with Developer ID ..."
    codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --sign "$MACOS_SIGNING_IDENTITY" \
        "$APP_BUNDLE"
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
else
    echo "==> Unsigned mode enabled (no Apple Developer signing/notarization credentials found)."
    if [[ -z "$MACOS_SIGNING_IDENTITY" ]]; then
        echo "    Reason: no Developer ID Application identity available."
    else
        echo "    Reason: notarization credentials missing."
    fi
    echo "    DMG will include 'Fix App.command' for users."
fi

echo "==> Creating DMG ..."
rm -f "$DMG_PATH"
STAGING_DIR=$(mktemp -d)
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

if [[ "$SIGNED_RELEASE" != true ]]; then
    cat <<'EOF' > "$STAGING_DIR/Fix App.command"
#!/bin/bash
set -e
APP_PATH="/Applications/AlfredAlternative.app"
if [ ! -d "$APP_PATH" ]; then
  echo "App not found at $APP_PATH"
  echo "Drag AlfredAlternative.app to Applications first, then run this again."
  read -p "Press Enter to close..."
  exit 1
fi
xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
echo "Done. You can now open AlfredAlternative."
read -p "Press Enter to close..."
EOF
    chmod +x "$STAGING_DIR/Fix App.command"
fi

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "==> DMG created: $DMG_PATH"
ls -lh "$DMG_PATH"

if [[ "$SIGNED_RELEASE" == true ]]; then
    echo "==> Signing DMG with Developer ID ..."
    codesign \
        --force \
        --timestamp \
        --sign "$MACOS_SIGNING_IDENTITY" \
        "$DMG_PATH"
    codesign --verify --verbose=2 "$DMG_PATH"

    echo "==> Submitting DMG for notarization (this can take several minutes) ..."
    if [[ "$USE_NOTARY_PROFILE" == true ]]; then
        xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile "$NOTARYTOOL_PROFILE" \
            --wait
    else
        xcrun notarytool submit "$DMG_PATH" \
            --apple-id "$APPLE_ID" \
            --password "$APPLE_APP_PASSWORD" \
            --team-id "$APPLE_TEAM_ID" \
            --wait
    fi

    echo "==> Stapling notarization ticket ..."
    xcrun stapler staple -v "$DMG_PATH"
    xcrun stapler validate -v "$DMG_PATH"

    echo "==> Running Gatekeeper assessment ..."
    spctl --assess --type open --verbose=4 "$DMG_PATH"
fi

echo ""
echo "==> Creating GitHub release $TAG ..."

EXISTING=$(gh release view "$TAG" --repo "$REPO_SLUG" --json tagName 2>/dev/null || true)
if [[ -n "$EXISTING" ]]; then
    echo "Release $TAG already exists. Deleting and recreating..."
    gh release delete "$TAG" --repo "$REPO_SLUG" --yes --cleanup-tag 2>/dev/null || true
    sleep 2
fi

NOTES_FILE=$(mktemp)
if [[ "$SIGNED_RELEASE" == true ]]; then
    cat <<EOF > "$NOTES_FILE"
## $APP_NAME $VERSION

Download the DMG, open it, and drag the app to your Applications folder.

**System Requirements:** macOS 13.0+ (Apple Silicon)
This release is Developer ID signed and notarized by Apple.
EOF
else
    cat <<EOF > "$NOTES_FILE"
## $APP_NAME $VERSION

Download the DMG, open it, and drag the app to your Applications folder.

**System Requirements:** macOS 13.0+ (Apple Silicon)

This release is not notarized.
If macOS blocks launch, run **Fix App.command** included in the DMG.
EOF
fi

gh release create "$TAG" \
    "$DMG_PATH" \
    --repo "$REPO_SLUG" \
    --title "$APP_NAME $TAG" \
    --notes-file "$NOTES_FILE" \
    --latest

echo ""
echo "==> Done! Release published at:"
echo "    https://github.com/$REPO_SLUG/releases/tag/$TAG"
