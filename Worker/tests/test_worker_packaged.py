"""Packaged-bundle tests: real PyInstaller builds over pipes, offline.

The release bundle is exercised for handshake and asset verification only
(its model path would need credentials/network). The fixture bundle adds
the framed-operation, cancellation, and lifecycle checks. Bundles are
skipped with an explicit reason when they have not been built yet so the
default suite stays usable without a package build.
"""

from __future__ import annotations

import os
import plistlib
import shutil
import time
import uuid
from pathlib import Path

import pytest

from conftest import (
    FIXTURE_BUNDLE_DEFAULT,
    RELEASE_BUNDLE_DEFAULT,
    ROOT,
    T01_REQUEST_ID,
    WorkerClient,
    align_request_a01,
    sanitized_env,
    translate_request_t01,
)


def _bundle_executable(bundle_dir: Path, env_var: str) -> Path | None:
    override = os.environ.get(env_var)
    if override:
        return Path(override)
    name = bundle_dir.name[:-4] if bundle_dir.name.endswith(".app") else bundle_dir.name
    candidate = bundle_dir / "Contents" / "MacOS" / name
    return candidate if candidate.exists() else None


@pytest.fixture(scope="module")
def release_executable() -> Path:
    path = _bundle_executable(RELEASE_BUNDLE_DEFAULT, "BIPARA_RELEASE_WORKER")
    if path is None:
        pytest.skip("release worker bundle not built; run script/build_worker.sh first")
    return path


@pytest.fixture(scope="module")
def fixture_executable() -> Path:
    path = _bundle_executable(FIXTURE_BUNDLE_DEFAULT, "BIPARA_FIXTURE_WORKER")
    if path is None:
        pytest.skip("fixture worker bundle not built; run script/build_worker.sh first")
    return path


def _handshake(client: WorkerClient) -> dict:
    client.send({"v": 2, "type": "hello"})
    ready = client.recv(timeout=10.0)
    assert ready["type"] == "ready"
    assert ready["v"] == 2
    assert ready["max_inflight"] == 4
    assert ready["prompt_versions"] == ["translation.v1", "translation.v2", "alignment.v1"]
    return ready


