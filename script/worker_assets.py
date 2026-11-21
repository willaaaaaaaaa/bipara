"""Package and verify the worker's canonical prompt and schema assets."""

from __future__ import annotations

import argparse
import atexit
import json
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROMPTS = ROOT / "prompts"
sys.path.insert(0, str(ROOT / "Worker"))
from bipara_worker.assets import ASSET_FILES, CASES_FILE, MANIFEST_NAME, AssetError, sha256_file
from bipara_worker.protocol import FatalError, decode_json_strict


def worker_asset_data(*, fixture: bool = False) -> list[tuple[str, str]]:
    paths = [PROMPTS / name for name in ASSET_FILES]
    hashes = {path.name: sha256_file(path) for path in paths}
    if fixture:
        paths.append(PROMPTS / CASES_FILE)
    staging = tempfile.TemporaryDirectory(prefix="bipara-worker-assets-")
    atexit.register(staging.cleanup)
    manifest = Path(staging.name) / MANIFEST_NAME
    manifest.write_text(json.dumps({"files": hashes}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return [(str(path), "prompts") for path in (*paths, manifest)]


def verify_worker_assets(helper: Path) -> dict[str, str]:
    bundled = helper / "Contents/Frameworks/prompts"
    hashes = {}
    for name in ASSET_FILES:
        try:
            expected = sha256_file(PROMPTS / name)
            actual = sha256_file(bundled / name)
        except OSError as exc:
            raise AssetError(f"could not read worker asset: {name}") from exc
        if actual != expected:
            raise AssetError(f"bundled asset differs from canonical prompts/{name}")
        hashes[name] = actual
    try:
        manifest = decode_json_strict((bundled / MANIFEST_NAME).read_text("utf-8"))
    except (OSError, UnicodeError, FatalError) as exc:
        raise AssetError("bundled asset manifest is unreadable") from exc
    if manifest != {"files": hashes}:
        raise AssetError("bundled asset manifest differs from canonical asset hashes")
    return hashes


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("helper", type=Path)
    args = parser.parse_args()
    try:
        verify_worker_assets(args.helper)
    except AssetError as exc:
        parser.exit(1, f"worker_assets.py: {exc}\n")
