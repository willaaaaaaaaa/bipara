#!/usr/bin/env bash
# Run all default (offline) checks: Swift Core tests, Python protocol and
# packaged-worker tests, and the native app build. Exits nonzero when any
# applicable suite fails or a prerequisite is missing.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Optional local run environment (e.g. DEVELOPER_DIR); ignored if absent.
# shellcheck disable=SC1091
if [ "${BIPARA_RELEASE_BUILD:-0}" != 1 ]; then
  [ -f "script/env.local.sh" ] && . "script/env.local.sh" || true
else
  UV_PYTHON="$(python3 script/prepare_release_runtime.py)" || exit 1
  export UV_PYTHON UV_PYTHON_DOWNLOADS=never UV_PYTHON_PREFERENCE=only-system
fi

FAILURES=0

step() {
  echo
  echo "==> $1"
}

record() {
  if [ "$1" -ne 0 ]; then
    FAILURES=$((FAILURES + 1))
    echo "check.sh: FAILED: $2 (exit $1)"
  else
    echo "check.sh: ok: $2"
  fi
}

step "Public content and tooling regressions"
python3 script/check_public_content.py --gitleaks
record $? "public-content check"
python3 -m unittest discover -s Tests/Tooling
record $? "tooling regressions"

step "Worker environment sync"
uv sync --project Worker --frozen --group dev
record $? "uv sync --project Worker --frozen --group dev"

step "Worker bundles (needed by packaged tests)"
"$ROOT/script/build_worker.sh"
record $? "script/build_worker.sh"

step "Swift package tests (offline: Core, real-process worker adapter, app state)"
# Keep linking consistent and isolate main-actor fixtures; see Tests/README.md.
SWIFT_TEST_FLAGS=(--build-system swiftbuild --no-parallel)
TESTING_PLUGIN_DIR="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
if [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ] && [ -d "$TESTING_PLUGIN_DIR" ]; then
  # Command Line Tools-only setups intermittently fail to discover the
  # swift-testing macro plugin ("plugin for module 'TestingMacros' not
  # found"); pin its search directory explicitly. Full Xcode is unaffected.
  SWIFT_TEST_FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGIN_DIR")
fi
swift test "${SWIFT_TEST_FLAGS[@]}"
record $? "swift test (Core + Worker adapter + AppKit)"

step "Python offline tests incl. packaged worker IPC"
uv run --project Worker --frozen pytest -m "not live"
record $? "pytest -m 'not live'"

step "Native app build (requires full Xcode)"
if command -v xcodebuild >/dev/null 2>&1; then
  xcodebuild -project Bipara.xcodeproj -scheme Bipara \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath build/native-check \
    build
  record $? "xcodebuild build"
else
  echo "check.sh: xcodebuild unavailable: full Xcode is not installed" >&2
  echo "  (active developer directory is a Command Line Tools instance)" >&2
  record 1 "xcodebuild build (prerequisite missing)"
fi

echo
if [ "$FAILURES" -ne 0 ]; then
  echo "check.sh: $FAILURES step(s) failed" >&2
  exit 1
fi
echo "check.sh: all steps passed"
