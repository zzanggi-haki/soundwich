#!/bin/bash
# Builds Soundwich as a universal (arm64 + x86_64) Release app, ad-hoc signs it,
# and packages it into a distributable .dmg.
#
# This produces an UNSIGNED-for-distribution build (ad-hoc only): users must bypass
# Gatekeeper on first launch. See INSTALL.md for the user-facing instructions.
#
# Usage: ./scripts/build_dmg.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD_DIR="$ROOT/build"
APP_NAME="Soundwich"
DMG_NAME="Soundwich.dmg"

export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
XCODEBUILD="$DEVELOPER_DIR/usr/bin/xcodebuild"

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building universal Release"
rm -rf "$BUILD_DIR"
"$XCODEBUILD" \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
[ -d "$APP_PATH" ] || { echo "Build failed: $APP_PATH not found"; exit 1; }

echo "==> Ad-hoc signing (with entitlements)"
codesign --force --deep \
  --entitlements "$ROOT/$APP_NAME/$APP_NAME.entitlements" \
  --sign - "$APP_PATH"
codesign --verify --verbose "$APP_PATH" || true

echo "==> Staging DMG contents"
STAGE="$BUILD_DIR/dmg"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP_PATH" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> Creating $DMG_NAME"
rm -f "$ROOT/$DMG_NAME"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$ROOT/$DMG_NAME" >/dev/null

echo "==> Done: $ROOT/$DMG_NAME"
ls -lh "$ROOT/$DMG_NAME"
lipo -info "$APP_PATH/Contents/MacOS/$APP_NAME" 2>/dev/null || true
