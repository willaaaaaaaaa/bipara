#!/usr/bin/env bash
# Build the current native app, verify its embedded helper, and launch that bundle.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export BIPARA_TARGET_ARCH="${BIPARA_TARGET_ARCH:-$(uname -m)}"
if [ -f script/env.local.sh ]; then . script/env.local.sh; fi
MODE="${1:---verify}"
PID_FILE="$ROOT/build/bipara-run.pid"
fail() { echo "build_and_run.sh: $1" >&2; exit 1; }
case "$MODE" in run|--verify|--debug|--logs) ;; *) fail "usage: $0 [run|--verify|--debug|--logs]";; esac
xcodebuild -version >/dev/null 2>&1 || fail "a usable full Xcode installation is required"
# Ask only this script's prior instance to quit, preserving its save/close review.
if [ -f "$PID_FILE" ]; then
  previous_pid="$(head -n 1 "$PID_FILE")"
  previous_path="$(ps -p "$previous_pid" -o comm= 2>/dev/null || true)"
  recorded_path="$(sed -n '2p' "$PID_FILE")"
  case "$previous_path" in
    "$ROOT/build/native/Build/Products/Debug/Bipara.app/Contents/MacOS/Bipara") ;;
    "$ROOT"/build/debug-*.noindex/Bipara.app/Contents/MacOS/Bipara) [ "$recorded_path" = "$previous_path" ] || previous_path="" ;;
    *) previous_path="" ;;
  esac
  if [ -n "$previous_path" ]; then
    /usr/bin/xcrun swift -e 'import AppKit; import Foundation; guard CommandLine.arguments.count == 3,
      let pid = Int32(CommandLine.arguments[1]), let app = NSRunningApplication(processIdentifier: pid),
      app.executableURL?.path == CommandLine.arguments[2], app.terminate() else { exit(1) }' \
      "$previous_pid" "$previous_path" || fail "close the previous app instance before rebuilding"
    for attempt in {1..50}; do kill -0 "$previous_pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$previous_pid" 2>/dev/null && fail "resolve the previous app's unsaved-document prompt, then run again"
  fi
fi
"$ROOT/script/build_worker.sh"
PRODUCTS="$(mktemp -d "$ROOT/build/debug-XXXXXXXX")"
mv "$PRODUCTS" "$PRODUCTS.noindex"
PRODUCTS="$PRODUCTS.noindex"
APP_PATH="$PRODUCTS/Bipara.app"
trap 'rm -rf "$PRODUCTS"' EXIT
# Keep the build architecture independent of Xcode's local Mac destination (which can report arm64e).
xcodebuild -project Bipara.xcodeproj -scheme Bipara -configuration Debug \
  -destination 'generic/platform=macOS' "ARCHS=$BIPARA_TARGET_ARCH" ONLY_ACTIVE_ARCH=NO \
  -derivedDataPath build/native "CONFIGURATION_BUILD_DIR=$PRODUCTS" build
[ -x "$APP_PATH/Contents/MacOS/Bipara" ] || fail "fresh app executable missing"
HELPER="$APP_PATH/Contents/Helpers/BiparaWorker.app"
[ -x "$HELPER/Contents/MacOS/BiparaWorker" ] || fail "embedded worker missing"
python3 script/worker_assets.py "$HELPER"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
if [ "$MODE" = --debug ]; then lldb "$APP_PATH/Contents/MacOS/Bipara"; exit $?; fi
( /usr/bin/open -n -W "$APP_PATH" || true; rm -rf "$PRODUCTS" ) </dev/null >/dev/null 2>&1 &
trap - EXIT
for attempt in {1..30}; do
  for candidate in $(pgrep -x Bipara || true); do
    candidate_path="$(ps -p "$candidate" -o comm= 2>/dev/null || true)"
    if [ "$candidate_path" = "$APP_PATH/Contents/MacOS/Bipara" ]; then
      printf '%s\n' "$candidate" "$candidate_path" > "$PID_FILE"
      echo "build_and_run.sh: launched pid $candidate at $APP_PATH"
      if [ "$MODE" = --logs ]; then exec /usr/bin/log stream --info --predicate 'process == "Bipara"'; fi
      exit 0
    fi
  done
  sleep 0.1
done
fail "fresh app did not remain running"
