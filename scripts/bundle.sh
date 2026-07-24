#!/bin/bash
set -euo pipefail

# Usage:
#   scripts/bundle.sh [release|debug]           # ad-hoc signed dev build
#   scripts/bundle.sh debug --fast              # fastest: skip dSYM + deep sign, just env+build
#   scripts/bundle.sh release --sign            # build + Developer ID codesign
#   scripts/bundle.sh release --dist            # build + sign + notarize + staple + DMG

CONFIG="release"
MODE="dev"
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG="$arg" ;;
    --fast)        MODE="fast" ;;
    --sign)        MODE="sign" ;;
    --dist)        MODE="dist" ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

ENV_FILE=".env"
if [ "$CONFIG" = "release" ] && [ -f "$ROOT/.env.prod" ]; then
  ENV_FILE=".env.prod"
fi
if [ -f "$ROOT/$ENV_FILE" ]; then
  echo "==> Loading $ENV_FILE"
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/$ENV_FILE"
  set +a
fi

SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-nueditor-notary}"
PROVISION_PROFILE="${PROVISION_PROFILE:-$ROOT/scripts/NUEditor_Developer_ID.provisionprofile}"
ENTITLEMENTS="$ROOT/scripts/NUEditor.entitlements"
RESOURCES="$ROOT/Sources/NUEditor/Resources"
APP="$ROOT/.build/NUEditor.app"
ZIP="$ROOT/.build/NUEditor.zip"
DMG="$ROOT/.build/NUEditor.dmg"

echo "==> Building ($CONFIG)"
BUILD_ARGS=(-c "$CONFIG" --traits BundledSpeech)
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/NUEditor"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/NUEditor"
cp "$RESOURCES/Info.plist" "$APP/Contents/Info.plist"

cp "$RESOURCES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Flatten SwiftPM's resource bundle into the app's Resources tree.
RES_BUNDLE="$(dirname "$BIN")/NUEditor_NUEditor.bundle"
if [ -d "$RES_BUNDLE/Fonts" ]; then
  cp -R "$RES_BUNDLE/Fonts" "$APP/Contents/Resources/"
else
  echo "!! missing Fonts/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi

# Ensure the shipped Claude Desktop connector is always up to date with mcpb/ sources.
MCPB_SRC="$ROOT/mcpb"
MCPB_CHECKED_IN="$ROOT/Sources/NUEditor/Resources/MCPB/nueditor.mcpb"
MCPB_FRESH="$(mktemp -d)/nueditor.mcpb"
(cd "$MCPB_SRC" && zip -q -X -r "$MCPB_FRESH" manifest.json icon.png server/index.js server/package.json)
if ! unzip -p "$MCPB_CHECKED_IN" server/index.js 2>/dev/null | diff -q - <(unzip -p "$MCPB_FRESH" server/index.js) >/dev/null 2>&1 \
  || ! unzip -p "$MCPB_CHECKED_IN" manifest.json 2>/dev/null | diff -q - <(unzip -p "$MCPB_FRESH" manifest.json) >/dev/null 2>&1; then
  echo "==> refreshing checked-in nueditor.mcpb from mcpb/ sources"
  cp "$MCPB_FRESH" "$MCPB_CHECKED_IN"
fi
cp "$MCPB_FRESH" "$APP/Contents/Resources/nueditor.mcpb"
rm -rf "$(dirname "$MCPB_FRESH")"
if [ -d "$RES_BUNDLE/Images" ]; then
  cp -R "$RES_BUNDLE/Images" "$APP/Contents/Resources/"
fi
# .lproj folders must live at the bundle root for macOS to resolve them —
# flatten out of Resources/Localization/ even though that's just an org folder.
if [ -d "$RES_BUNDLE/Localization" ]; then
  for locale_dir in "$RES_BUNDLE/Localization"/*.lproj; do
    [ -d "$locale_dir" ] && cp -R "$locale_dir" "$APP/Contents/Resources/"
  done
else
  echo "!! missing Localization/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi
if [ -d "$RES_BUNDLE/Changelog" ]; then
  cp -R "$RES_BUNDLE/Changelog" "$APP/Contents/Resources/"
else
  echo "!! missing Changelog/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi
if [ -d "$RES_BUNDLE/Models" ]; then
  cp -R "$RES_BUNDLE/Models" "$APP/Contents/Resources/"
else
  echo "!! missing Models/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi

if ! ls "$RES_BUNDLE"/*.metallib >/dev/null 2>&1; then
  echo "!! no .metallib in SwiftPM resource bundle at $RES_BUNDLE — Metal effects would be missing" >&2
  exit 1
fi
cp "$RES_BUNDLE"/*.metallib "$APP/Contents/Resources/"

MLX_METALLIB="$ROOT/.build/$CONFIG/mlx.metallib"
if [ ! -f "$MLX_METALLIB" ]; then
  echo "==> Building MLX metallib ($CONFIG)"
  BUILD_DIR="$ROOT/.build" "$ROOT/.build/checkouts/speech-swift/scripts/build_mlx_metallib.sh" "$CONFIG"
fi
if [ ! -f "$MLX_METALLIB" ]; then
  echo "!! missing $MLX_METALLIB — on-device speech features (VAD, speaker ID) would die silently" >&2
  exit 1
fi
mkdir -p "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
cp "$MLX_METALLIB" "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"

install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/NUEditor"
touch "$APP"

if [ "$MODE" = "fast" ]; then
  echo "==> Codesigning main app with $SIGNING_IDENTITY (no timestamp, no helpers)"
  codesign --force --sign "$SIGNING_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  echo "==> Done: $APP (fast mode — stable identity, no dSYM)"
  exit 0
fi

DSYM="$ROOT/.build/NUEditor.dSYM"
echo "==> Generating dSYM"
rm -rf "$DSYM"
dsymutil "$APP/Contents/MacOS/NUEditor" -o "$DSYM"

if [ "$MODE" = "dev" ]; then
  echo "==> Ad-hoc signing dev app"
  codesign --force --deep --sign - "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  echo "==> Done: $APP (ad-hoc signed)"
  exit 0
fi

echo "==> Embedding provisioning profile"
if [ ! -f "$PROVISION_PROFILE" ]; then
  echo "!! provisioning profile not found at $PROVISION_PROFILE" >&2
  exit 1
fi
cp "$PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"

echo "==> Codesigning main app"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGNING_IDENTITY" \
  "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [ "$MODE" = "sign" ]; then
  echo "==> Done: $APP (signed, not notarized)"
  exit 0
fi

echo "==> Zipping .app for notarization"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary (this can take several minutes)"
xcrun notarytool submit "$ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling ticket to .app"
xcrun stapler staple "$APP"
rm -f "$ZIP"

echo "==> Building DMG"
rm -f "$DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/NUEditor.app"
ln -s /Applications "$STAGING/Applications"
cp "$RESOURCES/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
hdiutil create \
  -volname "NUEditor" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG"
rm -rf "$STAGING"

echo "==> Codesigning DMG"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"

echo "==> Submitting DMG to notary"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling DMG"
xcrun stapler staple "$DMG"

echo ""
echo "==> Done"
echo "   App: $APP"
echo "   DMG: $DMG"
