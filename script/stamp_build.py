"""Record source identity in the signed app and the standard macOS About panel."""
import json
from pathlib import Path
import subprocess
import sys

resources = Path(sys.argv[1])
resources.mkdir(parents=True, exist_ok=True)
history = subprocess.run(["git", "rev-list", "--topo-order", "HEAD"], text=True, capture_output=True)
commits = history.stdout.splitlines() if history.returncode == 0 else []
modified = bool(commits and subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=normal"]))
source = {"commits": commits, "modified": modified}
(resources / "BuildSource.json").write_text(json.dumps(source) + "\n")
label = commits[0][:12] if commits else "unknown"
if modified:
    label += " (local changes)"
(resources / "Credits.rtf").write_text(r"{\rtf1\ansi Source: " + label + "}\n")
