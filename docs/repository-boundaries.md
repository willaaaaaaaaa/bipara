# Repository boundaries

## Content ownership

| Material | Destination |
| --- | --- |
| Current product contracts, technical rationale, portable commands and concise validation conclusions | Tracked source and documentation |
| Temporary notes, full review narratives, logs, captures and validation archives | Ignored .local/notes, .local/logs and .local/validation |
| Raw evidence, large attachments and recovery archives requiring retention | Secure storage outside the checkout |
| Personal workflows, machine-specific configuration and account details | Outside tracked project files |
| API keys, signing private keys, notarization keys and passwords | Keychain or a secrets system |
| Third-party attribution, dependency versions and asset provenance | Tracked records and required distribution notices |

Only documented public inputs are required to understand, build or test the project. Public documents state effective behavior and evidence limits, rather than naming approval participants, replaying conversations or appending review rounds. Public upstream citations and technical dates remain useful provenance. Retain required copyright and release-signing identity information.

Classify material by purpose and audience. Engineering requirements remain public regardless of their origin. Preserve useful design rationale, normal commits and community discussions. Personal coordination, private service identifiers and raw execution transcripts do not belong in public documentation. Public files contain the effective engineering contract and public references.

## Current documentation and history

Maintain one canonical public code history. Keep current documentation focused on effective behavior, technical rationale, compatibility and validation limits. Remove superseded proposals, unused candidate artwork and redundant process records from the current tree. Preserve supported prompt/schema versions and fixtures that are still used by runtime or tests, and retain asset provenance and third-party attribution.

Keep personal workflows out of public project documents; contributors need complete, portable engineering instructions. Keep each prose paragraph and logical list item on one source line, with structural and code newlines intact.

Normal incremental commits and community discussions are useful project history. Do not rewrite history, rebuild a root for each release or remove required contribution attribution as part of routine cleanup. Review every commit intended for upload; removing a file from the current tree does not remove it from history.

## Local setup and storage

Use .local/ only for temporary material. It is not backed up by Git, cloned or shared across worktrees. Keep long-lived private material outside the repository and back it up independently. Verify recovery before deleting material selected for preservation. Existing ignored scratch locations are not public inputs; new temporary work uses .local/.

`script/setup.sh` creates `.local/notes`, `.local/logs` and `.local/validation` with owner-only permissions, selects `.githooks` in local Git configuration and installs checksum-pinned check tools in an external cache. The cache defaults to `.cache/bipara/check-tools` under the current home directory; `bipara.checkToolsDirectory` records its location. `BIPARA_CHECK_TOOLS_DIR` overrides the cache location. Initial tool installation needs network access to official GitHub releases; setup does not install the worker dependencies.

Private exact-match rules are optional additions to the built-in checker and Gitleaks. To select them, create a JSON file outside the checkout containing a `literals` array of nonempty strings, then run `script/setup.sh --private-patterns-file /path/to/patterns.json`. This explicit option changes the local `bipara.privatePatternsFile` selection. Setup never creates or overwrites rule files or changes existing external-directory permissions. Without the option, it preserves the existing selection; without any selection, only the built-in and Gitleaks rules apply. `BIPARA_PRIVATE_PATTERNS_FILE` overrides the selection for the current process and is not persisted by setup.

Setup validates persistent and environment rule selections before writes. A missing, malformed or in-checkout file stops setup; restore it or explicitly select a valid replacement. A custom effective `core.hooksPath`, including a global setting, also stops setup without replacing it; integrate the checked-in hooks manually and install tools with `python3 script/install_check_tools.py`. Keep remote addresses and private paths in local configuration. No personal archive directory is required.

Ignored files can still be forcibly tracked or copied by other programs. Previously committed content remains in history. Do not rewrite history or silently approve old author identities as part of routine cleanup.

## Enforcement

- script/check_public_content.py checks current tracked/nonignored files.
- --staged reads the actual Git index; --commits RANGE checks every outgoing snapshot and commit identity. --history audits historical content and identities; it never rewrites them. Removing current files does not clear historical findings.
- Outgoing annotated tags also check the tagger identity and annotation; history audits include all local tag refs. Example environment files remain synthetic.
- New project commits use GitHub noreply identities; reserved example addresses are accepted only for synthetic tooling fixtures. Other author/committer addresses stop for explicit publication review. After that review, `BIPARA_APPROVED_COMMIT_EMAIL` permits the exact approved address for commit, push and history checks in the current process environment. It does not exempt content or secrets, and CI needs the same reviewed setting when applicable.
- Output identifies the rule and file/commit, never the matched private value. Attribution files retain legitimate third-party author information.
- Both hooks run --gitleaks using the pinned secret detector. Worktree/index scans export only their public candidate bytes into a private temporary snapshot; ignored private storage is not scanned or uploaded. Missing tools fail the check. Default offline checks, incoming PR commits and formal history checks also run it.
- Required PR checks block merging; protected tag/release checks block distribution. Local hooks are the upload-before-push defense. CI runs after upload.
- Build release artifacts from a clean tagged checkout and upload only the explicit asset allowlist. Private files and full logs are not release assets.

Scanners cannot judge every natural-language passage or image. Review screenshots, public explanations and exceptions; an ignored directory is not an access-control or encryption boundary. Check every commit being published, not only its latest tree. Generic public rules contain no real private-domain/email blacklist.

## Publication

The project uses MIT. Public repository creation, remote pushes, visibility changes and publication remain explicit operations. Follow [the preparation plan](open-source-preparation.md) and [release procedure](releasing.md). Preserve tested state and disclose missing provider, UI, cross-version, clean-machine and distribution evidence.
