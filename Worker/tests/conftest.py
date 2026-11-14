"""Shared test helpers: worker process client and fixture constants."""

from __future__ import annotations

import json
import queue
import subprocess
import sys
import threading
from pathlib import Path
from typing import Any

import pytest

TESTS_DIR = Path(__file__).resolve().parent
WORKER_DIR = TESTS_DIR.parent
ROOT = WORKER_DIR.parent
for entry in (str(WORKER_DIR), str(TESTS_DIR)):
    if entry not in sys.path:
        sys.path.insert(0, entry)

from bipara_worker.protocol import decode_frame  # noqa: E402

FIXTURE_ENTRY = TESTS_DIR / "fixture_worker.py"
RELEASE_BUNDLE_DEFAULT = ROOT / "build" / "worker" / "BiparaWorker.app"
FIXTURE_BUNDLE_DEFAULT = ROOT / "build" / "worker-fixture" / "BiparaWorkerFixture.app"

# Deterministic UUIDs mapped from the short fixture IDs in prompts/cases.json.
T01_REQUEST_ID = "11111111-1111-4111-8111-111111111111"
B_ID = "55555555-5555-4555-8555-555555555555"
T01_UNIT_ID = "22222222-2222-4222-8222-222222222222"
A01_REQUEST_ID = "33333333-3333-4333-8333-333333333333"
SYNTHETIC_KEY = "SYNTHETIC_TEST_CREDENTIAL"

OPENAI_STANDARD = "https://api.openai.com/v1/"
GLM_STANDARD = "https://open.bigmodel.cn/api/paas/v4/"
GLM_CODING = "https://open.bigmodel.cn/api/coding/paas/v4/"

# The two documented protocol-v2 example configs (worker-protocol.md).
V2_OPENAI_CONFIG = {
    "provider": "openai",
    "model": "gpt-4.1-mini-2025-04-14",
    "profile": "openai-json-schema-v2",
    "base_url": OPENAI_STANDARD,
    "effort": "auto",
}
V2_GLM_CONFIG = {
    "provider": "glm",
    "model": "glm-4.7-flash",
    "profile": "glm-json-v2",
    "base_url": GLM_STANDARD,
    "effort": "off",
}


def translate_request_t01(request_id: str = T01_REQUEST_ID) -> dict[str, Any]:
    return {
        "v": 2,
        "type": "request",
        "id": request_id,
        "op": "translate",
        "config": {
            "provider": "openai",
            "model": "gpt-4.1-mini-2025-04-14",
            "profile": "openai-json-schema-v1",
            "base_url": OPENAI_STANDARD,
            "effort": "auto",
        },
        "credentials": {"api_key": SYNTHETIC_KEY},
        "prompt_version": "translation.v1",
        "input": {
            "source_language": "zh",
            "target_language": "en",
            "context_before": "",
            "context_after": "",
            "units": [
                {
                    "unit_id": T01_UNIT_ID,
                    "kind": "sentence",
                    "text": "李明没有确认周五的会议。",
                }
            ],
        },
    }


def translate_request_markdown() -> dict[str, Any]:
    """Wire-format form of the Markdown hard-break corpus case."""
    from bipara_worker.assets import load_cases

    case = next(case for case in load_cases()["cases"] if case["id"] == "M01-inline-order-and-hard-break")
    env = translate_request_t01()
    env["prompt_version"] = case["prompt_version"]
    env["input"] = case["input"]
    env["input"]["units"][0]["unit_id"] = T01_UNIT_ID
    return env


def align_request_a01(request_id: str = A01_REQUEST_ID) -> dict[str, Any]:
    return {
        "v": 2,
        "type": "request",
        "id": request_id,
        "op": "align",
        "config": {
            "provider": "glm",
            "model": "glm-4.7-flash",
            "profile": "glm-json-v1",
            "base_url": GLM_STANDARD,
            "effort": "off",
        },
        "credentials": {"api_key": SYNTHETIC_KEY},
        "prompt_version": "alignment.v1",
        "input": {
            "reading_text": "I can can fruit.",
            "counterpart_text": "我会把水果装罐。",
            "selection": {"before": "I can ", "text": "can", "after": " fruit."},
        },
    }


def sanitized_env(home: Path) -> dict[str, str]:
    """Environment with no developer Python, uv, proxy, or credentials."""

    return {"PATH": "/usr/bin:/bin", "HOME": str(home), "TMPDIR": str(home)}


class WorkerClient:
    """Synchronous line-framed client for one worker process."""

    def __init__(
        self,
        argv: list[str],
        *,
        env: dict[str, str] | None = None,
        cwd: Path | None = None,
    ) -> None:
        self.argv = argv
        self.proc = subprocess.Popen(
            [str(a) for a in argv],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            cwd=str(cwd) if cwd else None,
        )
        self._lines: queue.Queue[bytes | None] = queue.Queue()
        self._stderr_chunks: list[bytes] = []
        self._stdout_thread = threading.Thread(target=self._read_stdout, daemon=True)
        self._stderr_thread = threading.Thread(target=self._read_stderr, daemon=True)
        self._stdout_thread.start()
        self._stderr_thread.start()

    def _read_stdout(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            self._lines.put(line)
        self._lines.put(None)

    def _read_stderr(self) -> None:
        assert self.proc.stderr is not None
        for chunk in iter(lambda: self.proc.stderr.read(4096), b""):
            self._stderr_chunks.append(chunk)

    def send(self, envelope: dict[str, Any]) -> None:
        assert self.proc.stdin is not None
        frame = json.dumps(envelope, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.proc.stdin.write(frame + b"\n")
        self.proc.stdin.flush()

    def send_raw(self, data: bytes) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(data)
        self.proc.stdin.flush()

    def recv(self, timeout: float = 5.0) -> dict[str, Any]:
        line = self._lines.get(timeout=timeout)
        if line is None:
            raise AssertionError("worker stdout closed before the expected frame")
        # decode_frame is strict: this doubles as the stdout-purity check.
        return decode_frame(line)

    def assert_no_frame(self, timeout: float = 0.5) -> None:
        try:
            line = self._lines.get(timeout=timeout)
        except queue.Empty:
            return
        if line is None:
            if self.proc.poll() is None:
                raise AssertionError("worker stdout closed while the process is still running")
            return
        raise AssertionError(f"unexpected extra frame: {line!r}")

    def close_stdin(self) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.close()

    def wait(self, timeout: float = 5.0) -> int:
        return self.proc.wait(timeout=timeout)

    def stderr_bytes(self) -> bytes:
        return b"".join(self._stderr_chunks)

    def shutdown(self) -> None:
        """Ensure the process never outlives the test (no orphans)."""

        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait(timeout=10)
        self._stdout_thread.join(timeout=5)
        self._stderr_thread.join(timeout=5)


@pytest.fixture
def dev_fixture_worker(tmp_path: Path):
    """Launch the fixture worker entry with the project virtualenv Python."""

    def launch(*args: str, env: dict[str, str] | None = None, cwd: Path | None = None):
        client = WorkerClient(
            [sys.executable, str(FIXTURE_ENTRY), *args], env=env, cwd=cwd or tmp_path
        )
        return client

    return launch