class TestReleaseBundle:
    def test_component_licenses_are_present_and_complete(self, release_executable):
        import json

        directory = release_executable.parent.parent / "Resources/ThirdPartyLicenses"
        records = json.loads((directory / "inventory.json").read_text())
        assert any(row["name"] == "CPython" for row in records)
        assert any(row["name"] == "openai" and row["role"] == "runtime" for row in records)
        for row in records:
            if row["role"] == "runtime":
                assert row["files"], row["name"]
            for name in row["files"]:
                path = directory / name
                assert path.is_file() and path.stat().st_size > 0, name

    def test_handshake_and_asset_verification(self, release_executable, tmp_path):
        client = WorkerClient(
            [str(release_executable)], env=sanitized_env(tmp_path), cwd=tmp_path
        )
        try:
            ready = _handshake(client)
            assert ready["worker_version"] == "0.1.0"
            client.assert_no_frame()
        finally:
            client.shutdown()

    def test_pre_hello_eof_emits_stopped_without_ready(self, release_executable, tmp_path):
        client = WorkerClient(
            [str(release_executable)], env=sanitized_env(tmp_path), cwd=tmp_path
        )
        try:
            client.close_stdin()
            # Q1 through the packaged release executable: EOF before hello
            # performs normal cleanup and emits exactly one stopped; ready
            # is never fabricated and no provider call is possible.
            assert client.recv(timeout=10.0) == {"v": 2, "type": "stopped"}
            assert client.wait(timeout=5.0) == 0
            client.assert_no_frame(0.3)
        finally:
            client.shutdown()

    def test_bundle_asset_bytes_match_canonical_hashes(self, release_executable):
        import hashlib

        frameworks = release_executable.parent.parent / "Frameworks"
        manifest_path = frameworks / "prompts" / "asset_manifest.json"
        assert manifest_path.is_file(), "asset manifest missing from bundle"
        import json

        manifest = json.loads(manifest_path.read_text("utf-8"))
        for name, expected in manifest["files"].items():
            bundled = hashlib.sha256((frameworks / "prompts" / name).read_bytes()).hexdigest()
            assert bundled == expected, name
            canonical = hashlib.sha256((ROOT / "prompts" / name).read_bytes()).hexdigest()
            assert bundled == canonical, f"{name} differs from the canonical asset"

    def test_helper_plist_is_ui_element(self, release_executable):
        plist_path = release_executable.parent.parent / "Info.plist"
        info = plistlib.loads(plist_path.read_bytes())
        assert info["CFBundleIdentifier"] == "dev.bipara.BiparaWorker"
        assert info["LSUIElement"] is True  # no Dock icon for the helper

    def test_no_developer_python_dependency_in_bundle(self, release_executable):
        import subprocess

        # The main executable must not link against a developer Python.
        output = subprocess.run(
            ["otool", "-L", str(release_executable)],
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        assert "/opt/homebrew" not in output
        assert "Python.framework" not in output

        # Text assets inside the bundle must not embed repository paths.
        bundle_root = release_executable.parent.parent
        forbidden = str(ROOT).encode()
        for path in bundle_root.rglob("*"):
            if path.is_file() and path.suffix in {".py", ".plist", ".json"}:
                assert forbidden not in path.read_bytes(), f"repo path leaked into {path.name}"


class TestFixtureBundle:
    def test_one_framed_fixture_reply(self, fixture_executable, tmp_path):
        client = WorkerClient(
            [str(fixture_executable)], env=sanitized_env(tmp_path), cwd=tmp_path
        )
        try:
            _handshake(client)
            client.send(translate_request_t01())
            result = client.recv(timeout=10.0)
            assert result["type"] == "result"
            assert result["id"] == T01_REQUEST_ID
            assert result["data"]["translations"][0]["text"] == (
                "Li Ming has not confirmed Friday's meeting."
            )
            client.assert_no_frame()
        finally:
            client.shutdown()

    def test_cooperative_cancellation(self, fixture_executable, tmp_path):
        # The fixture entry supports test-only argument injection.
        client = WorkerClient(
            [str(fixture_executable), "--delay", "5"], env=sanitized_env(tmp_path), cwd=tmp_path
        )
        try:
            _handshake(client)
            client.send(translate_request_t01())
            time.sleep(0.3)
            client.send({"v": 2, "type": "cancel", "id": T01_REQUEST_ID})
            cancelled = client.recv(timeout=3.0)
            assert cancelled == {"v": 2, "type": "cancelled", "id": T01_REQUEST_ID}
        finally:
            client.shutdown()

    def test_shutdown_and_eof_quit_cleanly(self, fixture_executable, tmp_path):
        client = WorkerClient(
            [str(fixture_executable)], env=sanitized_env(tmp_path), cwd=tmp_path
        )
        try:
            _handshake(client)
            client.send({"v": 2, "type": "shutdown"})
            assert client.recv(timeout=5.0) == {"v": 2, "type": "stopped"}
            assert client.wait(timeout=5.0) == 0
        finally:
            client.shutdown()

        client2 = WorkerClient(
            [str(fixture_executable)], env=sanitized_env(tmp_path), cwd=tmp_path
        )
        try:
            _handshake(client2)
            client2.close_stdin()
            # Q1: normal EOF emits exactly one stopped through the packaged
            # executable; no additional frame follows.
            assert client2.recv(timeout=5.0) == {"v": 2, "type": "stopped"}
            assert client2.wait(timeout=5.0) == 0
            client2.assert_no_frame(0.3)
        finally:
            client2.shutdown()

    def test_pre_hello_eof_emits_stopped_fixture(self, fixture_executable, tmp_path):
        client = WorkerClient(
            [str(fixture_executable)], env=sanitized_env(tmp_path), cwd=tmp_path
        )
        try:
            client.close_stdin()
            # Exactly one stopped; no ready, fatal, or duplicate stopped.
            assert client.recv(timeout=10.0) == {"v": 2, "type": "stopped"}
            assert client.wait(timeout=5.0) == 0
            client.assert_no_frame(0.3)
        finally:
            client.shutdown()

    def test_worker_stays_alive_between_operations(self, fixture_executable, tmp_path):
        client = WorkerClient(
            [str(fixture_executable)], env=sanitized_env(tmp_path), cwd=tmp_path
        )
        try:
            _handshake(client)
            for _ in range(3):
                time.sleep(0.2)
                assert client.proc.poll() is None
            client.send(translate_request_t01(str(uuid.uuid4())))
            assert client.recv(timeout=10.0)["type"] == "result"
            assert client.proc.poll() is None  # long-lived worker, not one-shot
        finally:
            client.shutdown()


class TestCopiedBundle:
    """PKG-01 copied-development-bundle portion: path with spaces, no dev PATH."""

    def test_copied_fixture_bundle_runs_without_developer_python(self, fixture_executable, tmp_path):
        copy_root = tmp_path / "Copied Bipara Bundle"  # path contains a space
        copy_root.mkdir()
        copied = copy_root / "BiparaWorkerFixture.app"
        shutil.copytree(fixture_executable.parents[2], copied)

        exe = copied / "Contents" / "MacOS" / "BiparaWorkerFixture"
        assert exe.is_file()
        env = sanitized_env(tmp_path / "home")
        env["PATH"] = "/usr/bin:/bin"  # no homebrew, no uv, no venv
        client = WorkerClient([str(exe)], env=env, cwd=copy_root)
        try:
            _handshake(client)
            client.send(align_request_a01(str(uuid.uuid4())))
            result = client.recv(timeout=10.0)
            assert result["type"] == "result"
            assert result["data"]["status"] == "matched"
        finally:
            client.shutdown()

    def test_copied_release_bundle_handshake(self, release_executable, tmp_path):
        copy_root = tmp_path / "Copied Release Bundle"
        copy_root.mkdir()
        copied = copy_root / "BiparaWorker.app"
        shutil.copytree(release_executable.parents[2], copied)
        exe = copied / "Contents" / "MacOS" / "BiparaWorker"
        client = WorkerClient([str(exe)], env=sanitized_env(tmp_path), cwd=copy_root)
        try:
            _handshake(client)
        finally:
            client.shutdown()
