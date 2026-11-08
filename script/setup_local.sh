#!/usr/bin/env bash
# Prepare ignored temporary storage and install repository-local upload checks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
case "$#" in
  0) private_dir="$(git config --local --get bipara.privateDirectory || true)" ;;
  2) [ "$1" = --private-dir ] || { echo 'usage: setup_local.sh [--private-dir PATH]' >&2; exit 1; }; private_dir="$2" ;;
  *) echo 'usage: setup_local.sh [--private-dir PATH]' >&2; exit 1 ;;
esac
if [ -z "$private_dir" ]; then private_dir="$HOME/Documents/Private/Bipara"; fi
private_dir="$(python3 - "$ROOT" "$private_dir" <<'PY'
from pathlib import Path
import sys
root, private = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).expanduser().resolve()
if private.is_relative_to(root):
    raise SystemExit('setup_local: long-lived private storage must be outside the checkout')
print(private)
PY
)"
existing="$(git config --local --get core.hooksPath || true)"
if [ -n "$existing" ] && [ "$existing" != .githooks ]; then
  echo 'setup_local: existing hooksPath requires manual integration' >&2
  exit 1
fi
mkdir -p .local/notes .local/logs .local/validation
chmod 700 .local .local/notes .local/logs .local/validation
mkdir -p "$private_dir"
chmod 700 "$private_dir"
patterns_file="$private_dir/public-content-patterns.json"
if [ ! -e "$patterns_file" ]; then
  (umask 077; printf '%s\n' '{"literals": []}' > "$patterns_file")
fi
git check-ignore -q .local/notes/example.md
if [ -n "$(git ls-files -- .local/)" ]; then
  echo 'setup_local: local storage is already tracked; resolve it before continuing' >&2
  exit 1
fi
python3 script/install_check_tools.py
tools_dir="$(python3 -c 'from pathlib import Path; import sys; sys.path.insert(0, "script"); from install_check_tools import tool_directory; print(tool_directory(Path.cwd()))')"
git config --local bipara.checkToolsDirectory "$tools_dir"
git config --local core.hooksPath .githooks
git config --local bipara.privateDirectory "$private_dir"
git config --local bipara.privatePatternsFile "$patterns_file"
echo 'setup_local: temporary storage, external private storage and upload checks are ready'
