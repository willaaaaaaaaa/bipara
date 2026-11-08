import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "script"))

SCRIPT = Path(__file__).resolve().parents[2] / "script" / "check_public_content.py"
spec = importlib.util.spec_from_file_location("public_content", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PublicContentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "Synthetic contributor")
        self.git("config", "user.email", "123+synthetic@users.noreply.github.com")
        (self.root / ".gitignore").write_text("/.local/\n")
        (self.root / "README.md").write_text("# Synthetic project\n")
        self.git("add", ".")
        self.git("commit", "-qm", "chore: initialize fixture")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], stderr=subprocess.DEVNULL)

    def test_ignored_storage_is_excluded_but_forced_index_entry_is_blocked(self):
        private = self.root / ".local" / "notes.md"
        private.parent.mkdir()
        private.write_text("temporary working material")
        self.assertEqual(module.check(self.root), [])
        self.git("add", "-f", ".local/notes.md")
        self.assertIn("private-file", [rule for _, rule, _ in module.check(self.root, staged=True)])

    def test_index_is_checked_instead_of_clean_worktree(self):
        value = "sk-" + "A" * 32
        path = self.root / "config.txt"
        path.write_text(value)
        self.git("add", "config.txt")
        path.write_text("clean replacement")
        self.assertEqual(module.check(self.root), [])
        self.assertIn("credential", [rule for _, rule, _ in module.check(self.root, staged=True)])
        result = subprocess.run([sys.executable, str(SCRIPT), "--root", str(self.root), "--staged"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(value, result.stdout + result.stderr)

    def test_all_outgoing_commits_are_checked(self):
        base = self.git("rev-parse", "HEAD").decode().strip()
        self.git("config", "user.email", "private" + "@gmail.com")
        self.git("commit", "--allow-empty", "-qm", "chore: first outgoing commit")
        self.git("config", "user.email", "123+synthetic@users.noreply.github.com")
        self.git("commit", "--allow-empty", "-qm", "chore: latest outgoing commit")
        findings = module.check(self.root, revision_range=f"{base}..HEAD")
        self.assertEqual([rule for _, rule, _ in findings], ["commit-identity-review"])

    def test_process_text_is_checked_in_current_and_historical_content(self):
        body = b"The owner " + b"approved the third review round."
        self.assertIn(("process-narrative", 1), module.scan("docs/design.md", body))
        (self.root / "README.md").write_bytes(body)
        self.git("add", ".")
        self.git("commit", "-qm", "docs: fixture context")
        (self.root / "README.md").write_text("# Clean current content\n")
        self.git("add", ".")
        self.git("commit", "-qm", "docs: clean fixture")
        self.assertEqual(module.check(self.root), [])
        self.assertIn("process-narrative", [rule for _, rule, _ in module.check(self.root, history=True)])

    def test_private_author_is_blocked_before_commit(self):
        self.git("config", "user.email", "private" + "@gmail.com")
        self.assertIn("commit-identity-review", [rule for _, rule, _ in module.check(self.root, staged=True)])

    def test_explicit_identity_exception_checks_exact_email_in_index_and_history(self):
        address = "private" + "@gmail.com"
        self.git("config", "user.email", address)
        with patch.dict("os.environ", {"BIPARA_APPROVED_COMMIT_EMAIL": address}):
            self.assertNotIn("commit-identity-review", [rule for _, rule, _ in module.check(self.root, staged=True)])
            self.git("commit", "--allow-empty", "-qm", "chore: approved fixture")
            self.assertNotIn("commit-identity-review", [rule for _, rule, _ in module.check(self.root, revision_range="HEAD")])
        with patch.dict("os.environ", {"BIPARA_APPROVED_COMMIT_EMAIL": "other" + "@gmail.com"}):
            self.assertIn("commit-identity-review", [rule for _, rule, _ in module.check(self.root, staged=True)])
            self.assertIn("commit-identity-review", [rule for _, rule, _ in module.check(self.root, revision_range="HEAD")])

    def test_external_symlink_is_not_followed(self):
        (self.root / "private-link").symlink_to(self.root.parent)
        self.assertIn("unapproved-symlink", [rule for _, rule, _ in module.check(self.root)])

    def test_legitimate_attribution_and_synthetic_addresses_remain_valid(self):
        self.assertEqual(module.scan("LICENSE", b"Author: person" + b"@gmail.com"), [])
        self.assertEqual(module.scan("example.md", b"person@example.com"), [])

    def test_public_docs_cannot_link_to_ignored_private_storage(self):
        (self.root / "README.md").write_text("[private](.local/notes.md)\n")
        self.assertIn("missing-public-link", [rule for _, rule, _ in module.check(self.root)])

    def test_secret_detector_receives_index_bytes_and_reports_only_location(self):
        secret = "synthetic-sensitive-value"
        (self.root / "config.txt").write_text(secret)
        self.git("add", "config.txt")
        (self.root / "config.txt").write_text("clean worktree")

        def detector(args, **kwargs):
            snapshot = Path(args[2])
            self.assertEqual((snapshot / "config.txt").read_text(), secret)
            report = Path(args[args.index("--report-path") + 1])
            report.write_text(json.dumps([{"File": str(snapshot / "config.txt"), "RuleID": "fixture-rule", "StartLine": 1, "Secret": secret}]))
            return subprocess.CompletedProcess(args, 1, secret.encode(), b"")

        indexed = self.git("show", ":config.txt")
        with patch.object(module, "tool_directory", return_value=self.root.parent), patch.object(module.subprocess, "run", side_effect=detector):
            findings = module.secret_findings(self.root, {"config.txt": indexed})
        self.assertEqual(findings, [("config.txt", "secret-detector:fixture-rule", 1)])
        self.assertNotIn(secret, repr(findings))

    def test_missing_secret_detector_blocks_instead_of_skipping(self):
        with patch.object(module, "tool_directory", return_value=self.root / "missing"):
            with self.assertRaises(OSError):
                module.secret_findings(self.root, {"README.md": b"public"})

    def test_forced_environment_and_signing_files_are_blocked(self):
        for name in (".env.production", "config/distribution.pfx", "app.mobileprovision"):
            self.assertIn(("private-file", 0), module.scan(name, b"synthetic"))
        self.assertEqual(module.scan(".env.example", b"SYNTHETIC_SETTING=example"), [])

    def test_annotated_tags_check_identity_and_process_text(self):
        self.git("config", "user.email", "private" + "@gmail.com")
        message = "The owner " + "approved this release."
        self.git("tag", "-a", "v0.1.0", "-m", message)
        findings = module.check_tag(self.root, "refs/tags/v0.1.0", ())
        self.assertEqual({rule for _, rule, _ in findings}, {"tag-identity-review", "process-narrative"})
        self.assertIn("tag-identity-review", [rule for _, rule, _ in module.check(self.root, history=True)])


if __name__ == "__main__":
    unittest.main()
