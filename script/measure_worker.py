#!/usr/bin/env python3
"""Measure packaged worker size, startup latency, RSS, and lifetime.

Development evidence for the M0 feasibility report. Launches the packaged
bundles with a sanitized environment (no developer Python on PATH), times
hello->ready over several cold starts, samples RSS while idle and after an
operation, and verifies clean exit without orphans. Emits JSON on stdout.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RELEASE = ROOT / "build" / "worker" / "BiparaWorker.app"
FIXTURE = ROOT / "build" / "worker-fixture" / "BiparaWorkerFixture.app"

HELLO = b'{"v":2,"type":"hello"}\n'
SHUTDOWN = b'{"v":2,"type":"shutdown"}\n'
T01 = (
    b'{"v":2,"type":"request","id":"11111111-1111-4111-8111-111111111111",'
    b'"op":"translate","config":{"provider":"openai","model":"gpt-4.1-mini-2025-04-14",'
    b'"profile":"openai-json-schema-v1","base_url":"https://api.openai.com/v1/","effort":"auto"},"credentials":{"api_key":"SYNTHETIC_TEST_CREDENTIAL"},'
    b'"prompt_version":"translation.v1","input":{"source_language":"zh","target_language":"en",'
    b'"context_before":"","context_after":"","units":[{"unit_id":"22222222-2222-4222-8222-222222222222",'
    b'"kind":"sentence","text":"\xe6\x9d\x8e\xe6\x98\x8e\xe6\xb2\xa1\xe6\x9c\x89\xe7\xa1\xae\xe8\xae\xa4\xe5\x91\xa8\xe4\xba\x94\xe7\x9a\x84\xe4\xbc\x9a\xe8\xae\xae\xe3\x80\x82"}]}}\n'
)


def dir_size_mib(path: Path) -> float:
    total = 0
    for item in path.rglob("*"):
        if item.is_file():
            total += item.stat().st_size
    return round(total / (1024 * 1024), 1)


def rss_kib(pid: int) -> int:
    output = subprocess.run(
        ["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True, check=True
    ).stdout
    return int(output.strip())


def one_cold_start(executable: Path, home: Path) -> float:
    started = time.perf_counter()
    proc = subprocess.Popen(
        [str(executable)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env={"PATH": "/usr/bin:/bin", "HOME": str(home), "TMPDIR": str(home)},
        cwd=str(home),
    )
    assert proc.stdin is not None and proc.stdout is not None
    proc.stdin.write(HELLO)
    proc.stdin.flush()
    line = proc.stdout.readline()
    ready = json.loads(line)
    assert ready["type"] == "ready", ready
    latency = time.perf_counter() - started
    proc.stdin.write(SHUTDOWN)
    proc.stdin.flush()
    assert json.loads(proc.stdout.readline())["type"] == "stopped"
    proc.stdin.close()
    proc.wait(timeout=10)
    return latency


def measure_bundle(app: Path, name: str) -> dict:
    executable = app / "Contents" / "MacOS" / app.name[:-4]
    with tempfile.TemporaryDirectory(prefix="bipara-measure-") as tmp:
        home = Path(tmp)
        cold = [one_cold_start(executable, home) for _ in range(5)]

        proc = subprocess.Popen(
            [str(executable)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env={"PATH": "/usr/bin:/bin", "HOME": str(home), "TMPDIR": str(home)},
            cwd=str(home),
        )
        assert proc.stdin and proc.stdout and proc.pid
        proc.stdin.write(HELLO)
        proc.stdin.flush()
        assert json.loads(proc.stdout.readline())["type"] == "ready"
        time.sleep(0.5)
        idle_rss = rss_kib(proc.pid)
        if name == "fixture":
            # Offline fixture operation only; the release bundle's model path
            # would attempt a real provider HTTP call and stays unexercised.
            proc.stdin.write(T01)
            proc.stdin.flush()
            reply = json.loads(proc.stdout.readline())
            assert reply["type"] == "result", reply
            active_rss = rss_kib(proc.pid)
        else:
            active_rss = None
        lifetime_start = time.perf_counter()
        time.sleep(1.0)
        assert proc.poll() is None, "worker died while idle (should stay alive)"
        lifetime_alive_s = round(time.perf_counter() - lifetime_start, 2)
        proc.stdin.write(SHUTDOWN)
        proc.stdin.flush()
        assert json.loads(proc.stdout.readline())["type"] == "stopped"
        proc.stdin.close()
        exit_start = time.perf_counter()
        proc.wait(timeout=10)
        exit_s = round(time.perf_counter() - exit_start, 3)

        # Orphan check: no remaining process carrying this executable path.
        remaining = subprocess.run(
            ["pgrep", "-f", str(executable)], capture_output=True, text=True
        ).stdout.strip()

    cold_sorted = sorted(cold)
    return {
        "bundle": name,
        "size_mib": dir_size_mib(app),
        "cold_start_s": {
            "runs": [round(value, 3) for value in cold],
            "median": round(cold_sorted[len(cold) // 2], 3),
            "max": round(cold_sorted[-1], 3),
        },
        "rss_idle_kib": idle_rss,
        "rss_after_operation_kib": active_rss if active_rss is not None else "not measured offline",
        "alive_after_idle_s": lifetime_alive_s,
        "shutdown_exit_s": exit_s,
        "exit_code": proc.returncode,
        "orphan_processes_after_exit": remaining or "none",
    }


def main() -> int:
    results = []
    for app, name in ((RELEASE, "release"), (FIXTURE, "fixture")):
        if not (app / "Contents" / "MacOS").is_dir():
            print(f"measure_worker: bundle missing: {app}", file=sys.stderr)
            return 1
        results.append(measure_bundle(app, name))
    print(json.dumps({"driver_python": sys.version.split()[0], "bundles": results}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
