import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[2]


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="bipara-setup-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.root = self.base / "checkout"
        (self.root / "script").mkdir(parents=True)
        self.env = {key: value for key, value in os.environ.items() if not key.startswith(("BIPARA_", "GIT_"))}
        self.env.update(GIT_CONFIG_GLOBAL=str(self.base / "global.gitconfig"), GIT_CONFIG_NOSYSTEM="1",
                        BIPARA_CHECK_TOOLS_DIR=str(self.base / "tools"))
        self.git("init", "-q")
        (self.root / ".gitignore").write_text("/.local/\n")
        for name in ("setup.sh", "check_public_content.py", "install_check_tools.py"):
            shutil.copy2(PROJECT / "script" / name, self.root / "script" / name)
        # Exercise the real path selection without downloading tools in fixtures.
        installer = self.root / "script/install_check_tools.py"
        installer.write_text(installer.read_text().replace(
            "        install(destination)", "        (root / '.installer-ran').write_text('called')"))

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], env=self.env, stderr=subprocess.DEVNULL).decode().strip()

    def run_setup(self, *args):
        return subprocess.run([str(self.root / "script/setup.sh"), *map(str, args)], cwd=self.base,
                              env=self.env, capture_output=True, text=True)

    def rules(self, name="custom rules.json"):
        path = self.base / name
        path.write_text(json.dumps({"literals": ["synthetic-private-phrase"]}) + "\n")
        path.chmod(0o640)
        return path

    def assert_preflight_failure(self, *args):
        before = self.git("config", "--local", "--list")
        result = self.run_setup(*args)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("config", "--local", "--list"), before)
        self.assertFalse((self.root / ".local").exists())
        self.assertFalse((self.root / ".installer-ran").exists())
        return result

    def test_fresh_setup_is_repeatable_without_private_storage(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("config", "--local", "--get", "core.hooksPath"), ".githooks")
        self.assertEqual(self.git("config", "--local", "--get", "bipara.checkToolsDirectory"), str(self.base / "tools"))
        config = self.git("config", "--local", "--list")
        self.assertNotIn("bipara.private", config)
        self.assertTrue((self.root / ".local/validation").is_dir())
        self.assertEqual(self.run_setup().returncode, 0)
        self.assertEqual(self.git("config", "--local", "--list"), config)

    def test_existing_rules_and_directory_permissions_are_preserved(self):
        rules = self.rules()
        self.git("config", "--local", "bipara.privatePatternsFile", str(rules))
        self.git("config", "--local", "bipara.privateDirectory", str(self.base))
        before = (rules.read_bytes(), stat.S_IMODE(rules.stat().st_mode), stat.S_IMODE(self.base.stat().st_mode))
        for _ in range(2):
            result = self.run_setup()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.git("config", "--local", "--get", "bipara.privatePatternsFile"), str(rules))
            self.assertEqual((rules.read_bytes(), stat.S_IMODE(rules.stat().st_mode), stat.S_IMODE(self.base.stat().st_mode)), before)
        self.assertFalse((self.base / "public-content-patterns.json").exists())

    def test_explicit_file_can_replace_selection_without_modifying_files(self):
        old = self.rules("old.json")
        new = self.rules()
        self.git("config", "--local", "bipara.privatePatternsFile", str(old))
        before = old.read_bytes(), new.read_bytes()
        result = self.run_setup("--private-patterns-file", new)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("config", "--local", "--get", "bipara.privatePatternsFile"), str(new))
        self.assertEqual((old.read_bytes(), new.read_bytes()), before)

    def test_missing_configured_file_is_not_recreated_or_cleared(self):
        missing = self.base / "missing.json"
        self.git("config", "--local", "bipara.privatePatternsFile", str(missing))
        self.assert_preflight_failure()
        self.assertFalse(missing.exists())

    def test_custom_local_and_global_hooks_stop_before_writes(self):
        for scope in ("--local", "--global"):
            with self.subTest(scope=scope):
                self.git("config", scope, "core.hooksPath", str(self.base / "custom-hooks"))
                self.assert_preflight_failure()
                self.assertEqual(self.git("config", "--get", "core.hooksPath"), str(self.base / "custom-hooks"))
                self.git("config", scope, "--unset", "core.hooksPath")

    def test_invalid_files_fail_without_exposing_values(self):
        rules = self.rules()
        for body in ('{"literals": "synthetic-private-phrase"}', '{"literals": [""]}', '{}', '[]', 'invalid'):
            with self.subTest(body=body):
                rules.write_text(body)
                result = self.assert_preflight_failure("--private-patterns-file", rules)
                self.assertNotIn("synthetic-private-phrase", result.stdout + result.stderr)
                self.assertNotIn(str(rules), result.stdout + result.stderr)

    def test_inside_checkout_and_symlinked_rule_files_are_rejected(self):
        rules = self.root / "rules.json"
        rules.write_text('{"literals": []}')
        link = self.base / "external-link.json"
        link.symlink_to(rules)
        for path in (rules, link):
            with self.subTest(path=path):
                self.assert_preflight_failure("--private-patterns-file", path)

    def test_environment_override_does_not_replace_persistent_selection(self):
        configured = self.rules("configured.json")
        override = self.rules("override.json")
        self.git("config", "--local", "bipara.privatePatternsFile", str(configured))
        self.env["BIPARA_PRIVATE_PATTERNS_FILE"] = str(override)
        self.assertEqual(self.run_setup().returncode, 0)
        self.assertEqual(self.git("config", "--local", "--get", "bipara.privatePatternsFile"), str(configured))

    def test_environment_override_cannot_hide_missing_persistent_selection(self):
        self.git("config", "--local", "bipara.privatePatternsFile", str(self.base / "missing.json"))
        self.env["BIPARA_PRIVATE_PATTERNS_FILE"] = str(self.rules())
        self.assert_preflight_failure()

    def test_invalid_environment_override_is_rejected(self):
        self.env["BIPARA_PRIVATE_PATTERNS_FILE"] = str(self.base / "missing.json")
        self.assert_preflight_failure()

    def test_tool_cache_inside_checkout_is_rejected_before_writes(self):
        self.env["BIPARA_CHECK_TOOLS_DIR"] = str(self.root / "tools")
        self.assert_preflight_failure()

    def test_unignored_or_tracked_scratch_storage_is_rejected(self):
        (self.root / ".gitignore").write_text("")
        self.assert_preflight_failure()
        (self.root / ".gitignore").write_text("/.local/\n")
        (self.root / ".local").mkdir()
        (self.root / ".local/tracked.txt").write_text("synthetic")
        self.git("add", "-f", ".local/tracked.txt")
        shutil.rmtree(self.root / ".local")
        self.assert_preflight_failure()

    def test_help_and_invalid_arguments_make_no_changes(self):
        before = self.git("config", "--local", "--list")
        self.assertEqual(self.run_setup("--help").returncode, 0)
        for args in (("--unknown",), ("--private-patterns-file",), ("--private-patterns-file", "")):
            self.assert_preflight_failure(*args)
        self.assertEqual(self.git("config", "--local", "--list"), before)


if __name__ == "__main__":
    unittest.main()
