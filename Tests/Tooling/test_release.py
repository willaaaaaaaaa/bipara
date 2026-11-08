import importlib.util
import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import shutil

SCRIPT = Path(__file__).resolve().parents[2] / "script/release.py"
spec = importlib.util.spec_from_file_location("release", SCRIPT)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Synthetic contributor")
        self.git("config", "user.email", "fixture@example.com")
        (self.root / "Config").mkdir()
        (self.root / "Config/Version.xcconfig").write_text("MARKETING_VERSION = 0.1.0\nCURRENT_PROJECT_VERSION = 1\n")
        self.git("add", ".")
        self.git("commit", "-qm", "chore: fixture")
        self.git("tag", "v0.1.0")
        self.commit = self.git("rev-parse", "HEAD").strip().decode()
        self.git("update-ref", "refs/remotes/origin/main", self.commit)

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], stderr=subprocess.DEVNULL)

    def test_source_requires_clean_exact_tag_and_main_ancestry(self):
        self.assertEqual(release.source("v0.1.0", self.root), ("0.1.0", "1", self.commit))
        for invalid in ("main", "v0.1.0;echo", "v0.1.0-rc.1", "v00.1.0", "v0.2.0"):
            with self.assertRaises(release.ReleaseError):
                release.source(invalid, self.root)
        (self.root / "uncommitted.txt").write_text("unexpected file")
        with self.assertRaises(release.ReleaseError):
            release.source("v0.1.0", self.root)

    def test_publication_can_verify_an_old_tag_from_trusted_newer_main(self):
        (self.root / "Config/Version.xcconfig").write_text("MARKETING_VERSION = 0.2.0\nCURRENT_PROJECT_VERSION = 2\n")
        self.git("add", ".")
        self.git("commit", "-qm", "chore: next version")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.assertEqual(release.source("v0.1.0", self.root, require_checkout=False), ("0.1.0", "1", self.commit))
        with self.assertRaises(release.ReleaseError):
            release.source("v0.1.0", self.root)

    def prepare_assets(self):
        folder = self.root / "assets"
        folder.mkdir()
        dmg, sums, manifest_name = release.assets("v0.1.0")
        (folder / dmg).write_bytes(b"synthetic disk image")
        value = {"schema": 1, "tag": "v0.1.0", "commit": self.commit, "version": "0.1.0", "build": "1", "architecture": "arm64",
                 "xcode": "Xcode fixture", "python": "Python fixture", "lock_sha256": "a" * 64,
                 "prompt_sha256": {}, "dmg_sha256": release.digest(folder / dmg)}
        (folder / manifest_name).write_text(json.dumps(value))
        (folder / sums).write_text("".join(f"{release.digest(folder / name)}  {name}\n" for name in (dmg, manifest_name)))
        return folder

    def test_asset_checks_detect_tampering_and_extra_uploads(self):
        folder = self.prepare_assets()
        release.verify_assets(folder, "v0.1.0", self.commit)
        (folder / "private.log").write_text("excluded")
        with self.assertRaises(release.ReleaseError):
            release.verify_assets(folder, "v0.1.0", self.commit)
        (folder / "private.log").unlink()
        (folder / release.assets("v0.1.0")[0]).write_bytes(b"changed")
        with self.assertRaises(release.ReleaseError):
            release.verify_assets(folder, "v0.1.0", self.commit)

    def test_publish_refuses_missing_installation_evidence_before_network(self):
        with patch.object(release, "source", return_value=("0.1.0", "1", self.commit)), patch.object(release, "command") as network:
            with self.assertRaises(release.ReleaseError):
                release.github_release("v0.1.0", publish=True, expected_sha="a" * 64, verified=["clean-install"])
            network.assert_not_called()

    def test_tool_failure_does_not_print_sensitive_output(self):
        secret = "synthetic-private-material"
        with patch.object(release.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", secret)):
            with self.assertRaises(release.ReleaseError) as failure:
                release.command("synthetic-tool", secret)
            self.assertNotIn(secret, str(failure.exception))

    def test_publish_binds_installation_declarations_to_downloaded_bytes(self):
        folder = self.prepare_assets()
        calls = []

        def fake_command(*args, **kwargs):
            calls.append(args)
            if args[:3] == ("gh", "release", "view"):
                return json.dumps({"isDraft": True, "assets": [{"name": name} for name in release.assets("v0.1.0")]})
            if args[:3] == ("gh", "release", "download"):
                target = Path(args[-1])
                for item in folder.iterdir():
                    shutil.copyfile(item, target / item.name)
            return ""

        with patch.object(release, "source", return_value=("0.1.0", "1", self.commit)), \
             patch.object(release, "command", side_effect=fake_command), \
             patch.dict(release.os.environ, {"GITHUB_REPOSITORY": "example/project"}):
            with self.assertRaises(release.ReleaseError):
                release.github_release("v0.1.0", publish=True, expected_sha="0" * 64, verified=list(release.REQUIRED_CHECKS))
            self.assertFalse(any(args[:3] == ("gh", "release", "edit") for args in calls))
            sha = release.digest(folder / release.assets("v0.1.0")[0])
            with contextlib.redirect_stdout(io.StringIO()):
                release.github_release("v0.1.0", publish=True, expected_sha=sha, verified=list(release.REQUIRED_CHECKS))
            self.assertTrue(any(args[:3] == ("xcrun", "stapler", "validate") for args in calls))
            self.assertEqual(sum(args[:3] == ("gh", "release", "edit") for args in calls), 1)


if __name__ == "__main__":
    unittest.main()
