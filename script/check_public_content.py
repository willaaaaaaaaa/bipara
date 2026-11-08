#!/usr/bin/env python3
"""Check publishable files without displaying matched private material."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlsplit

from install_check_tools import tool_directory


RULES = {
    "private-key": re.compile(rb"-----BEGIN (?:OPENSSH |RSA |EC )?PRIVATE KEY-----"),
    "credential": re.compile(rb"\b(?:sk-(?:proj-)?[A-Za-z0-9_-]{24,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[A-Z0-9]{16})\b"),
    "personal-path": re.compile(rb"/(?:Users/(?!USER/|USERNAME/)[A-Za-z0-9._-]+|home/(?!runner/|USER/)[A-Za-z0-9._-]+)/"),
    "personal-email": re.compile(rb"\b[A-Za-z0-9._%+-]+@(?:gmail|qq|163|126|hotmail|outlook|icloud)\.(?:com|net)\b", re.I),
    "private-context": re.compile(rb"\bknowledge_base_id\b|https?://[^\s/]+\.(?:internal|corp)(?:/|\b)", re.I),
    "temporary-marker": re.compile(rb"temp-" + rb"repro-marker"),
}
PROCESS = re.compile(rb"\b(?:Codex|Claude Code)\b|\b(?:owner|user)[ -](?:approved|requested|confirmed)\b|\bcross-review\b", re.I)
PRIVATE_DIRS = {".local", "local", ".scratch", ".codex", ".claude", ".cross-review", ".my-repo-review", "secrets", "build", "dist", ".build"}
PRIVATE_SUFFIXES = {".log", ".p12", ".p8", ".pfx", ".pem", ".key", ".mobileprovision", ".provisionprofile", ".dmg", ".xcresult"}


def git(root: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.DEVNULL)


def private_path(name: str) -> bool:
    path = PurePosixPath(name)
    return (path.suffix == ".bipara" and not name.startswith("Tests/Fixtures/")) or bool(PRIVATE_DIRS.intersection(path.parts)) or path.suffix in PRIVATE_SUFFIXES or any(
        part.endswith((".app", ".xcresult")) or (part.startswith(".env") and part != ".env.example") or ".local." in part for part in path.parts
    )


def scan(name: str, data: bytes, *, literals: tuple[bytes, ...] = ()) -> list[tuple[str, int]]:
    findings = []
    if private_path(name):
        findings.append(("private-file", 0))
    # Third-party attribution is intentionally allowed to retain its authors.
    attribution = PurePosixPath(name).name.startswith(("LICENSE", "COPYING", "NOTICE")) or "ThirdPartyLicenses" in PurePosixPath(name).parts
    if b"\0" in data[:8192]:
        return findings
    for number, line in enumerate(data.splitlines(), 1):
        for rule, pattern in RULES.items():
            if rule == "personal-email" and attribution:
                continue
            if pattern.search(line):
                findings.append((rule, number))
        if name.endswith((".md", ".swift", ".py", ".sh", ".txt")) and name != "script/check_public_content.py" and PROCESS.search(line):
            findings.append(("process-narrative", number))
        if any(value in line for value in literals):
            findings.append(("private-literal", number))
    return findings


def private_literals(root: Path) -> tuple[bytes, ...]:
    value = os.environ.get("BIPARA_PRIVATE_PATTERNS_FILE")
    if not value:
        result = subprocess.run(["git", "-C", str(root), "config", "--local", "--get", "bipara.privatePatternsFile"], capture_output=True, text=True)
        value = result.stdout.strip()
    if not value:
        return ()
    path = Path(value).expanduser().resolve()
    if path.is_relative_to(root.resolve()):
        raise ValueError("private pattern configuration must be outside the checkout")
    values = json.loads(path.read_text())["literals"]
    if not isinstance(values, list) or any(not isinstance(x, str) or not x for x in values):
        raise ValueError("private literals must be nonempty strings")
    return tuple(x.encode() for x in values)


def public_author(email: str) -> bool:
    approved = os.environ.get("BIPARA_APPROVED_COMMIT_EMAIL", "")
    return bool(email) and (email == approved or email == "noreply@github.com" or email.endswith("@users.noreply.github.com") or email.endswith("@example.com"))


def check_tag(root: Path, ref: str, literals: tuple[bytes, ...], *, gitleaks: bool = False) -> list[tuple[str, str, int]]:
    if not ref.startswith("refs/tags/"):
        raise ValueError("tag checks require a complete tag ref")
    if git(root, "cat-file", "-t", ref).strip() != b"tag":
        return []  # Lightweight tags have no separate tagger or annotation.
    headers, _, body = git(root, "cat-file", "tag", ref).partition(b"\n\n")
    identity = re.search(rb"^tagger [^\n]*<([^>]+)>", headers, re.M)
    findings = []
    if not identity or not public_author(identity.group(1).decode("utf-8", "replace")):
        findings.append((ref, "tag-identity-review", 0))
    findings.extend((ref, rule, line) for rule, line in scan("tag.txt", body, literals=literals))
    if gitleaks:
        findings.extend((ref, rule, line) for _, rule, line in secret_findings(root, {"tag.txt": body}))
    return findings


def check_links(contents: dict[str, bytes]) -> list[tuple[str, str, int]]:
    findings = []
    for name, data in contents.items():
        if not name.endswith(".md"):
            continue
        fenced = False
        for number, line in enumerate(data.decode("utf-8", "replace").splitlines(), 1):
            if line.lstrip().startswith("```"):
                fenced = not fenced
            if fenced:
                continue
            for raw in re.findall(r"\[[^\]]*\]\(([^)]+)\)", line):
                raw = raw.strip("<>")
                if urlsplit(raw).scheme:
                    continue
                path, _, anchor = raw.partition("#")
                target = posixpath.normpath(str(PurePosixPath(name).parent / unquote(path))) if path else name
                if target not in contents and not any(candidate.startswith(target.rstrip("/") + "/") for candidate in contents):
                    findings.append((name, "missing-public-link", number))
                elif anchor and target in contents and target.endswith(".md"):
                    headings = re.findall(r"^#+\s+(.+)$", contents[target].decode("utf-8", "replace"), re.M)
                    slugs = [re.sub(r"\s", "-", re.sub(r"[^\w\s-]", "", heading.lower())) for heading in headings]
                    if anchor not in slugs:
                        findings.append((name, "missing-public-anchor", number))
    return findings


def secret_findings(root: Path, contents: dict[str, bytes] | None, revision_range: str | None = None) -> list[tuple[str, str, int]]:
    executable = tool_directory(root) / "gitleaks"
    with tempfile.TemporaryDirectory(prefix="bipara-secret-check-") as temporary:
        folder = Path(temporary)
        report = folder / "report.json"
        if contents is not None:
            snapshot = folder / "source"
            snapshot.mkdir()
            for name, data in contents.items():
                path = snapshot / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            args = ["dir", str(snapshot)]
        else:
            args = ["git", str(root), "--log-opts", revision_range or "--all"]
        result = subprocess.run([str(executable), *args, "--redact", "--no-banner", "--report-format", "json", "--report-path", str(report)], capture_output=True)
        if result.returncode not in (0, 1) or not report.is_file():
            raise ValueError("secret check failed")
        findings = []
        for item in json.loads(report.read_text()):
            name = item["File"]
            if contents is not None and Path(name).is_absolute():
                name = str(Path(name).relative_to(snapshot))
            findings.append((name, "secret-detector:" + item["RuleID"], item["StartLine"]))
        if result.returncode == 1 and not findings:
            raise ValueError("secret check produced no report")
        return findings


def check(root: Path, *, staged: bool = False, revision_range: str | None = None, history: bool = False, gitleaks: bool = False) -> list[tuple[str, str, int]]:
    findings = []
    literals = private_literals(root)
    if staged:
        for role in ("GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT"):
            identity = git(root, "var", role).decode()
            email = re.search(r"<([^>]+)>", identity)
            if not email or not public_author(email.group(1)):
                findings.append((role, "commit-identity-review", 0))
    if revision_range or history:
        if history:
            for ref in git(root, "for-each-ref", "--format=%(refname)", "refs/tags").decode().splitlines():
                findings.extend(check_tag(root, ref, literals, gitleaks=gitleaks))
        commits = git(root, "rev-list", revision_range or "--all").decode().splitlines()
        seen = set()
        for commit in commits:
            # Check every outgoing commit, not only the most recent identity.
            authors = git(root, "show", "-s", "--format=%ae%n%ce", commit).decode().splitlines()
            if any(not public_author(email) for email in authors):
                findings.append((commit[:12], "commit-identity-review", 0))
            message = git(root, "show", "-s", "--format=%B", commit)
            findings.extend((commit[:12], rule, line) for rule, line in scan("commit.txt", message, literals=literals))
            for entry in git(root, "ls-tree", "-r", "-z", commit).split(b"\0"):
                if not entry:
                    continue
                metadata, name_bytes = entry.split(b"\t", 1)
                mode, kind, oid = metadata.split()
                name = name_bytes.decode("utf-8", "surrogateescape")
                if kind != b"blob" or (oid, name) in seen:
                    continue
                seen.add((oid, name))
                data = git(root, "cat-file", "blob", oid.decode())
                if mode == b"120000" and (name != "CLAUDE.md" or data != b"AGENTS.md"):
                    findings.append((name, "unapproved-symlink", 0))
                findings.extend((name, rule, line) for rule, line in scan(name, data, literals=literals))
        return findings + (secret_findings(root, None, revision_range) if gitleaks else [])
    args = ["ls-files", "-z", "--cached"]
    if not staged:
        args.extend(["--others", "--exclude-standard"])
    contents = {}
    for name in sorted(set(git(root, *args).decode("utf-8", "surrogateescape").split("\0")) - {""}):
        path = root / name
        if not staged and not path.exists() and not path.is_symlink():
            continue
        if staged:
            mode = git(root, "ls-files", "-s", "--", name).split(b" ", 1)[0]
            data = git(root, "show", ":" + name)
            is_link = mode == b"120000"
        else:
            is_link = path.is_symlink()
            data = os.readlink(path).encode() if is_link else path.read_bytes()
        if is_link:
            if name != "CLAUDE.md" or data != b"AGENTS.md":
                findings.append((name, "unapproved-symlink", 0))
            else:
                contents[name] = git(root, "show", ":AGENTS.md") if staged else (root / "AGENTS.md").read_bytes()
            continue
        contents[name] = data
        findings.extend((name, rule, line) for rule, line in scan(name, data, literals=literals))
    return findings + check_links(contents) + (secret_findings(root, contents) if gitleaks else [])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--staged", action="store_true")
    group.add_argument("--commits", metavar="REVISION_RANGE")
    group.add_argument("--history", action="store_true", help="audit all historical content and author identities without rewriting history")
    group.add_argument("--tag-ref", help="check a complete outgoing tag ref and its annotation")
    parser.add_argument("--gitleaks", action="store_true", help="also run the pinned external secret detector")
    args = parser.parse_args()
    try:
        findings = check_tag(args.root, args.tag_ref, private_literals(args.root), gitleaks=args.gitleaks) if args.tag_ref else check(args.root, staged=args.staged, revision_range=args.commits, history=args.history, gitleaks=args.gitleaks)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError):
        print("public-content: unable to complete the check; inspect local configuration", file=sys.stderr)
        return 2
    for name, rule, line in findings:
        print(f"{json.dumps(name, ensure_ascii=True)}:{line}: {rule}")
    if findings:
        print(f"public-content: blocked ({len(findings)} findings); matched values are redacted")
        return 1
    print("public-content: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
