# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for the test-only fixture worker bundle (onedir).

Same protocol runtime, assets, and manifest as the release bundle, but the
entry point injects the fixture model factory. Built only by the test
workflow; never shipped inside the application's Helpers directory.
"""

import sys
from pathlib import Path

worker_dir = Path(SPECPATH).resolve().parent  # Worker/
tests_dir = worker_dir / "tests"
root = worker_dir.parent
sys.path.insert(0, str(root / "script"))
from worker_assets import worker_asset_data

a = Analysis(
    [str(tests_dir / "fixture_worker.py")],
    pathex=[str(worker_dir), str(tests_dir)],
    binaries=[],
    datas=worker_asset_data(fixture=True),
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
