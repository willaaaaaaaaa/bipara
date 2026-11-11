"""Exercise Intel build entry points without executing Intel code or building apps."""

import hashlib
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("check_tools", ROOT / "script/install_check_tools.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class BuildArchitectureTests(unittest.TestCase):
    def test_intel_tool_installation_uses_pinned_archives_and_reuses_cache(self):
        archives = {}
        tools = {}
        for name, (repo, version, platforms) in installer.TOOLS.items():
            archive_platform, pinned = platforms["Darwin-x86_64"]
            self.assertRegex(pinned, r"^[a-f0-9]{64}$")
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode="w:gz") as package:
                body = f"synthetic {name}".encode()
                entry = tarfile.TarInfo(name)
                entry.size = len(body)
                package.addfile(entry, io.BytesIO(body))
            archive = buffer.getvalue()
            url = f"https://github.com/{repo}/releases/download/v{version}/{name}_{version}_{archive_platform}.tar.gz"
            archives[url] = archive
            tools[name] = (repo, version, {"Darwin-x86_64": (archive_platform, hashlib.sha256(archive).hexdigest())})
        with tempfile.TemporaryDirectory() as temp, patch.object(installer, "TOOLS", tools), \
             patch.object(installer.platform, "system", return_value="Darwin"), patch.object(installer.platform, "machine", return_value="x86_64"), \
             patch.object(installer, "urlopen", side_effect=lambda url, **kw: io.BytesIO(archives[url])) as download:
            installer.install(Path(temp))
            self.assertEqual(download.call_count, len(tools))
            for name in tools:
                self.assertEqual((Path(temp) / name).read_text(), f"synthetic {name}")
            installer.install(Path(temp))
            self.assertEqual(download.call_count, len(tools))

    def test_worker_defaults_to_intel_host_before_environment_sync(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "script").mkdir()
            shutil.copy2(ROOT / "script/build_worker.sh", root / "script/build_worker.sh")
            commands = root / "bin"
            commands.mkdir()
            for name, body in {"uname": "echo x86_64", "uv": 'echo "target=$BIPARA_TARGET_ARCH"; exit 42'}.items():
                path = commands / name
                path.write_text("#!/bin/sh\n" + body + "\n")
                path.chmod(0o700)
            env = {k: v for k, v in os.environ.items() if not k.startswith("BIPARA_")}
            env["PATH"] = str(commands) + os.pathsep + env["PATH"]
            result = subprocess.run(["bash", str(root / "script/build_worker.sh")], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 42, result.stderr)
            self.assertIn("target=x86_64", result.stdout)
            env["BIPARA_TARGET_ARCH"] = "arm64"
            result = subprocess.run(["bash", str(root / "script/build_worker.sh")], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertNotIn("Syncing", result.stdout)


if __name__ == "__main__":
    unittest.main()
