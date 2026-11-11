# Releasing

Public installers use separate Apple silicon and Intel DMGs; Intel targets macOS 26 only. A tag identifies source and `Config/Distribution.json` selects its trust policy. The initial `ad-hoc` policy uses valid ad-hoc code signatures without Developer ID verification or Apple notarization, and needs no paid Apple membership or signing credentials. A future `developer-id` policy requires signing and notarization. Both retain runtime, license and product gates, with exact-package local installation acceptance for the Apple silicon DMG; a GitHub Release becomes public only after qualification.

## Repository setup

Configure these settings before the first release:

- Protect main with required public-content and offline checks. Restrict creation, deletion and movement of formal version tags to release maintainers.
- Enable immutable releases and private vulnerability reporting.
- Create protected environments named release and release-publish. Restrict their deployment refs and configure appropriate reviewer access. Tag-triggered code runs with signing access, so only reviewed source may receive a release tag.
- Review all intended history and author/committer identities. The history check reports identities requiring review without printing their addresses. Existing historical identities are not silently approved or rewritten.

Only the `developer-id` policy requires release environment secrets BIPARA_CERTIFICATE_P12_BASE64, BIPARA_CERTIFICATE_PASSWORD, BIPARA_KEYCHAIN_PASSWORD, BIPARA_CODESIGN_IDENTITY, BIPARA_NOTARY_KEY_P8, BIPARA_NOTARY_KEY_ID and BIPARA_NOTARY_ISSUER_ID. Use a Developer ID Application certificate and eligible notarization API key. Keep credentials in a secrets system, outside Git. Do not dump the environment or upload raw signing logs. The hosted job imports credentials into a temporary keychain and removes it in its always-run cleanup step.

