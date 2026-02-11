#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="AlfredAlternative"
APP_BUNDLE="$ROOT_DIR/.build/$APP_NAME.app"
DMG_DIR="$ROOT_DIR/.build"

VERSION=$(grep '^version' "$ROOT_DIR/Cargo.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')
if [[ -z "$VERSION" ]]; then
    echo "error: could not read version from Cargo.toml"
    exit 1
fi

TAG="v$VERSION"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="$DMG_DIR/$DMG_NAME"

echo "==> Building $APP_NAME v$VERSION ..."
make -C "$ROOT_DIR" build-app

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "error: app bundle not found at $APP_BUNDLE"
    exit 1
fi

echo "==> Creating DMG ..."
rm -f "$DMG_PATH"

# Strip quarantine so users don't get "damaged" error
xattr -cr "$APP_BUNDLE"

STAGING_DIR=$(mktemp -d)
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo "==> DMG created: $DMG_PATH"
ls -lh "$DMG_PATH"

echo ""
echo "==> Creating GitHub release $TAG ..."

if ! command -v gh &>/dev/null; then
    echo "error: gh CLI not found. Install with: brew install gh"
    exit 1
fi

if ! gh auth status &>/dev/null; then
    echo "error: gh is not authenticated. Run: gh auth login"
    exit 1
fi

EXISTING=$(gh release view "$TAG" --repo serkandemirel0420/alfredalt --json tagName 2>/dev/null || true)
if [[ -n "$EXISTING" ]]; then
    echo "Release $TAG already exists. Deleting and recreating..."
    gh release delete "$TAG" --repo serkandemirel0420/alfredalt --yes --cleanup-tag 2>/dev/null || true
    sleep 2
fi

gh release create "$TAG" \
    "$DMG_PATH" \
    --repo serkandemirel0420/alfredalt \
    --title "$APP_NAME $TAG" \
    --notes "## $APP_NAME $VERSION

Download the DMG, open it, and drag the app to your Applications folder.

**System Requirements:** macOS 13.0+ (Apple Silicon)

> **Note:** This app is not code-signed. If macOS says it's damaged, right-click the app → Open, or run:
> \`\`\`
> xattr -cr /Applications/AlfredAlternative.app
> \`\`\`" \
    --latest

echo ""
echo "==> Done! Release published at:"
echo "    https://github.com/serkandemirel0420/alfredalt/releases/tag/$TAG"
