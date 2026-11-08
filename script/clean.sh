#!/usr/bin/env bash
# Remove repository-local build products without touching installed apps or data.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: ./script/clean.sh [--dry-run | --help]

Remove build/ and .build/ relative to this script's repository, including
temporary apps, packaged workers, test reports, DMGs, and Swift build caches.
Use --dry-run to preview the paths without deleting anything.

Stop builds and tests and close apps launched from these directories first.
Source files, local configuration, Worker/.venv, installed apps, preferences,
Keychain credentials, and saved documents outside these directories are kept.
Search results may take time to disappear; rebuilding creates new products.
EOF
}

if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=true ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

TARGETS=("$ROOT/build" "$ROOT/.build")

# Preflight every target before deleting any. Never traverse a mounted image
# left behind by packaging; the caller can eject it and retry.
if [ "$DRY_RUN" = false ]; then
  MOUNTS="$(/sbin/mount)"
  for target in "${TARGETS[@]}"; do
    # rm removes a directory symlink itself, not its external destination.
    [ -L "$target" ] && continue
    if printf '%s\n' "$MOUNTS" | awk -v target="$target" '
      index($0, " on " target " (") || index($0, " on " target "/") { found = 1 }
      END { exit !found }
    '; then
      echo "clean.sh: eject mounted volumes under $target before cleaning" >&2
      exit 1
    fi
  done
fi

for target in "${TARGETS[@]}"; do
  if [ "$DRY_RUN" = true ]; then
    printf 'Would remove: %s\n' "$target"
  else
    printf 'Removing: %s\n' "$target"
    rm -rf -- "$target"
  fi
done

if [ "$DRY_RUN" = false ]; then
  echo "clean.sh: build products removed; search indexes may update later."
fi
