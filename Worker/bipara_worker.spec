# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for the release BiparaWorker.app (onedir).

Prompt/schema assets are copied byte-for-byte from the canonical
repository ``prompts/`` directory and recorded in an ``asset_manifest.json``
that the worker verifies before reporting ready. The fixture-only entry
point is deliberately absent from this bundle.
"""

import hashlib
import json
import atexit
import shutil
import tempfile
import os
import re
import sys
from pathlib import Path

worker_dir = Path(SPECPATH).resolve()
root = worker_dir.parent
prompts_dir = root / "prompts"

asset_names = [
    "translation.v1.txt",
    "translation.v2.txt",
    "alignment.v1.txt",
    "translation-output.v1.schema.json",
    "alignment-output.v1.schema.json",
]
manifest = {
    "files": {
        name: hashlib.sha256((prompts_dir / name).read_bytes()).hexdigest()
        for name in asset_names
    }
}

staging = Path(tempfile.mkdtemp(prefix="bipara-worker-assets-"))
atexit.register(shutil.rmtree, staging, True)
for name in asset_names:
    shutil.copyfile(prompts_dir / name, staging / name)
(staging / "asset_manifest.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)

datas = [(str(staging / name), "prompts") for name in asset_names + ["asset_manifest.json"]]
licenses = root / "build" / "third-party"
if not (licenses / "README.md").is_file():
    raise RuntimeError("Generate dependency licenses before packaging")
datas.append((str(licenses), "ThirdPartyLicenses"))
version_text = (root / "Config" / "Version.xcconfig").read_text()
app_version = re.search(r"^MARKETING_VERSION\s*=\s*(\S+)", version_text, re.M).group(1)
build_number = re.search(r"^CURRENT_PROJECT_VERSION\s*=\s*(\S+)", version_text, re.M).group(1)

a = Analysis(
    [str(worker_dir / "worker_entry.py")],
    pathex=[str(worker_dir)],
    binaries=[],
    datas=datas,
    hiddenimports=["langchain_core", "langchain_openai", "httpx", "pydantic"],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)
sys.path.insert(0, str(root / "script"))
from generate_notices import collect_native
collect_native(a.binaries, licenses)
known_data = {name for name, _, _ in a.datas}
for notice in licenses.rglob("*"):
    if notice.is_file():
        name = "ThirdPartyLicenses/" + notice.relative_to(licenses).as_posix()
        if name not in known_data:
            a.datas.append((name, str(notice), "DATA"))
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="BiparaWorker",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    disable_windowed_traceback=False,
    codesign_identity=os.environ.get("BIPARA_CODESIGN_IDENTITY"),
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    name="BiparaWorker",
)

app = BUNDLE(
    coll,
    name="BiparaWorker.app",
    info_plist={
        "CFBundleDisplayName": "BiparaWorker",
        "CFBundleIdentifier": "dev.bipara.BiparaWorker",
        "CFBundleName": "BiparaWorker",
        "CFBundleShortVersionString": app_version,
        "CFBundleVersion": build_number,
        "CFBundlePackageType": "APPL",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
    },
)
