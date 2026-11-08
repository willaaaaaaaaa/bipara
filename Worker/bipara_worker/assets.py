"""Canonical prompt/schema asset loading with SHA-256 verification.

Assets are packaged from the repository's canonical ``prompts/`` files; the
build writes an ``asset_manifest.json`` into the bundle and the worker
refuses to report ready until every bundled copy matches it. In development
mode the canonical files themselves are read and hashed.
"""

from __future__ import annotations

import hashlib
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .protocol import PROMPT_VERSIONS, decode_json_strict

PROMPT_FILES = {
    "translation.v1": "translation.v1.txt",
    "translation.v2": "translation.v2.txt",
    "alignment.v1": "alignment.v1.txt",
}
SCHEMA_FILES = {
    "translation.v1": "translation-output.v1.schema.json",
    "translation.v2": "translation-output.v1.schema.json",
    "alignment.v1": "alignment-output.v1.schema.json",
}
ASSET_FILES = tuple(dict.fromkeys((*PROMPT_FILES.values(), *SCHEMA_FILES.values())))
MANIFEST_NAME = "asset_manifest.json"
CASES_FILE = "cases.json"


class AssetError(Exception):
    """Assets are missing or failed hash verification."""


def asset_dir() -> Path:
    if getattr(sys, "frozen", False):
        base = Path(getattr(sys, "_MEIPASS", Path(sys.executable).resolve().parent))
        return Path(base) / "prompts"
    return Path(__file__).resolve().parents[2] / "prompts"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


@dataclass(frozen=True)
class Assets:
    prompts: dict[str, str]
    schemas: dict[str, dict[str, Any]]
    hashes: dict[str, str]

    @property
    def versions(self) -> tuple[str, ...]:
        return PROMPT_VERSIONS


def load_assets() -> Assets:
    base = asset_dir()
    if not base.is_dir():
        raise AssetError("prompt asset directory is missing")
    prompts: dict[str, str] = {}
    schemas: dict[str, dict[str, Any]] = {}
    hashes: dict[str, str] = {}
    for version, filename in PROMPT_FILES.items():
        data = _read(base / filename)
        prompts[version] = data.decode("utf-8")
        hashes[filename] = hashlib.sha256(data).hexdigest()
    for version, filename in SCHEMA_FILES.items():
        data = _read(base / filename)
        try:
            schemas[version] = decode_json_strict(data.decode("utf-8"))
        except Exception as exc:
            raise AssetError(f"schema asset is not strict JSON: {filename}") from exc
        hashes[filename] = hashlib.sha256(data).hexdigest()

    manifest_path = base / MANIFEST_NAME
    if manifest_path.exists():
        try:
            manifest = decode_json_strict(manifest_path.read_text("utf-8"))
            recorded = manifest["files"] if isinstance(manifest, dict) else None
        except Exception as exc:
            raise AssetError("asset manifest is unreadable") from exc
        if not isinstance(recorded, dict):
            raise AssetError("asset manifest is malformed")
        for filename, expected in recorded.items():
            if hashes.get(filename) != expected:
                raise AssetError(f"asset hash mismatch: {filename}")
    elif getattr(sys, "frozen", False):
        raise AssetError("packaged worker is missing its asset manifest")
    return Assets(prompts=prompts, schemas=schemas, hashes=hashes)


def load_cases() -> Any:
    """Load the synthetic prompt corpus. Test/fixture use only."""

    path = asset_dir() / CASES_FILE
    if not path.is_file():
        raise AssetError("cases.json is missing")
    try:
        return decode_json_strict(path.read_text("utf-8"))
    except Exception as exc:
        raise AssetError("cases.json is not strict JSON") from exc


def _read(path: Path) -> bytes:
    try:
        return path.read_bytes()
    except OSError as exc:
        raise AssetError(f"required asset is missing: {path.name}") from exc
