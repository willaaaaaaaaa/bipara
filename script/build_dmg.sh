#!/usr/bin/env bash
# Formal builds use --tag; --development explicitly selects an ad-hoc local DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export BIPARA_TARGET_ARCH="${BIPARA_TARGET_ARCH:-$(uname -m)}"
MODE="${1:-}"
if [ "$MODE" != --development ] && [ "$MODE" != --install ]; then
  exec python3 "$ROOT/script/release.py" build "$@"
fi
shift
[ "$#" = 0 ] || { echo 'usage: build_dmg.sh --development | --install | --tag vMAJOR.MINOR.PATCH' >&2; exit 1; }

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

LOCAL_SIGNING_IDENTITY=""
if [ "$MODE" = --install ]; then
  LOCAL_SIGNING_IDENTITY="${BIPARA_LOCAL_CODESIGN_IDENTITY:-}"
fi
if [ -n "$LOCAL_SIGNING_IDENTITY" ]; then
  case "$LOCAL_SIGNING_IDENTITY" in
    'Apple Development: '*) ;;
    *) fail 'BIPARA_LOCAL_CODESIGN_IDENTITY must name an Apple Development certificate' ;;
  esac
  IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning)"
  if ! grep -Fq -- "\"$LOCAL_SIGNING_IDENTITY\"" <<< "$IDENTITIES"; then
    fail 'the configured local signing identity is unavailable'
  fi
fi

verify_bundle() {
  local app="$1"
  local helper="$app/Contents/Helpers/BiparaWorker.app"
  [ -x "$app/Contents/MacOS/Bipara" ] || fail "app executable missing: $app"
  [ -x "$helper/Contents/MacOS/BiparaWorker" ] || fail "embedded worker missing: $app"
  python3 script/worker_assets.py "$helper"
  /usr/bin/codesign --verify --deep --strict "$app" \
    || fail "signature verification failed: $app"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bipara-package.XXXXXXXX")"
MOUNTPOINT=""
cleanup() {
  if [ -n "$MOUNTPOINT" ] && [ -d "$MOUNTPOINT/Bipara.app" ]; then
    /usr/bin/hdiutil detach "$MOUNTPOINT" >/dev/null || return 1
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

step "Release worker bundle"
"$ROOT/script/build_worker.sh" --release-only

step "Native Release build"
xcodebuild -version >/dev/null 2>&1 || fail "a usable full Xcode installation is required"
DERIVED="$WORK/native"
# A local Mac may be listed as arm64e even when building an arm64 package.
xcodebuild -project Bipara.xcodeproj -scheme Bipara -configuration Release \
  -destination 'generic/platform=macOS' "ARCHS=$BIPARA_TARGET_ARCH" ONLY_ACTIVE_ARCH=NO \
  -derivedDataPath "$DERIVED" -clonedSourcePackagesDirPath "$ROOT/build/SourcePackages" -onlyUsePackageVersionsFromResolvedFile build

APP_PATH="$DERIVED/Build/Products/Release/Bipara.app"
if [ -n "$LOCAL_SIGNING_IDENTITY" ]; then
  step "Sign local Bipara app"
  /usr/bin/codesign --force --sign "$LOCAL_SIGNING_IDENTITY" --timestamp=none --options runtime "$APP_PATH"
fi
verify_bundle "$APP_PATH"
if [ "$MODE" = --install ]; then
  "$APP_PATH/Contents/MacOS/Bipara" --install-local-build
  exit 0
fi

step "Assemble DMG staging"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$APP_PATH/Contents/Info.plist")"
STAGING="$WORK/staging"
DMG="$ROOT/build/dist/Bipara-$VERSION-$BIPARA_TARGET_ARCH.dmg"
mkdir -p "$STAGING" "$ROOT/build/dist"
/usr/bin/ditto "$APP_PATH" "$STAGING/Bipara.app"

step "Create DMG"
CANDIDATE="$WORK/Bipara.dmg"
/usr/bin/hdiutil create -volname Bipara -srcfolder "$STAGING" -format UDZO -ov "$CANDIDATE" \
  || fail "hdiutil create failed"
[ -f "$CANDIDATE" ] || fail "DMG missing after hdiutil"

step "Verify mounted image"
MOUNTPOINT="$WORK/mount"
mkdir "$MOUNTPOINT"
/usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$MOUNTPOINT" "$CANDIDATE" >/dev/null \
  || fail "could not mount the DMG for verification"
verify_bundle "$MOUNTPOINT/Bipara.app"
/usr/bin/hdiutil detach "$MOUNTPOINT" >/dev/null || fail "could not unmount the verified DMG"
MOUNTPOINT=""
mv -f "$CANDIDATE" "$DMG"

echo
echo "build_dmg.sh: verified $DMG"
du -sk "$DMG" | awk '{printf "%.1f MiB\n", $1/1024}'
echo "build_dmg.sh: local ad-hoc development package; not qualified for public distribution"
