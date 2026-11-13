# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for the test-only fixture worker bundle (onedir).

Same protocol runtime, assets, and manifest as the release bundle, but the
entry point injects the fixture model factory. Built only by the test
workflow; never shipped inside the application's Helpers directory.
"""

import hashlib
import json
import atexit
import shutil
import tempfile
from pathlib import Path

worker_dir = Path(SPECPATH).resolve().parent  # Worker/
tests_dir = worker_dir / "tests"
root = worker_dir.parent
prompts_dir = root / "prompts"

asset_names = [
    "translation.v1.txt",
    "translation.v2.txt",
    "translation.markdown.v1.txt",
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

staging = Path(tempfile.mkdtemp(prefix="bipara-fixture-assets-"))
atexit.register(shutil.rmtree, staging, True)
for name in asset_names + ["cases.json"]:
    shutil.copyfile(prompts_dir / name, staging / name)
(staging / "asset_manifest.json").write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)

datas = [
    (str(staging / name), "prompts")
    for name in asset_names + ["cases.json", "asset_manifest.json"]
]

a = Analysis(
    [str(tests_dir / "fixture_worker.py")],
    pathex=[str(worker_dir), str(tests_dir)],
    binaries=[],
    datas=datas,
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="BiparaWorkerFixture",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    disable_windowed_traceback=False,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    name="BiparaWorkerFixture",
)

app = BUNDLE(
    coll,
    name="BiparaWorkerFixture.app",
    info_plist={
        "CFBundleDisplayName": "BiparaWorkerFixture",
        "CFBundleIdentifier": "dev.bipara.BiparaWorkerFixture",
        "CFBundleName": "BiparaWorkerFixture",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "CFBundlePackageType": "APPL",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
    },
)
