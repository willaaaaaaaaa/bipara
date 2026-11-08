# Validation status

Bipara is an experimental source preview. Default development checks do not qualify a public installer, real-provider behavior or the complete native UI.

## Tested source and reproduction

On 2026-11-08 (UTC+8), the default offline suites, worker packaging and native Debug build passed in [GitHub Actions](https://github.com/willaaaaaaaaa/bipara/actions/runs/42487562509) for commit `640b239d11a640a8c14750366a91c7621b270f40`. The hosted environment used macOS 26, Xcode 26.6 (Swift 6.3.3) and managed CPython 3.13.3, without developer-local configuration or model credentials. Dependencies were installed before the offline suites; setup requires network access. No provider calls were made. The same application sources also passed local Swift tests and an explicit ad-hoc Debug build. Neither environment qualifies an installer or complete native UI behavior.

The source-input manifest SHA-256 is `f6739ab29c665581d18e93a54362a83d1408debe265cc60e0e35a96e32bebb5e`. It covers the 157 tracked or nonignored non-Markdown files present in the tested tree, excluding `.gitattributes`. The manifest sorts repository-relative paths and records one UTF-8 line per file: path, four-digit octal permission bits and file SHA-256, separated by tabs and terminated by LF. Detailed manifests and execution evidence stay outside tracked documentation. Documentation-only edits receive content, link and whitespace checks without new product-coverage claims.

Use the prerequisites in [Tests/README.md](../Tests/README.md), install the pinned check tools with `script/setup.sh`, and reproduce the development baseline:

```sh
uv python install 3.13.3 --no-bin
UV_PYTHON=3.13.3 UV_PYTHON_PREFERENCE=only-managed script/check.sh
```

No model key is required. Native package tests need a macOS window session. The development baseline explicitly selects Swift Build and serial test cases for package tests and does not enable `BIPARA_RELEASE_BUILD`. To reproduce a development build with ad-hoc signing even when optional local signing settings exist:

```sh
xcodebuild -project Bipara.xcodeproj -scheme Bipara \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/native-check CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

## Source-publication evidence

| Layer | Observed result |
| --- | --- |
| Public content | Working tree, index and outgoing history passed built-in rules and pinned Gitleaks before publication; hosted checks also passed. Identity, local links and the relative `CLAUDE.md` symlink passed |
| Tooling | 32 synthetic-repository tests passed, including 13 setup regressions for repeated execution, configuration preservation, custom hooks, invalid rule files and path boundaries |
| Contributor setup | `script/setup.sh` passed two consecutive runs in the development checkout, preserving existing Git configuration, rule-file bytes and external permissions |
| Worker | Frozen environment, production/fixture bundles, canonical prompt assets and notice collection passed |
| Swift | 270 tests passed: 38 worker, 108 core and 124 app-state tests, including paragraph restoration and text width with legacy and overlay scrollers |
| Python | 288 offline tests passed, including packaged-worker IPC |
| Native Debug | Hosted ad-hoc Debug build and a local build with explicit ad-hoc signing overrides passed |
| Hosted workflows | Both required jobs, `public-content` and `native-offline`, passed for the commit linked above; workflow syntax checks passed |
| Formal runtime | This historical development run did not qualify the formal runtime; the subsequent release-foundation result is recorded below |

The default run made no provider calls, launched no interactive UI acceptance session and produced no qualified installer. Worker notices do not establish complete external-dylib license coverage, asset rights or legal compatibility. Those reviews remain separate.

## Release-foundation evidence

On 2026-11-08 (UTC+8), `BIPARA_RELEASE_BUILD=1 script/check.sh` passed locally on arm64 macOS 27.0.1 with Xcode 27.2: 41 tooling tests, 270 Swift tests, 289 Python tests, both worker bundles and the native Debug build. The 160 non-Markdown source inputs, excluding `.gitattributes`, use the manifest format above and have SHA-256 `b19fe41474e4292b0eeba65e7ef06e580fc974d212ad516741253461c489c616`. The local Debug build may still read the optional Debug signing configuration; it is not a clean-machine installation result.

The Python archive checksum matched its upstream checksum asset. Runtime preparation verified the unchanged archive library and extracted source/native files; interpreter-regenerated `.pyc` caches are excluded. The former library mismatch came from uv rewriting the Mach-O install name to an installation-specific path. Twenty upstream component notices matched the pinned source revision. The packaged inventory contains 55 entries, including 40 runtime attribution entries and 14 native binary inputs; these counts include conservative component notices rather than claiming 40 independently loaded packages. Checksum-verified source archives for the MPL-covered certifi and orjson versions are bundled with their licenses. Source, native attribution, cached/downloaded tampering, unsafe extraction and distribution-mode regressions passed.

An isolated clean Git fixture subsequently ran the actual tagged build entry point without Apple credentials and produced all three allowlisted assets. Its 160 source inputs have SHA-256 `5876fab4e62e5923e31f1b96513191454ba8cccbf05e009a3f377d0e82c5690e`. Release compilation, nested ad-hoc signature checks, mounted bundle checks, and helper handshake/shutdown passed. End-to-end checks also exposed and fixed a private-content boundary check that incorrectly included parent checkout paths, and an explicit ad-hoc PyInstaller identity that enabled incompatible library validation. The resulting local DMG checksum is `072caef6b735c6ab69ba9afb08e02974b5b4d054376a93c9a6ef103e1a3a2840`; it has not passed browser-quarantine, clean-installation, upgrade or minimum-OS qualification and is not a published release.

The tagged distribution policy selects ad-hoc signing without Developer ID or Apple notarization. This removes the Apple membership/credential prerequisite for the initial download, while retaining product and exact-package installation gates. Repository immutability is enabled; a separate creation ruleset limits `v*` tag creation to the release maintainer, while the existing no-bypass update/deletion rules remain active. Main protection was read back unchanged. These configuration checks do not establish installation or hosted release-workflow acceptance.

## Remaining gates

Source is published at [willaaaaaaaaa/bipara](https://github.com/willaaaaaaaaa/bipara). Before subsequent uploads, audit every outgoing commit/tag and its identities, and review new images and attribution. A passing current-tree scan does not establish that every intended commit or tag is safe to publish.

Repository settings were read back after configuration: main requires PRs and both Actions checks, including for administrators; `v*` tags cannot be updated or deleted; release environments restrict deployment refs and require manual approval. Private vulnerability reporting, dependency alerts/security updates, secret scanning and push protection are enabled. Dependabot accepted the weekly configuration and opened update proposals; automatic merge is disabled. These settings do not qualify signing credentials or a formal release workflow.

Native UI and accessibility, including VoiceOver, keyboard-only use, physical IME, Increase Contrast and Reduce Motion, remain incomplete. Offline component tests do not establish complete native or live-model acceptance for this input. Real-provider semantic quality, latency, cost and live rate-limit recovery require separate scoped checks. See [the test plan](testing.md).

Public distribution still requires native/product/provider qualification, valid ad-hoc package signatures, and clean installation, upgrade and minimum-OS acceptance against the exact final DMG checksum, including the actual macOS warning and per-app exception for the initial unnotarized package. Developer ID/notarization remain a future policy option rather than a prerequisite for this initial route. Target macOS 14+ and arm64 do not establish actual minimum-OS compatibility. Every formal version still requires a protected tag and its qualified DMG under [the release procedure](releasing.md).
