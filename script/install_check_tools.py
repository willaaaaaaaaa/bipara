#!/usr/bin/env python3
"""Install checksum-pinned public-content tools in an external cache."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import subprocess
import tarfile
from urllib.request import urlopen

TOOLS = {
    "gitleaks": ("gitleaks/gitleaks", "8.30.1", {
        "Darwin-arm64": ("darwin_arm64", "b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5"),
        "Darwin-x86_64": ("darwin_x64", "dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709"),
        "Linux-x86_64": ("linux_x64", "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb"),
    }),
    "actionlint": ("rhysd/actionlint", "1.7.12", {
        "Darwin-arm64": ("darwin_arm64", "aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f"),
        "Darwin-x86_64": ("darwin_amd64", "5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644"),
        "Linux-x86_64": ("linux_amd64", "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8"),
    }),
}


def tool_directory(root: Path) -> Path:
    value = os.environ.get("BIPARA_CHECK_TOOLS_DIR")
    if not value:
        result = subprocess.run(["git", "-C", str(root), "config", "--local", "--get", "bipara.checkToolsDirectory"], capture_output=True, text=True)
        value = result.stdout.strip()
    path = Path(value).expanduser().resolve() if value else Path.home() / ".cache/bipara/check-tools"
    if path.is_relative_to(root.resolve()):
        raise ValueError("check tools must be outside the checkout")
    return path


def install(destination: Path) -> None:
    target = f"{platform.system()}-{platform.machine()}"
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    for name, (repo, version, platforms) in TOOLS.items():
        if target not in platforms or not platforms[target][1]:
            raise ValueError("this host has no pinned check-tool archive")
        archive_platform, checksum = platforms[target]
        receipt = destination / f"{name}.json"
        binary = destination / name
        if receipt.is_file() and binary.is_file():
            saved = json.loads(receipt.read_text())
            if saved.get("archive_sha256") == checksum and saved.get("binary_sha256") == hashlib.sha256(binary.read_bytes()).hexdigest():
                continue
        url = f"https://github.com/{repo}/releases/download/v{version}/{name}_{version}_{archive_platform}.tar.gz"
        with urlopen(url, timeout=60) as response:
            archive = response.read()
        if hashlib.sha256(archive).hexdigest() != checksum:
            raise ValueError("check-tool archive checksum mismatch")
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as package:
            member = package.getmember(name)
            if not member.isfile():
                raise ValueError("invalid check-tool archive")
            data = package.extractfile(member).read()
        temporary = destination / f".{name}.tmp"
        temporary.write_bytes(data)
        temporary.chmod(0o700)
        temporary.replace(binary)
        receipt.write_text(json.dumps({"version": version, "archive_sha256": checksum,
                                       "binary_sha256": hashlib.sha256(data).hexdigest()}) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dest", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    destination = args.dest.expanduser().resolve() if args.dest else tool_directory(root)
    if destination.is_relative_to(root):
        parser.error("check tools must be outside the checkout")
    try:
        install(destination)
    except (OSError, ValueError, KeyError, tarfile.TarError):
        raise SystemExit("check-tools: installation failed; check network and external cache configuration")
    print("check-tools: pinned tools are ready")


if __name__ == "__main__":
    main()
