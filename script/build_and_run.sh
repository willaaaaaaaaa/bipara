#!/usr/bin/env bash
# Build the current native app, verify its embedded helper, and launch that bundle.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export BIPARA_TARGET_ARCH="${BIPARA_TARGET_ARCH:-$(uname -m)}"
if [ -f script/env.local.sh ]; then . script/env.local.sh; fi
MODE="${1:---verify}"
APP_PATH="$ROOT/build/native/Build/Products/Debug/Bipara.app"
PID_FILE="$ROOT/build/bipara-run.pid"
fail() { echo "build_and_run.sh: $1" >&2; exit 1; }
case "$MODE" in run|--verify|--debug|--logs) ;; *) fail "usage: $0 [run|--verify|--debug|--logs]";; esac
xcodebuild -version >/dev/null 2>&1 || fail "a usable full Xcode installation is required"
# Ask only this script's prior instance to quit, preserving its save/close review.
if [ -f "$PID_FILE" ]; then
  previous_pid="$(cat "$PID_FILE")"
  previous_path="$(ps -p "$previous_pid" -o comm= 2>/dev/null || true)"
  if [ "$previous_path" = "$APP_PATH/Contents/MacOS/Bipara" ]; then
    /usr/bin/xcrun swift -e 'import AppKit; import Foundation; guard CommandLine.arguments.count == 3,
      let pid = Int32(CommandLine.arguments[1]), let app = NSRunningApplication(processIdentifier: pid),
      app.executableURL?.path == CommandLine.arguments[2], app.terminate() else { exit(1) }' \
      "$previous_pid" "$APP_PATH/Contents/MacOS/Bipara" || fail "close the previous app instance before rebuilding"
    for attempt in {1..50}; do kill -0 "$previous_pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$previous_pid" 2>/dev/null && fail "resolve the previous app's unsaved-document prompt, then run again"
  fi
fi
"$ROOT/script/build_worker.sh"
xcodebuild -project Bipara.xcodeproj -scheme Bipara -configuration Debug \
  -destination "platform=macOS,arch=$BIPARA_TARGET_ARCH" "ARCHS=$BIPARA_TARGET_ARCH" -derivedDataPath build/native build
[ -x "$APP_PATH/Contents/MacOS/Bipara" ] || fail "fresh app executable missing"
HELPER="$APP_PATH/Contents/Helpers/BiparaWorker.app"
[ -x "$HELPER/Contents/MacOS/BiparaWorker" ] || fail "embedded worker missing"
cmp -s prompts/translation.v1.txt "$HELPER/Contents/Frameworks/prompts/translation.v1.txt" || fail "canonical prompt mismatch"
cmp -s prompts/translation.v2.txt "$HELPER/Contents/Frameworks/prompts/translation.v2.txt" || fail "canonical prompt mismatch"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
if [ "$MODE" = --debug ]; then exec lldb "$APP_PATH/Contents/MacOS/Bipara"; fi
/usr/bin/open -n "$APP_PATH"
for attempt in {1..30}; do
  for candidate in $(pgrep -x Bipara || true); do
    candidate_path="$(ps -p "$candidate" -o comm= 2>/dev/null || true)"
    if [ "$candidate_path" = "$APP_PATH/Contents/MacOS/Bipara" ]; then
      echo "$candidate" > "$PID_FILE"
      echo "build_and_run.sh: launched pid $candidate at $APP_PATH"
      if [ "$MODE" = --logs ]; then exec /usr/bin/log stream --info --predicate 'process == "Bipara"'; fi
      exit 0
    fi
  done
  sleep 0.1
done
fail "fresh app did not remain running"
