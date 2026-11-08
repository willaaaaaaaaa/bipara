# Releasing

Formal releases contain an installable Apple Silicon DMG. A tag identifies source;
the GitHub Release becomes public only after its exact package is qualified.

## Repository setup

Configure these settings before the first release:

- Protect main with required public-content and offline checks. Restrict creation,
  deletion and movement of formal version tags to release maintainers.
- Enable immutable releases and private vulnerability reporting.
- Create protected environments named release and release-publish. Restrict their
  deployment refs and configure appropriate reviewer access. Tag-triggered code
  runs with signing access, so only reviewed source may receive a release tag.
- Review all intended history and author/committer identities. The history check
  reports identities requiring review without printing their addresses. Existing
  historical identities are not silently approved or rewritten.

The release environment requires secrets BIPARA_CERTIFICATE_P12_BASE64,
BIPARA_CERTIFICATE_PASSWORD, BIPARA_KEYCHAIN_PASSWORD, BIPARA_CODESIGN_IDENTITY,
BIPARA_NOTARY_KEY_P8, BIPARA_NOTARY_KEY_ID and BIPARA_NOTARY_ISSUER_ID.
Use a Developer ID Application certificate and eligible notarization API key.
Keep the private material outside Git and the KB. Do not dump the environment or
upload raw signing logs. The hosted job imports credentials into a temporary
keychain and removes it in its always-run cleanup step.

The signing certificate exposes its subscriber's individual or organization
identity in the distributed signature. Git ignore rules cannot conceal it;
review the chosen signing identity before the first public package. See Apple's
[Developer ID certification practice statement](https://images.apple.com/certificateauthority/pdf/Apple_Developer_ID_CPS_v3.2.pdf).

GitHub-hosted arm64 macOS 26 jobs select Xcode 26.6 explicitly. Record actual
tool versions in each manifest; runner image labels can receive updates. Python
3.13 and uv are build tools. Run script/setup_local.sh locally, or
python3 script/install_check_tools.py in CI, to install checksum-pinned Gitleaks
and actionlint outside the checkout. Signing/notarization requires network access;
default tests require no model account.

Formal builds qualify the managed arm64 CPython 3.13.3 build recorded in
licenses/python-runtime/manifest.json. Its native-library fingerprint and unchanged
upstream notices are verified before packaging. A different interpreter build
requires a new provenance/license review; development Homebrew builds additionally
collect the actual external dylib license files. An interpreter version string
alone does not establish native-component provenance.
The hosted native jobs select UV_PYTHON=3.13.3 and
UV_PYTHON_PREFERENCE=only-managed in a runner-temporary installation directory.
Configure the same interpreter selection on a local formal release machine.

## Create a release candidate

1. Update Config/Version.xcconfig with the application version and a positive,
   increasing build number. Keep worker package/protocol versions independent;
   the helper bundle carries the application's packaging version.
2. Run script/check.sh and relevant native/model qualification. Summarize current
   results in docs/validation.md, keeping detailed evidence in .local/validation/.
3. Commit reviewed source to main using a selected public identity. Create and
   push a formal vMAJOR.MINOR.PATCH tag only under an actual release instruction.
4. The tag workflow checks source/history, runs offline checks, builds the worker
   and native app, signs nested code, creates/signs the DMG, notarizes the outer
   DMG, staples its ticket and verifies signatures/Gatekeeper and mounted contents.
5. The workflow uploads a Draft Release with exactly these assets:

```text
Bipara-MAJOR.MINOR.PATCH-arm64.dmg
SHA256SUMS
release-manifest.json
```

The manifest records tag, commit, application/build versions, architecture, Xcode,
Python, dependency-lock and prompt hashes, and the final stapled DMG checksum.
Signing timestamps mean traceable builds are not a claim of byte-identical rebuilds.
The build rejects a dirty checkout, an unmatched version, a tag outside origin/main,
missing credentials, failed notarization or a previously existing output directory.
Preserve failed-build evidence and explicitly resolve existing output before retrying.

For a configured local release machine, the equivalent build command is:

```sh
script/build_dmg.sh --tag v0.1.0
```

It reads BIPARA_CODESIGN_IDENTITY and BIPARA_NOTARY_PROFILE from the environment.
The profile must already be securely configured. Formal builds do not source local
shell configuration. Run only from a clean checkout of that tag, with full history
and origin/main available. The default release output is build/release/TAG/.

## Install and publish

Download the draft DMG through a browser, retaining normal quarantine behavior.
Test on a supported clean Mac without source/development Python: installation,
Gatekeeper, first launch, helper operation, model configuration, translation,
save/open and normal quit. Test upgrade from the previous supported package with
settings/documents/Keychain intact. Qualify the lowest claimed macOS version,
including the Python and native dependency binaries. For an initial release,
exercise replacement of a previous development installation and disclose limits.

Record private evidence against the exact final SHA-256. Dispatch the Release DMG
workflow with the existing tag, that checksum and all three successful declarations:
clean installation, upgrade and minimum OS. Publication uses the trusted main-branch tooling without executing code from the selected tag, downloads the draft again,
checks tag/manifest/asset allowlist/checksums and notarization, then publishes it.
These declarations are an operator attestation, not an automated proof of manual
testing. Do not mark a declaration true until its evidence exists.

Equivalent local publication after qualification:

```sh
python3 script/release.py publish --tag v0.1.0 --sha256 FINAL_DMG_SHA256 \
  --verified clean-install --verified upgrade --verified minimum-os
```

Set GITHUB_REPOSITORY to the selected repository and authenticate gh with the
required release permission. Never change a published tag or replace its assets;
publish a new version for a source/package correction. App Store, Intel and an
automatic in-app updater remain separate scope.

## Development packages

script/build_dmg.sh --development explicitly creates a local ad-hoc package.
It is not a formal Release artifact or evidence of notarization/clean-machine
acceptance. Full logs stay ignored and only the three allowlisted formal assets
are uploaded. License text is generated into build/third-party and bundled into
the worker; regular builds do not rewrite tracked notice files.
