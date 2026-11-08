#!/usr/bin/env python3
"""Collect dependency attribution and complete license files into build output."""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata as metadata
import json
import os
from pathlib import Path
import shutil
import sys
import sysconfig
import tomllib

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name

ROOT = Path(__file__).resolve().parents[1]


def runtime_names() -> set[str]:
    dependencies = tomllib.loads((ROOT / "Worker/pyproject.toml").read_text())["project"]["dependencies"]
    pending = []
    for value in dependencies:
        requirement = Requirement(value)
        if not requirement.marker or requirement.marker.evaluate({"extra": ""}):
            pending.append((requirement.name, requirement.extras))
    names = set()
    visited = set()
    while pending:
        raw_name, extras = pending.pop()
        name = canonicalize_name(raw_name)
        identity = (name, tuple(sorted(extras)))
        if identity in visited:
            continue
        visited.add(identity)
        names.add(name)
        for value in metadata.distribution(name).requires or []:
            requirement = Requirement(value)
            if requirement.marker and not any(requirement.marker.evaluate({"extra": extra}) for extra in extras | {""}):
                continue
            pending.append((requirement.name, requirement.extras))
    return names


def collect(destination: Path) -> list[dict]:
    runtime = runtime_names()
    records = []
    for dist in sorted(metadata.distributions(), key=lambda value: value.metadata["Name"].lower()):
        name = dist.metadata["Name"]
        if canonicalize_name(name) == "bipara-worker":
            continue
        files = []
        for entry in dist.files or []:
            if "licenses" not in entry.parts and not entry.name.lower().startswith(("license", "copying", "notice")):
                continue
            original = Path(dist.locate_file(entry))
            if not original.is_file():
                continue
            relative = Path(canonicalize_name(name)) / Path(*entry.parts)
            target = destination / relative
            if not target.resolve().is_relative_to(destination):
                raise ValueError(f"invalid license path for {name}")
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original, target)
            files.append(relative.as_posix())
        role = "runtime" if canonicalize_name(name) in runtime else "development/build"
        if role == "runtime" and not files:
            raise ValueError(f"license text missing for runtime dependency: {name}")
        records.append({"name": name, "version": dist.version, "role": role,
                        "license": dist.metadata.get("License-Expression") or dist.metadata.get("License") or "See supplied license files",
                        "files": files})
    python_license = Path(sys.base_prefix) / f"lib/python{sys.version_info.major}.{sys.version_info.minor}/LICENSE.txt"
    if not python_license.is_file():
        python_license = Path(sys.base_prefix) / "LICENSE.txt"
    if not python_license.is_file():
        raise ValueError("CPython license text is unavailable")
    target = destination / "CPython/LICENSE.txt"
    target.parent.mkdir(parents=True)
    shutil.copyfile(python_license, target)
    records.append({"name": "CPython", "version": sys.version.split()[0], "role": "runtime",
                    "license": "PSF and included component licenses", "files": ["CPython/LICENSE.txt"]})
    provenance = ROOT / "licenses/python-runtime"
    manifest = json.loads((provenance / "manifest.json").read_text())
    library = Path(sys.base_prefix) / f"lib/libpython{sys.version_info.major}.{sys.version_info.minor}.dylib"
    matched = library.is_file() and hashlib.sha256(library.read_bytes()).hexdigest() == manifest["python_library_sha256"]
    if os.environ.get("BIPARA_RELEASE_BUILD") == "1" and not matched:
        raise ValueError("formal builds require the qualified managed Python runtime fingerprint")
    if matched:
        for name, expected in manifest["license_sha256"].items():
            if hashlib.sha256((provenance / name).read_bytes()).hexdigest() != expected:
                raise ValueError("upstream runtime license fingerprint mismatch")
        shutil.copytree(provenance, destination / "PythonRuntime")
        records.append({"name": "Python runtime component notices", "version": manifest["upstream_build"],
                        "role": "runtime", "license": "Conservative upstream component inventory; see supplied terms",
                        "files": ["PythonRuntime/" + name for name in manifest["license_sha256"]]})
    return records


def collect_native(binaries: list, destination: Path) -> None:
    """Attach notices for external dylibs actually collected by PyInstaller."""
    records = json.loads((destination / "inventory.json").read_text())
    managed = (destination / "PythonRuntime/manifest.json").is_file()
    purelib = Path(sysconfig.get_paths()["purelib"]).resolve()
    seen = set()
    for name, original, kind in binaries:
        if kind != "BINARY" or not name.endswith(".dylib") or Path(name).name.startswith("libpython"):
            continue
        source = Path(original).resolve()
        if source.is_relative_to(purelib):
            continue  # Wheel-supplied attribution was collected from dist-info.
        package = next((parent for parent in source.parents if parent.parent.parent.name == "Cellar"), None)
        if package is None:
            if managed and source.is_relative_to(Path(sys.base_prefix).resolve()):
                continue  # Covered by the exact upstream runtime's component notices.
            raise ValueError("native dependency has no qualified license source: " + Path(name).name)
        if package in seen:
            continue
        seen.add(package)
        files = []
        for candidate in package.rglob("*"):
            lower = candidate.name.lower()
            if not candidate.is_file() or not (lower.startswith(("license", "copying", "copyright")) or lower in {"notice", "notice.txt"}):
                continue
            relative = Path("native") / package.parent.name / package.name / candidate.relative_to(package)
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(candidate, target)
            files.append(relative.as_posix())
        if not files:
            raise ValueError("native dependency license text is missing: " + package.parent.name)
        records.append({"name": package.parent.name, "version": package.name, "role": "runtime",
                        "license": "See collected native component terms", "files": files})
    write_inventory(destination, records)


def write_inventory(destination: Path, records: list[dict]) -> None:
    lines = ["# Third-party licenses", "",
             "Runtime dependencies and build-environment packages are identified separately.",
             "Additional package/upstream notices are supplied conservatively; their presence does not claim that every component ships in the application.",
             "License collection supports distribution review; it does not establish legal compatibility.", ""]
    for record in records:
        lines.append(f"- **{record['name']}** {record['version']} ({record['role']}): {record['license']}")
        lines.extend(f"  - [{Path(name).name}]({name})" for name in record["files"])
    (destination / "README.md").write_text("\n".join(lines) + "\n")
    (destination / "inventory.json").write_text(json.dumps(records, indent=2) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "build/third-party")
    args = parser.parse_args()
    destination = args.out.resolve()
    if not destination.is_relative_to(ROOT / "build"):
        parser.error("license output must remain under ignored build/")
    shutil.rmtree(destination, ignore_errors=True)
    destination.mkdir(parents=True)
    try:
        records = collect(destination)
    except (ValueError, metadata.PackageNotFoundError) as error:
        print(f"licenses: {error}", file=sys.stderr)
        return 1
    write_inventory(destination, records)
    print(f"licenses: collected notices for {len(records)} components")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
