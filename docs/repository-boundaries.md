# Repository and private-material boundaries

## Content ownership

| Material | Destination |
| --- | --- |
| Current product contracts, technical rationale, portable commands and concise validation conclusions | Tracked source and documentation |
| Temporary notes, full review narratives, logs, captures and validation archives | Ignored .local/notes, .local/logs and .local/validation |
| Long-lived non-secret personal context, private environment mappings, unpublished priorities and useful work-resumption summaries | The private knowledge base, with scoped provenance |
| Raw evidence, large attachments, pre-publication history and recovery archives | A private directory outside the checkout, referenced from private knowledge when useful |
| Minimal personal defaults and private-context retrieval routing | Private global agent instructions outside the checkout |
| API keys, signing private keys, notarization keys and passwords | Keychain or a secrets system |
| Third-party attribution, dependency versions and asset provenance | Tracked records and required distribution notices |

No private directory or KB access is required to understand, build or test the
project. Public documents state effective behavior and evidence limits, rather
than naming approval participants, replaying conversations or appending review
rounds. Public upstream citations and technical dates remain useful provenance.
Retain required copyright and release-signing identity information.

Classify material by purpose and audience. Engineering requirements remain public
even when they originate as personal preferences. Preserve useful design rationale,
normal commits and community discussions. Private coordination and raw execution
transcripts do not belong in public documentation. Private knowledge source IDs,
service addresses and adoption records remain on the private side; public files
contain the adopted engineering contract and public references.

## Code history and private context

Maintain one canonical public code history. Keep pre-publication history in a
private read-only archive; it is not merged into the public history. Additional
code remotes may back up the same publishable history without becoming separate
development lines.

The initial reviewed snapshot is a one-time privacy migration choice. Preserve
normal incremental public history afterwards; do not rebuild a root for each
release or remove required contribution attribution.

Private notes reference relevant commits, issues or releases instead of copying
source code or maintaining a second version of project contracts. The repository
owns effective product and engineering contracts; private context and archives
remain optional to contributors and are not build inputs.

## Local storage

Use .local/ only for temporary material. It is not backed up by Git, cloned or
shared across worktrees. Keep long-lived private material outside the repository
and back it up independently. Private knowledge is the entry for enduring context;
the external file store owns raw evidence and archives, rather than another copy
of project contracts. Verify recovery of material selected for preservation before
replacing history or retiring a preparation checkout. Existing ignored scratch locations are not public
inputs; new temporary work uses .local/.

Local setup defaults the external store to Documents/Private/Bipara under the
current home directory. Use script/setup_local.sh --private-dir PATH to select
another external directory. Its resolved path is kept only in the local Git
configuration key bipara.privateDirectory, never in tracked files. The store is
shared across checkouts only when explicitly configured to the same path.

Keep remote addresses in Git's local configuration. Keep private exact-match
patterns in an external JSON file selected by BIPARA_PRIVATE_PATTERNS_FILE:
an object containing a literals array of nonempty strings. The checker refuses a
pattern file inside the checkout and never prints matched values.
Setup creates an initially empty public-content-patterns.json in the external
private store and records it as bipara.privatePatternsFile in local Git config.
Add exact private hostnames, identities and other known private phrases there;
the environment variable can override this local selection.

Ignored files can still be forcibly tracked or copied by other programs.
Previously committed content remains in history. Do not rewrite history or silently
approve old author identities as part of routine cleanup.

## Enforcement

- script/setup_local.sh installs the checked-in hooks without replacing a different
  hooksPath and downloads checksum-pinned check tools into an external cache.
  The cache defaults to .cache/bipara/check-tools under the current home directory;
  bipara.checkToolsDirectory in local Git configuration records its location.
  BIPARA_CHECK_TOOLS_DIR selects an external CI/tool cache.
- script/check_public_content.py checks current tracked/nonignored files.
- --staged reads the actual Git index; --commits RANGE checks every outgoing
  snapshot and commit identity. --history audits historical content and identities;
  it never rewrites them. Removing current files does not clear historical findings.
- Outgoing annotated tags also check the tagger identity and annotation; history
  audits include all local tag refs. Example environment files remain synthetic.
- After explicit identity review, `BIPARA_APPROVED_COMMIT_EMAIL` permits that
  exact address for identity checks in the current process environment. It does
  not exempt content or secrets, and is not automatically passed to CI.
- Output identifies the rule and file/commit, never the matched private value.
  Attribution files retain legitimate third-party author information.
- Both hooks run --gitleaks using the pinned secret detector. Worktree/index scans
  export only their public candidate bytes into a private temporary snapshot;
  ignored private storage is not scanned or uploaded. Missing tools fail the check.
  Default offline checks, incoming PR commits and formal history checks also run it.
- Required PR checks block merging; protected tag/release checks block distribution.
  Local hooks are the upload-before-push defense. CI runs after upload.
- Build release artifacts from a clean tagged checkout and upload only the explicit
  asset allowlist. Private files and full logs are not release assets.

Scanners cannot judge every natural-language passage or image. Review screenshots,
public explanations and exceptions; an ignored directory is not an access-control
or encryption boundary. Check every commit being published, not only its latest
tree. Generic public rules contain no real private-domain/email blacklist.

## Publication

The project uses MIT. Public repository creation, remote pushes, visibility changes
and publication remain explicit operations. Follow [the preparation plan](open-source-preparation.md)
and [release procedure](releasing.md). Preserve tested state and disclose missing
provider, UI, minimum-OS and distribution evidence.
