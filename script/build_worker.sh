#!/usr/bin/env bash
# Build the frozen Bipara worker bundles (release + test fixture) with
# PyInstaller onedir, verify canonical assets and the helper bundle layout,
# and collect dependency licenses in ignored build output. Makes no model calls.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RELEASE_APP="build/worker/BiparaWorker.app"
FIXTURE_APP="build/worker-fixture/BiparaWorkerFixture.app"
SYNC_OPTIONS=(--frozen --group dev)
# Optional local run environment (e.g. DEVELOPER_DIR); ignored if absent.
# shellcheck disable=SC1091
if [ "${BIPARA_RELEASE_BUILD:-0}" != 1 ]; then
  [ -f "script/env.local.sh" ] && . "script/env.local.sh" || true
fi
export BIPARA_TARGET_ARCH="${BIPARA_TARGET_ARCH:-$(uname -m)}"
case "$BIPARA_TARGET_ARCH" in arm64) PYTHON_PLATFORM=aarch64-apple-darwin ;; x86_64) PYTHON_PLATFORM=x86_64-apple-darwin ;; *) echo "Unsupported architecture" >&2; exit 1 ;; esac
# Reject a mismatched host before downloading or changing the environment.
[ "$(uname -m)" = "$BIPARA_TARGET_ARCH" ] || { echo "worker build host must match BIPARA_TARGET_ARCH" >&2; exit 1; }
if [ "${BIPARA_RELEASE_BUILD:-0}" = 1 ]; then
  UV_PYTHON="$(python3 script/prepare_release_runtime.py)" || exit 1
  export UV_PYTHON UV_PYTHON_DOWNLOADS=never UV_PYTHON_PREFERENCE=only-system
  # A newer build host can otherwise select wheels that require a newer OS.
  export MACOSX_DEPLOYMENT_TARGET=14.0
  SYNC_OPTIONS+=(--python-platform "$PYTHON_PLATFORM")
fi
case "${1:-}" in ''|--release-only) ;; *) echo 'usage: build_worker.sh [--release-only]' >&2; exit 1 ;; esac

fail() {
  echo "build_worker.sh: $1" >&2
  exit 1
}

# Keep separate checkouts from deleting or rewriting a shared binary cache.
export PYINSTALLER_CONFIG_DIR="$ROOT/build/pyinstaller-cache"

echo "==> Syncing locked worker environment"
uv sync --project Worker "${SYNC_OPTIONS[@]}"

echo "==> Recording dependency notices"
uv run --project Worker --no-sync python script/generate_notices.py --out build/third-party

echo "==> Building release worker bundle"
rm -rf build/worker build/pyinstaller-work
uv run --project Worker --no-sync pyinstaller \
  --clean \
  --distpath build/worker \
  --workpath build/pyinstaller-work \
  --noconfirm \
  Worker/bipara_worker.spec

echo "==> Building test fixture worker bundle"
if [ "${1:-}" != --release-only ]; then
rm -rf build/worker-fixture build/pyinstaller-fixture-work
uv run --project Worker --no-sync pyinstaller \
  --clean \
  --distpath build/worker-fixture \
  --workpath build/pyinstaller-fixture-work \
  --noconfirm \
  Worker/tests/fixture_worker.spec
fi

[ -x "$RELEASE_APP/Contents/MacOS/BiparaWorker" ] || fail "release executable missing"
APPS=("$RELEASE_APP")
if [ "${1:-}" != --release-only ]; then
  [ -x "$FIXTURE_APP/Contents/MacOS/BiparaWorkerFixture" ] || fail "fixture executable missing"
  APPS+=("$FIXTURE_APP")
fi

for app in "${APPS[@]}"; do
  /usr/libexec/PlistBuddy -c "Print :LSUIElement" "$app/Contents/Info.plist" >/dev/null 2>&1 \
    || fail "LSUIElement missing in $app"
  [ -f "$app/Contents/Frameworks/prompts/asset_manifest.json" ] \
    || fail "asset manifest missing in $app"
  for asset in translation.v1.txt translation.v2.txt translation.markdown.v1.txt alignment.v1.txt \
    translation-output.v1.schema.json alignment-output.v1.schema.json; do
    cmp -s "prompts/$asset" "$app/Contents/Frameworks/prompts/$asset" \
      || fail "bundled asset differs from canonical prompts/$asset"
  done
done

echo "==> Worker bundles verified"
du -sk "${APPS[@]}" | awk '{printf "%s: %.1f MiB\n", $2, $1/1024}'
