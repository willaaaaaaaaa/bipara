#!/usr/bin/env bash
# Prepare this checkout's ignored scratch directories, Git hooks and check tools.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  echo 'usage: script/setup.sh [--private-patterns-file PATH]'
  echo 'Install pinned check tools in an external cache and enable repository hooks.'
  echo 'Optionally select an existing external JSON file containing private literals.'
  echo 'Existing rule files, external directories and custom hooks are never replaced.'
}

patterns_file=""
case "$#" in
  0) ;;
  1) case "$1" in -h|--help) usage; exit 0 ;; *) usage >&2; exit 1 ;; esac ;;
  2) [ "$1" = --private-patterns-file ] && [ -n "$2" ] || { usage >&2; exit 1; }; patterns_file="$2" ;;
  *) usage >&2; exit 1 ;;
esac

# Honor effective hooks, including global or worktree-specific configuration.
existing="$(git config --get core.hooksPath || true)"
if [ -n "$existing" ] && [ "$existing" != .githooks ]; then
  echo 'setup: existing hooksPath requires manual integration; no setup changes made' >&2
  exit 1
fi
if ! git check-ignore -q .local/notes/example.md || [ -n "$(git ls-files -- .local/)" ]; then
  echo 'setup: scratch storage must be ignored and untracked before continuing' >&2
  exit 1
fi

# Validate both persistent and process-only selections before making any writes.
# Reuse the checker's parser so setup cannot silently weaken its rule selection.
patterns_file="$(python3 - "$patterns_file" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, "script")
from check_public_content import private_literals
from install_check_tools import tool_directory

root = Path.cwd()
explicit = sys.argv[1]
configured = subprocess.run(["git", "config", "--local", "--get", "bipara.privatePatternsFile"], capture_output=True, text=True).stdout.strip()
override = os.environ.get("BIPARA_PRIVATE_PATTERNS_FILE")
try:
    for value in (explicit or configured, override):
        if value:
            os.environ["BIPARA_PRIVATE_PATTERNS_FILE"] = value
            private_literals(root)
except (OSError, ValueError, KeyError, TypeError):
    raise SystemExit("setup: private pattern file must be valid, readable and outside the checkout; no setup changes made")
try:
    tool_directory(root)
except (OSError, ValueError):
    raise SystemExit("setup: check-tool cache must be outside the checkout; no setup changes made")
if explicit:
    print(Path(explicit).expanduser().resolve())
PY
)"

mkdir -p .local/notes .local/logs .local/validation
chmod 700 .local .local/notes .local/logs .local/validation
python3 script/install_check_tools.py
tools_dir="$(python3 -c 'from pathlib import Path; import sys; sys.path.insert(0, "script"); from install_check_tools import tool_directory; print(tool_directory(Path.cwd()))')"
git config --local bipara.checkToolsDirectory "$tools_dir"
git config --local core.hooksPath .githooks
if [ -n "$patterns_file" ]; then
  git config --local bipara.privatePatternsFile "$patterns_file"
fi
echo 'setup: ignored scratch directories, pinned check tools and Git hooks are ready'