When Developer ID signing is used, the signing certificate exposes its subscriber's individual or organization identity in the distributed signature. Git ignore rules cannot conceal it; review the chosen signing identity before the first public package. See Apple's [Developer ID certification practice statement](https://images.apple.com/certificateauthority/pdf/Apple_Developer_ID_CPS_v3.2.pdf).

The GitHub-hosted arm64 draft build uses the `xcode-27` runner and selects Xcode 27.2 explicitly. The PR offline check and publication jobs use macOS 26 with Xcode 26.6. Each manifest records actual build tool versions. Python 3.13 and uv are build tools. Run script/setup.sh locally, or python3 script/install_check_tools.py in CI, to install checksum-pinned Gitleaks and actionlint outside the checkout. Signing/notarization requires network access. Default tests require no model account.

Formal builds use architecture-specific CPython 3.13.3 archives: `licenses/python-runtime/manifest.json` for arm64 and `manifest-x86_64.json` in the same directory for Intel. Build entry points default to the host architecture; `BIPARA_TARGET_ARCH` can select `arm64` or `x86_64` explicitly. Intel builds use a separate runtime cache. Xcode targets also default to the host architecture, while formal builds pass the selected architecture explicitly. A matching-architecture build host is required for PyInstaller; cross-compiling the Swift app alone does not produce a working Intel package. `script/prepare_release_runtime.py` downloads and checks its pinned SHA-256, verifies extracted source/native files (excluding interpreter-regenerated `.pyc` caches), and returns the interpreter path under ignored `build/release-runtime`. Build/check scripts select that path and disable automatic interpreter downloads. This avoids uv rewriting the library install name to a machine-specific path, which changes its file hash. Changed archives, extracted inputs or notices fail qualification. New runtime builds require new provenance/license review. The formal native CI baseline exercises this path without Apple credentials; dependency/runtime installation needs network access.

## Create a release candidate

Compatibility targets are macOS 26 and 27 on Apple Silicon, plus macOS 26 on compatible Intel Macs, with a minimum deployment version of 26.0. This is a fixed support scope, not an automatically rolling window. The formal build checks that the app declares the deployment target from `Config/Version.xcconfig` and that every bundled Mach-O binary for the selected architecture declares a target at or below it. Worker wheel selection retains its lower macOS 14.0 build baseline and frozen lockfile; this dependency baseline does not extend app support to older systems. Compilation and binary checks do not prove runtime compatibility. Installation and upgrade acceptance run only on the maintainer's local Apple silicon Mac, recorded against that exact DMG; users verify other target systems on their own devices.

1. Update Config/Version.xcconfig with the application version and a positive, increasing build number. Keep worker package and protocol versions independent. The helper bundle carries the application's packaging version.
2. Run script/check.sh and relevant native/model qualification. Summarize current results in docs/validation.md, keeping detailed evidence in .local/validation/.
3. Commit reviewed source to main using a selected public identity. Create and push a formal vMAJOR.MINOR.PATCH tag only under an actual release instruction.
4. The tag workflow checks source/history, runs offline checks, builds the worker and native app, verifies nested code signatures and mounted contents, and creates a DMG. Under `ad-hoc`, it requires no signing secrets and does not submit to Apple or claim Gatekeeper approval. Under `developer-id`, it imports temporary credentials, signs the app/DMG, notarizes the outer DMG, staples the ticket and verifies Gatekeeper acceptance.
5. The arm64 job uploads these Draft Release assets:

```text
Bipara-MAJOR.MINOR.PATCH-arm64.dmg
SHA256SUMS
release-manifest.json
```

A dependent `macos-26-intel` job uses Xcode 26.6 to build the Intel worker and application, then adds `Bipara-MAJOR.MINOR.PATCH-x86_64.dmg`, `SHA256SUMS-x86_64` and `release-manifest-x86_64.json`. Build checks cover signatures, architecture, deployment targets and helper packaging; they are not Intel app acceptance. Each package has its own schema-2 manifest and checksums. Publication validates all present assets and discloses the Intel package as runtime-untested; an arm64-only draft remains publishable without claiming an Intel download.

The schema-2 manifest records distribution mode, tag, commit, application/build versions, architecture, Xcode, Python, runtime-manifest/dependency-lock/prompt hashes and the final DMG checksum. Publication rejects a distribution mode different from the tagged policy. Traceable builds are not a claim of byte-identical rebuilds. The build rejects a dirty checkout, an unmatched version, a tag outside origin/main, missing required credentials, failed required notarization or a previously existing output directory. Preserve failed-build evidence and explicitly resolve existing output before retrying.

For a configured local release machine, the equivalent build command is:

```sh
script/build_dmg.sh --tag v0.1.0
```

For `developer-id`, it reads BIPARA_CODESIGN_IDENTITY and BIPARA_NOTARY_PROFILE from the environment; the profile must already be securely configured. The initial `ad-hoc` policy ignores a configured Developer ID identity and uses no Apple credentials. Formal builds do not source local shell configuration. Run only from a clean checkout of that tag, with full history and origin/main available. The default release output is build/release/TAG/.

## Install and publish

Download the draft DMG through a browser, retaining normal quarantine behavior. On the maintainer's local Apple Silicon Mac running macOS 26 or 27, test installation, Gatekeeper, first launch, helper operation, model configuration, translation, save/open and normal quit. Test upgrade from the previous package with settings/documents/Keychain intact; for an initial release, exercise replacement of a previous development installation and disclose limits. Record the exact OS version, final DMG checksum and actual coverage. Check bundled Python and native dependency deployment targets and runtime independence from development tools. These checks on an existing development machine do not establish clean-machine isolation. No other physical Mac, VM or minimum-OS runtime acceptance is required. Untested OS versions must remain explicitly unverified; users confirm compatibility in their own environment.

For the initial unnotarized package, verify the download/checksum and copy Bipara to Applications before opening it. macOS can block the first launch because the developer is unidentified and Apple has not notarized the app. If the user trusts the source and integrity, Apple documents a per-app exception through System Settings > Privacy & Security > Open Anyway after attempting launch. Managed Macs may prohibit this exception. Do not disable Gatekeeper globally or remove quarantine as an installation step. Record the actual warning and successful per-app exception on the tested local OS; an expected block is not a notarization pass. See [Apple's instructions](https://support.apple.com/en-us/102445).

Record private evidence against the exact final SHA-256. Dispatch the Release DMG workflow with the existing tag, the Apple silicon DMG checksum, the exact tested macOS version and both successful declarations: local installation and upgrade. Publication appends this OS version, checksum and the local-only validation limits to the existing release notes. It reads the minimum macOS version from the selected tag, rejects acceptance on an older OS, and preserves historical package minimums instead of applying the current compatibility claim to old tags. Publication uses the trusted main-branch tooling without executing code from the selected tag, downloads the draft again, checks tag/manifest/asset allowlist/checksums and the tagged trust policy, then publishes it. Developer ID assets additionally require notarization checks; ad-hoc assets receive disk-image integrity verification and retain the manual installation requirement. These declarations are an operator attestation, not an automated proof of manual testing. Do not mark a declaration true until its evidence exists.

Equivalent local publication after qualification:

```sh
python3 script/release.py publish --tag v0.1.0 --sha256 FINAL_DMG_SHA256 \
  --verified local-install --verified upgrade --tested-macos 27.0.1
```

Replace the example OS version with the actual version used for both checks; do not report the build runner's OS as local acceptance. Set GITHUB_REPOSITORY to the selected repository and authenticate gh with the required release permission. Never change a published tag or replace its assets; publish a new version for a source/package correction. App Store, universal packaging and an automatic in-app updater remain separate scope.

## Development packages

script/build_dmg.sh --development explicitly creates a local ad-hoc package. It is not a formal Release artifact or evidence of notarization or final-package installation acceptance. Full logs stay ignored and only the architecture-specific allowlisted formal assets are uploaded. License text is generated into build/third-party and bundled into the worker; regular builds do not rewrite tracked notice files.

Apple identifies macOS Tahoe 26 as the [last release for Intel Macs](https://developer.apple.com/documentation/macos-release-notes/macos-26_4-release-notes). Intel eligibility follows Apple's [macOS 26 hardware list](https://support.apple.com/en-euro/122867); this project does not add patched-OS support for older machines.
