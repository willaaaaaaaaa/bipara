#!/usr/bin/env python3
"""Build tagged DMGs and publish exact, installation-qualified assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
if sys.version_info < (3, 12):
    raise SystemExit("release: Python 3.12 or newer is required")
TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
REQUIRED_CHECKS = ("clean-install", "upgrade", "minimum-os")


class ReleaseError(Exception):
    pass


def command(*args: str, cwd: Path = ROOT, env: dict | None = None) -> str:
    result = subprocess.run(list(args), cwd=cwd, env=env, capture_output=True, text=True)
    if result.returncode:
        # Tool output may contain credential-bearing arguments or local paths.
        raise ReleaseError(f"{Path(args[0]).name}: operation failed")
    return result.stdout.strip()


def version(root: Path = ROOT, ref: str | None = None) -> tuple[str, str]:
    text = command("git", "show", f"{ref}:Config/Version.xcconfig", cwd=root) if ref else (root / "Config/Version.xcconfig").read_text()
    values = dict(re.findall(r"^(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*(\S+)\s*$", text, re.M))
    app = values["MARKETING_VERSION"]
    build = values["CURRENT_PROJECT_VERSION"]
    if not TAG.fullmatch("v" + app) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ReleaseError("invalid version configuration")
    return app, build


def distribution(root: Path = ROOT, ref: str | None = None) -> str:
    text = command("git", "show", f"{ref}:Config/Distribution.json", cwd=root) if ref else (root / "Config/Distribution.json").read_text()
    value = json.loads(text)
    if not isinstance(value, dict) or set(value) != {"mode"} or value["mode"] not in {"ad-hoc", "developer-id"}:
        raise ReleaseError("invalid distribution mode")
    return value["mode"]


def source(tag: str, root: Path = ROOT, *, require_checkout: bool = True) -> tuple[str, str, str]:
    if not TAG.fullmatch(tag):
        raise ReleaseError("formal tags must be vMAJOR.MINOR.PATCH")
    app, build = version(root, None if require_checkout else f"refs/tags/{tag}")
    if tag != "v" + app:
        raise ReleaseError("tag and application version differ")
    commit = command("git", "rev-parse", "--verify", f"refs/tags/{tag}^{{commit}}", cwd=root)
    if require_checkout and commit != command("git", "rev-parse", "HEAD", cwd=root):
        raise ReleaseError("checkout does not match the requested tag")
    if command("git", "status", "--porcelain", "--untracked-files=all", cwd=root):
        raise ReleaseError("release checkout must be clean")
    command("git", "merge-base", "--is-ancestor", commit, "refs/remotes/origin/main", cwd=root)
    return app, build, commit


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def assets(tag: str) -> tuple[str, str, str]:
    if not TAG.fullmatch(tag):
        raise ReleaseError("invalid formal tag")
    return f"Bipara-{tag[1:]}-arm64.dmg", "SHA256SUMS", "release-manifest.json"


def verify_assets(folder: Path, tag: str, commit: str, mode: str) -> dict:
    names = assets(tag)
    if {p.name for p in folder.iterdir()} != set(names) or any((folder / n).is_symlink() for n in names):
        raise ReleaseError("release asset inventory differs from the allowlist")
    manifest = json.loads((folder / names[2]).read_text())
    allowed = {"schema", "tag", "commit", "version", "build", "architecture", "xcode", "python", "lock_sha256", "prompt_sha256", "dmg_sha256", "distribution", "runtime_manifest_sha256"}
    if not isinstance(manifest, dict) or set(manifest) != allowed or manifest["schema"] != 2 or manifest["architecture"] != "arm64":
        raise ReleaseError("invalid release manifest")
    if manifest["distribution"] != mode or mode not in {"ad-hoc", "developer-id"}:
        raise ReleaseError("asset distribution mode differs from the tagged policy")
    if manifest["tag"] != tag or manifest["version"] != tag[1:] or manifest["commit"] != commit:
        raise ReleaseError("asset provenance does not match the tag")
    if manifest["dmg_sha256"] != digest(folder / names[0]):
        raise ReleaseError("DMG checksum mismatch")
    expected = "".join(f"{digest(folder / n)}  {n}\n" for n in (names[0], names[2]))
    if (folder / names[1]).read_text() != expected:
        raise ReleaseError("release checksum inventory mismatch")
    return manifest


def run_logged(args: list[str], env: dict, log: Path) -> None:
    with log.open("a") as stream:
        os.chmod(log, 0o600)
        result = subprocess.run(args, cwd=ROOT, env=env, stdout=stream, stderr=stream)
    if result.returncode:
        raise ReleaseError(f"{Path(args[0]).name}: build failed; inspect ignored release logs")


def verify_bundle(app: Path) -> None:
    helper = app / "Contents/Helpers/BiparaWorker.app"
    if not (helper / "Contents/MacOS/BiparaWorker").is_file():
        raise ReleaseError("bundled worker is missing")
    command("codesign", "--verify", "--deep", "--strict", str(app))
    if command("lipo", "-archs", str(app / "Contents/MacOS/Bipara")) != "arm64":
        raise ReleaseError("unexpected application architecture")
    for prompt in (ROOT / "prompts").glob("*.txt"):
        if digest(prompt) != digest(helper / "Contents/Frameworks/prompts" / prompt.name):
            raise ReleaseError("bundled prompt differs from the tagged source")
    if not (helper / "Contents/Resources/ThirdPartyLicenses/README.md").is_file():
        raise ReleaseError("bundled dependency licenses are missing")
    for path in app.rglob("*"):
        public_ca = False
        if path.parent.name == "certifi" and path.name == "cacert.pem" and path.is_file():
            certificate = path.read_bytes()
            public_ca = b"-----BEGIN CERTIFICATE-----" in certificate and b"PRIVATE KEY" not in certificate
        if any(part in {".local", ".scratch", ".git", "secrets"} for part in path.relative_to(app).parts) or path.suffix in {".p12", ".p8", ".key", ".log"} or (path.suffix == ".pem" and not public_ca):
            raise ReleaseError("private material found in the application bundle")
    with tempfile.TemporaryDirectory(prefix="bipara-helper-smoke-") as home:
        result = subprocess.run([str(helper / "Contents/MacOS/BiparaWorker")],
                                input='{"v":2,"type":"hello"}\n{"v":2,"type":"shutdown"}\n',
                                capture_output=True, text=True, timeout=15,
                                env={"PATH": "/usr/bin:/bin", "HOME": home, "TMPDIR": home})
        frames = [json.loads(line) for line in result.stdout.splitlines()]
        if result.returncode or [frame.get("type") for frame in frames] != ["ready", "stopped"]:
            raise ReleaseError("signed helper handshake/shutdown smoke failed")


def build_release(tag: str) -> None:
    app_version, build_number, commit = source(tag)
    mode = distribution()
    command(sys.executable, "script/check_public_content.py", "--history", "--gitleaks")
    identity = os.environ.get("BIPARA_CODESIGN_IDENTITY", "") if mode == "developer-id" else "-"
    profile = os.environ.get("BIPARA_NOTARY_PROFILE", "")
    if mode == "developer-id":
        if not identity.startswith("Developer ID Application:") or not profile:
            raise ReleaseError("Developer ID Application identity and notarization profile are required")
        identities = command("security", "find-identity", "-v", "-p", "codesigning")
        if f'"{identity}"' not in identities:
            raise ReleaseError("the configured signing identity is unavailable")
    if command("uname", "-m") != "arm64":
        raise ReleaseError("formal packages currently target arm64")
    env = os.environ.copy()
    env["BIPARA_RELEASE_BUILD"] = "1"
    env["UV_PYTHON"] = command(sys.executable, "script/prepare_release_runtime.py")
    env["UV_PYTHON_DOWNLOADS"] = "never"
    env["UV_PYTHON_PREFERENCE"] = "only-system"
    if mode == "developer-id":
        env["BIPARA_CODESIGN_IDENTITY"] = identity
    else:
        # An explicit identity makes PyInstaller enable library validation.
        # Its default ad-hoc signing supports a worker without a Team ID.
        env.pop("BIPARA_CODESIGN_IDENTITY", None)
    logs = ROOT / ".local/logs/release"
    logs.mkdir(parents=True, exist_ok=True)
    run_logged(["script/build_worker.sh", "--release-only"], env, logs / "worker.log")
    derived = ROOT / "build/tagged-release"
    shutil.rmtree(derived, ignore_errors=True)
    run_logged(["xcodebuild", "-project", "Bipara.xcodeproj", "-scheme", "Bipara", "-configuration", "Release", "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO", "build"], env, logs / "native.log")
    app = derived / "Build/Products/Release/Bipara.app"
    resources = app / "Contents/Resources"
    shutil.copy2(ROOT / "LICENSE", resources / "LICENSE")
    signing_options = ["--timestamp", "--options", "runtime"] if mode == "developer-id" else ["--timestamp=none"]
    command("codesign", "--force", "--sign", identity, *signing_options, str(app))
    verify_bundle(app)
    import plistlib
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info["CFBundleShortVersionString"] != app_version or info["CFBundleVersion"] != build_number:
        raise ReleaseError("built application version differs from the tag")
    output = ROOT / "build/release" / tag
    if output.exists():
        raise ReleaseError("release output already exists; preserve or remove it explicitly before rebuilding")
    output.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix="bipara-dmg-") as temp:
        staging = Path(temp) / "staging"
        staging.mkdir()
        command("ditto", str(app), str(staging / "Bipara.app"))
        (staging / "Applications").symlink_to("/Applications")
        dmg = output / assets(tag)[0]
        command("hdiutil", "create", "-volname", "Bipara", "-srcfolder", str(staging), "-format", "UDZO", str(dmg))
        if mode == "developer-id":
            command("codesign", "--sign", identity, "--timestamp", str(dmg))
            notary_keychain = os.environ.get("BIPARA_NOTARY_KEYCHAIN")
            notary_args = ["--keychain", notary_keychain] if notary_keychain else []
            result = json.loads(command("xcrun", "notarytool", "submit", str(dmg), "--keychain-profile", profile,
                                        *notary_args, "--wait", "--output-format", "json"))
            if result.get("status") != "Accepted":
                raise ReleaseError("notarization was not accepted")
            command("xcrun", "stapler", "staple", str(dmg))
            command("xcrun", "stapler", "validate", str(dmg))
            command("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose", str(dmg))
        mount = Path(temp) / "mount"
        mount.mkdir()
        command("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(dmg))
        try:
            verify_bundle(mount / "Bipara.app")
            if mode == "developer-id":
                command("spctl", "--assess", "--type", "execute", str(mount / "Bipara.app"))
        finally:
            command("hdiutil", "detach", str(mount))
    manifest = {"schema": 2, "tag": tag, "commit": commit, "version": app_version, "build": build_number,
                "distribution": mode, "runtime_manifest_sha256": digest(ROOT / "licenses/python-runtime/manifest.json"),
                "architecture": "arm64", "xcode": command("xcodebuild", "-version"),
                "python": command("uv", "run", "--project", "Worker", "--frozen", "python", "--version", env=env),
                "lock_sha256": digest(ROOT / "Worker/uv.lock"),
                "prompt_sha256": {p.name: digest(p) for p in sorted((ROOT / "prompts").glob("*.txt"))},
                "dmg_sha256": digest(dmg)}
    (output / "release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (output / "SHA256SUMS").write_text("".join(f"{digest(output / n)}  {n}\n" for n in (assets(tag)[0], assets(tag)[2])))
    verify_assets(output, tag, commit, mode)
    print(f"release: verified assets in build/release/{tag}")


def github_release(tag: str, *, publish: bool, expected_sha: str = "", verified: list[str] | None = None) -> None:
    _, _, commit = source(tag, require_checkout=not publish)
    mode = distribution(ref=f"refs/tags/{tag}")
    if publish and (set(verified or []) != set(REQUIRED_CHECKS) or not re.fullmatch(r"[a-f0-9]{64}", expected_sha)):
        raise ReleaseError("publication requires the exact checksum and all three installation declarations")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ReleaseError("GITHUB_REPOSITORY must identify the selected public repository")
    if publish:
        metadata = json.loads(command("gh", "release", "view", tag, "--repo", repo, "--json", "isDraft,assets"))
        if not metadata["isDraft"] or {x["name"] for x in metadata["assets"]} != set(assets(tag)):
            raise ReleaseError("publication requires a draft with the exact asset allowlist")
        with tempfile.TemporaryDirectory(prefix="bipara-release-check-") as temp:
            folder = Path(temp)
            command("gh", "release", "download", tag, "--repo", repo, "--dir", temp)
            manifest = verify_assets(folder, tag, commit, mode)
            if manifest["dmg_sha256"] != expected_sha:
                raise ReleaseError("installation declarations refer to another DMG")
            if mode == "developer-id":
                command("xcrun", "stapler", "validate", str(folder / assets(tag)[0]))
                command("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", str(folder / assets(tag)[0]))
            else:
                command("hdiutil", "verify", str(folder / assets(tag)[0]))
        command("gh", "release", "edit", tag, "--repo", repo, "--draft=false", "--latest")
    else:
        folder = ROOT / "build/release" / tag
        verify_assets(folder, tag, commit, mode)
        existing = subprocess.run(["gh", "release", "view", tag, "--repo", repo, "--json", "isDraft"], capture_output=True, text=True)
        if existing.returncode == 0:
            if not json.loads(existing.stdout)["isDraft"]:
                raise ReleaseError("published release assets are immutable")
        else:
            trust = "Ad-hoc signed; not Developer ID signed or notarized. macOS may require Open Anyway in Privacy & Security. " if mode == "ad-hoc" else "Developer ID signed and notarized. "
            command("gh", "release", "create", tag, "--repo", repo, "--verify-tag", "--draft", "--title", tag,
                    "--notes", trust + "Experimental native bilingual reader. See the bundled manifest, checksums and repository validation status.")
        command("gh", "release", "upload", tag, "--repo", repo, "--clobber", *(str(folder / n) for n in assets(tag)))
    print("release: published" if publish else "release: draft assets uploaded")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("preflight", "build", "draft", "publish"))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--sha256", default="")
    parser.add_argument("--verified", action="append", choices=REQUIRED_CHECKS, default=[])
    args = parser.parse_args()
    try:
        if args.operation == "preflight":
            source(args.tag)
            print("release: source preflight passed")
        elif args.operation == "build":
            build_release(args.tag)
        else:
            github_release(args.tag, publish=args.operation == "publish", expected_sha=args.sha256, verified=args.verified)
    except (ReleaseError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"release: {error if isinstance(error, ReleaseError) else 'invalid configuration or tool response'}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
