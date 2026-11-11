import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "script/prepare_release_runtime.py"
spec = importlib.util.spec_from_file_location("release_runtime", SCRIPT)
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        env = patch.dict(runtime.os.environ, {"BIPARA_TARGET_ARCH": "arm64"})
        env.start()
        self.addCleanup(env.stop)
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "licenses/python-runtime").mkdir(parents=True)
        self.archive = self.root / "fixture.tar.gz"
        with tarfile.open(self.archive, "w:gz") as bundle:
            for name, body in [("lib/libpython3.13.dylib", b"qualified library"), ("bin/python3.13", b"interpreter"), ("lib/python3.13/site.py", b"unchanged source"), ("lib/python3.13/__pycache__/site.cpython-313.pyc", b"upstream bytecode")]:
                entry = tarfile.TarInfo("python/" + name)
                entry.size = len(body)
                bundle.addfile(entry, io.BytesIO(body))
        self.manifest = {"python_version": "3.13.3", "runtime_url": self.archive.as_uri(),
                         "archive_sha256": runtime.sha256(self.archive),
                         "python_library_sha256": hashlib.sha256(b"qualified library").hexdigest()}
        (self.root / "licenses/python-runtime/manifest.json").write_text(json.dumps(self.manifest))
        self.patch = patch.object(runtime, "ROOT", self.root)
        self.patch.start()

    def tearDown(self):
        self.patch.stop()
        self.temp.cleanup()

    def test_repeated_preparation_keeps_the_same_verified_interpreter(self):
        interpreter = runtime.prepare()
        self.assertTrue(interpreter.is_file())
        with patch.object(runtime, "urlopen", side_effect=AssertionError("unexpected download")):
            self.assertEqual(runtime.prepare(), interpreter)

    def test_corrupt_cached_archive_fails_without_overwrite(self):
        runtime.prepare()
        cache = self.root / "build/release-runtime/cpython.tar.gz"
        cache.write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "cached"):
            runtime.prepare()
        self.assertEqual(cache.read_bytes(), b"changed")

    def test_intel_runtime_uses_separate_manifest_and_cache(self):
        (self.root / "licenses/python-runtime/manifest-x86_64.json").write_text(json.dumps(self.manifest))
        arm = runtime.prepare()
        with patch.dict(runtime.os.environ, {"BIPARA_TARGET_ARCH": "x86_64"}):
            intel = runtime.prepare()
        self.assertNotEqual(arm, intel)
        self.assertIn("release-runtime-x86_64", str(intel))
        self.assertTrue(arm.is_file() and intel.is_file())

    def test_intel_host_selects_intel_runtime_without_override(self):
        (self.root / "licenses/python-runtime/manifest-x86_64.json").write_text(json.dumps(self.manifest))
        with patch.dict(runtime.os.environ, {}, clear=True), patch.object(runtime.platform, "machine", return_value="x86_64"):
            self.assertIn("release-runtime-x86_64", str(runtime.prepare()))

    def test_bad_download_is_not_promoted_or_left_as_a_cache_hit(self):
        with self.assertRaises(ValueError):
            runtime.download_verified(self.archive.as_uri(), "0" * 64, self.root / "cache/input")
        self.assertEqual(list((self.root / "cache").iterdir()), [])

    def test_changed_library_or_standard_library_is_rejected(self):
        runtime.prepare()
        for relative in ["lib/python3.13/site.py", "lib/libpython3.13.dylib"]:
            path = self.root / "build/release-runtime/python" / relative
            original = path.read_bytes()
            path.write_bytes(b"modified")
            with self.assertRaises(ValueError):
                runtime.prepare()
            path.write_bytes(original)

    def test_archive_path_escape_is_rejected(self):
        with tarfile.open(self.archive, "w:gz") as bundle:
            entry = tarfile.TarInfo("../outside")
            entry.size = 1
            bundle.addfile(entry, io.BytesIO(b"x"))
        self.manifest["archive_sha256"] = runtime.sha256(self.archive)
        (self.root / "licenses/python-runtime/manifest.json").write_text(json.dumps(self.manifest))
        with self.assertRaises(tarfile.TarError):
            runtime.prepare()
        self.assertFalse((self.root / "build/release-runtime/outside").exists())

    def test_interpreter_regenerated_bytecode_does_not_change_source_qualification(self):
        runtime.prepare()
        cache = self.root / "build/release-runtime/python/lib/python3.13/__pycache__/site.cpython-313.pyc"
        cache.write_bytes(b"regenerated for the installed path")
        self.assertTrue(runtime.prepare().is_file())
