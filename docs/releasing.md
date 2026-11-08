# Releasing

Public installers contain an Apple Silicon DMG. A tag identifies source and `Config/Distribution.json` selects its trust policy. The initial `ad-hoc` policy uses valid ad-hoc code signatures without Developer ID verification or Apple notarization, and needs no paid Apple membership or signing credentials. A future `developer-id` policy requires signing and notarization. Both retain runtime, license, product and exact-package installation gates; a GitHub Release becomes public only after qualification.

## Repository setup

Configure these settings before the first release:

- Protect main with required public-content and offline checks. Restrict creation, deletion and movement of formal version tags to release maintainers.
- Enable immutable releases and private vulnerability reporting.
- Create protected environments named release and release-publish. Restrict their deployment refs and configure appropriate reviewer access. Tag-triggered code runs with signing access, so only reviewed source may receive a release tag.
- Review all intended history and author/committer identities. The history check reports identities requiring review without printing their addresses. Existing historical identities are not silently approved or rewritten.

Only the `developer-id` policy requires release environment secrets BIPARA_CERTIFICATE_P12_BASE64, BIPARA_CERTIFICATE_PASSWORD, BIPARA_KEYCHAIN_PASSWORD, BIPARA_CODESIGN_IDENTITY, BIPARA_NOTARY_KEY_P8, BIPARA_NOTARY_KEY_ID and BIPARA_NOTARY_ISSUER_ID. Use a Developer ID Application certificate and eligible notarization API key. Keep credentials in a secrets system, outside Git. Do not dump the environment or upload raw signing logs. The hosted job imports credentials into a temporary keychain and removes it in its always-run cleanup step.

When Developer ID signing is used, the signing certificate exposes its subscriber's individual or organization identity in the distributed signature. Git ignore rules cannot conceal it; review the chosen signing identity before the first public package. See Apple's [Developer ID certification practice statement](https://images.apple.com/certificateauthority/pdf/Apple_Developer_ID_CPS_v3.2.pdf).

GitHub-hosted arm64 macOS 26 jobs select Xcode 26.6 explicitly. Record actual tool versions in each manifest; runner image labels can receive updates. Python 3.13 and uv are build tools. Run script/setup.sh locally, or python3 script/install_check_tools.py in CI, to install checksum-pinned Gitleaks and actionlint outside the checkout. Signing/notarization requires network access; default tests require no model account.

Formal builds use the exact arm64 CPython 3.13.3 archive in `licenses/python-runtime/manifest.json`. `script/prepare_release_runtime.py` downloads and checks its pinned SHA-256, verifies extracted source/native files (excluding interpreter-regenerated `.pyc` caches), and returns the interpreter path under ignored `build/release-runtime`. Build/check scripts select that path and disable automatic interpreter downloads. This avoids uv rewriting the library install name to a machine-specific path, which changes its file hash. Changed archives, extracted inputs or notices fail qualification. New runtime builds require new provenance/license review. The formal native CI baseline exercises this path without Apple credentials; dependency/runtime installation needs network access.

## Create a release candidate

1. Update Config/Version.xcconfig with the application version and a positive, increasing build number. Keep worker package/protocol versions independent; the helper bundle carries the application's packaging version.
2. Run script/check.sh and relevant native/model qualification. Summarize current results in docs/validation.md, keeping detailed evidence in .local/validation/.
3. Commit reviewed source to main using a selected public identity. Create and push a formal vMAJOR.MINOR.PATCH tag only under an actual release instruction.
4. The tag workflow checks source/history, runs offline checks, builds the worker and native app, verifies nested code signatures and mounted contents, and creates a DMG. Under `ad-hoc`, it requires no signing secrets and does not submit to Apple or claim Gatekeeper approval. Under `developer-id`, it imports temporary credentials, signs the app/DMG, notarizes the outer DMG, staples the ticket and verifies Gatekeeper acceptance.
5. The workflow uploads a Draft Release with exactly these assets:

```text
Bipara-MAJOR.MINOR.PATCH-arm64.dmg
SHA256SUMS
release-manifest.json
```

The schema-2 manifest records distribution mode, tag, commit, application/build versions, architecture, Xcode, Python, runtime-manifest/dependency-lock/prompt hashes and the final DMG checksum. Publication rejects a distribution mode different from the tagged policy. Traceable builds are not a claim of byte-identical rebuilds. The build rejects a dirty checkout, an unmatched version, a tag outside origin/main, missing required credentials, failed required notarization or a previously existing output directory. Preserve failed-build evidence and explicitly resolve existing output before retrying.

For a configured local release machine, the equivalent build command is:

```sh
script/build_dmg.sh --tag v0.1.0
```

For `developer-id`, it reads BIPARA_CODESIGN_IDENTITY and BIPARA_NOTARY_PROFILE from the environment; the profile must already be securely configured. The initial `ad-hoc` policy ignores a configured Developer ID identity and uses no Apple credentials. Formal builds do not source local shell configuration. Run only from a clean checkout of that tag, with full history and origin/main available. The default release output is build/release/TAG/.

## Install and publish

Download the draft DMG through a browser, retaining normal quarantine behavior. Test on a supported clean Mac without source/development Python: installation, Gatekeeper, first launch, helper operation, model configuration, translation, save/open and normal quit. Test upgrade from the previous supported package with settings/documents/Keychain intact. Qualify the lowest claimed macOS version, including the Python and native dependency binaries. For an initial release, exercise replacement of a previous development installation and disclose limits.

For the initial unnotarized package, verify the download/checksum and copy Bipara to Applications before opening it. macOS can block the first launch because the developer is unidentified and Apple has not notarized the app. If the user trusts the source and integrity, Apple documents a per-app exception through System Settings > Privacy & Security > Open Anyway after attempting launch. Managed Macs may prohibit this exception. Do not disable Gatekeeper globally or remove quarantine as an installation step. Record the actual warning and successful per-app exception on each qualified OS; an expected block is not a notarization pass. See [Apple's instructions](https://support.apple.com/en-us/102445).

Record private evidence against the exact final SHA-256. Dispatch the Release DMG workflow with the existing tag, that checksum and all three successful declarations: clean installation, upgrade and minimum OS. Publication uses the trusted main-branch tooling without executing code from the selected tag, downloads the draft again, checks tag/manifest/asset allowlist/checksums and the tagged trust policy, then publishes it. Developer ID assets additionally require notarization checks; ad-hoc assets receive disk-image integrity verification and retain the manual installation requirement. These declarations are an operator attestation, not an automated proof of manual testing. Do not mark a declaration true until its evidence exists.

Equivalent local publication after qualification:

```sh
python3 script/release.py publish --tag v0.1.0 --sha256 FINAL_DMG_SHA256 \
  --verified clean-install --verified upgrade --verified minimum-os
```

Set GITHUB_REPOSITORY to the selected repository and authenticate gh with the required release permission. Never change a published tag or replace its assets; publish a new version for a source/package correction. App Store, Intel and an automatic in-app updater remain separate scope.

## Development packages

script/build_dmg.sh --development explicitly creates a local ad-hoc package. It is not a formal Release artifact or evidence of notarization/clean-machine acceptance. Full logs stay ignored and only the three allowlisted formal assets are uploaded. License text is generated into build/third-party and bundled into the worker; regular builds do not rewrite tracked notice files.
