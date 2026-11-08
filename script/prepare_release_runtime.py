#!/usr/bin/env python3
"""Print the interpreter path from the checksum-pinned upstream release archive."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
if sys.version_info < (3, 12):
    raise SystemExit("release-runtime: Python 3.12 or newer is required for safe archive extraction")


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def download_verified(url: str, expected: str, destination: Path) -> None:
    """Reuse only verified bytes; never keep an incomplete download as a cache hit."""
    if destination.exists():
        if sha256(destination) != expected:
            raise ValueError("cached release input checksum mismatch")
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            with urlopen(Request(url, headers={"User-Agent": "Bipara-release-inputs/1"}), timeout=60) as response:
                shutil.copyfileobj(response, stream)
            stream.close()
            if sha256(temporary) != expected:
                raise ValueError("downloaded release input checksum mismatch")
            temporary.replace(destination)
        finally:
            temporary.unlink(missing_ok=True)


def verify_runtime(prefix: Path, manifest: dict) -> None:
    library = prefix / f"lib/libpython{'.'.join(manifest['python_version'].split('.')[:2])}.dylib"
    if not library.is_file() or sha256(library) != manifest["python_library_sha256"]:
        raise ValueError("formal builds require the unchanged qualified Python library")


def verify_extracted(archive: Path, prefix: Path) -> None:
    with tarfile.open(archive) as bundle:
        for entry in bundle:
            # CPython regenerates installation-specific bytecode on first use.
            if entry.name.endswith(".pyc"):
                continue
            path = prefix / Path(entry.name).relative_to("python")
            if entry.isfile() or entry.islnk():
                if not path.is_file() or sha256(path) != hashlib.file_digest(bundle.extractfile(entry), "sha256").hexdigest():
                    raise ValueError("extracted Python file differs from the pinned archive")
            elif entry.issym() and (not path.is_symlink() or path.readlink().as_posix() != entry.linkname):
                raise ValueError("extracted Python symlink differs from the pinned archive")


def prepare() -> Path:
    manifest = json.loads((ROOT / "licenses/python-runtime/manifest.json").read_text())
    cache = ROOT / "build/release-runtime"
    archive = cache / "cpython.tar.gz"
    download_verified(manifest["runtime_url"], manifest["archive_sha256"], archive)
    runtime = cache / "python"
    if not runtime.exists():
        with tempfile.TemporaryDirectory(dir=cache) as temporary:
            with tarfile.open(archive) as bundle:
                bundle.extractall(temporary, filter="data")
            extracted = Path(temporary) / "python"
            verify_runtime(extracted, manifest)
            extracted.rename(runtime)
    verify_runtime(runtime, manifest)
    verify_extracted(archive, runtime)
    return runtime / "bin/python3.13"


if __name__ == "__main__":
    try:
        print(prepare())
    except (OSError, ValueError, tarfile.TarError):
        print("release-runtime: preparation failed; verify pinned inputs and network access", file=sys.stderr)
        sys.exit(1)
