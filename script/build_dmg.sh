#!/usr/bin/env bash
# Formal builds use --tag; --development explicitly selects an ad-hoc local DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export BIPARA_TARGET_ARCH="${BIPARA_TARGET_ARCH:-$(uname -m)}"
if [ "${1:-}" != --development ]; then
  exec python3 "$ROOT/script/release.py" build "$@"
fi
shift
[ "$#" = 0 ] || { echo 'usage: build_dmg.sh --development | --tag vMAJOR.MINOR.PATCH' >&2; exit 1; }

# Optional local run environment (e.g. DEVELOPER_DIR); ignored if absent.
# shellcheck disable=SC1091
if [ "${BIPARA_RELEASE_BUILD:-0}" != 1 ]; then
  [ -f "script/env.local.sh" ] && . "script/env.local.sh" || true
fi

fail() {
  echo "build_dmg.sh: $1" >&2
  exit 1
}

step() {
  echo
  echo "==> $1"
}

verify_bundle() {
  local app="$1"
  local helper="$app/Contents/Helpers/BiparaWorker.app"
  [ -x "$app/Contents/MacOS/Bipara" ] || fail "app executable missing: $app"
  [ -x "$helper/Contents/MacOS/BiparaWorker" ] || fail "embedded worker missing: $app"
  for asset in translation.v1.txt translation.v2.txt translation.markdown.v1.txt alignment.v1.txt \
    translation-output.v1.schema.json alignment-output.v1.schema.json; do
    cmp -s "prompts/$asset" "$helper/Contents/Frameworks/prompts/$asset" \
      || fail "bundled asset differs from canonical prompts/$asset"
  done
  /usr/bin/codesign --verify --deep --strict "$app" \
    || fail "signature verification failed: $app"
}

MOUNTPOINT=""
cleanup() {
  if [ -n "$MOUNTPOINT" ]; then
    /usr/bin/hdiutil detach "$MOUNTPOINT" -force >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

step "Release worker bundle"
"$ROOT/script/build_worker.sh"

step "Native Release build"
xcodebuild -version >/dev/null 2>&1 || fail "a usable full Xcode installation is required"
DERIVED="$ROOT/build/native-release"
# Build from a clean state: incremental xcodebuild does not re-sign the app
# when only the rebuilt worker changed, leaving a stale outer seal over the
# new nested worker ("nested code is modified or invalid").
rm -rf "$DERIVED"
xcodebuild -project Bipara.xcodeproj -scheme Bipara -configuration Release \
  -destination "platform=macOS,arch=$BIPARA_TARGET_ARCH" "ARCHS=$BIPARA_TARGET_ARCH" -derivedDataPath "$DERIVED" build

APP_PATH="$DERIVED/Build/Products/Release/Bipara.app"
verify_bundle "$APP_PATH"

step "Assemble DMG staging"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP_PATH/Contents/Info.plist")"
STAGING="$ROOT/build/dmg-staging"
DMG="$ROOT/build/dist/Bipara-$VERSION-$BIPARA_TARGET_ARCH.dmg"
rm -rf "$STAGING"
mkdir -p "$STAGING" "$ROOT/build/dist"
/usr/bin/ditto "$APP_PATH" "$STAGING/Bipara.app"
ln -s /Applications "$STAGING/Applications"

step "Create DMG"
rm -f "$DMG"
/usr/bin/hdiutil create -volname Bipara -srcfolder "$STAGING" -format UDZO -ov "$DMG" \
  || fail "hdiutil create failed"
[ -f "$DMG" ] || fail "DMG missing after hdiutil"

step "Verify mounted image"
rm -rf "$ROOT/build/dmg-mount"
mkdir -p "$ROOT/build/dmg-mount"
MOUNTPOINT="$ROOT/build/dmg-mount"
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$MOUNTPOINT" "$DMG" >/dev/null \
  || fail "could not mount the DMG for verification"
verify_bundle "$MOUNTPOINT/Bipara.app"
/usr/bin/hdiutil detach "$MOUNTPOINT" >/dev/null || fail "could not unmount the verified DMG"
MOUNTPOINT=""

echo
echo "build_dmg.sh: verified $DMG"
du -sk "$DMG" | awk '{printf "%.1f MiB\n", $1/1024}'
echo "build_dmg.sh: local ad-hoc development package; not qualified for public distribution"
