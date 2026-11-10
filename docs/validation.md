# Validation status

Bipara is an experimental source preview. Default development checks do not qualify a public installer, real-provider behavior or the complete native UI.

## Custom model editor self-check

The current editor Save fix passed 46 targeted tests across the three suites below and a native Debug app build on 2026-11-10 (UTC+8), with 164-input manifest SHA-256 `5f0353675157694b5e3488435389f88b2d740895184d8cee59db5373168440c6`. A new regression first reproduced `invalidField("model configuration")` for both protocols: new custom records omitted the removed vendor field while Save still required it. The fix accepts absent labels, validates retained labels when present, and distinguishes field-validation errors from credential failures. Regressions verify Save/reload, active selection, synthetic-key retention and rejection before credential writes. No production settings or credentials were changed, and the running app was not restarted. Native UI acceptance remains unrun.

On 2026-11-10 (UTC+8), the six-field custom editor passed 44 targeted Swift tests in `OpenModelConfigurationTests`, `ModelConfigurationRegressionTests` and `CredentialBindingRegressionTests`, using `swift test --build-system swiftbuild --no-parallel --filter 'OpenModelConfigurationTests|ModelConfigurationRegressionTests|CredentialBindingRegressionTests'`. The native Debug application and updated UI test targets compiled with `xcodebuild build-for-testing`; no UI tests were executed. The 164-input manifest uses the format below and has SHA-256 `b2ac1516e8a60eded43704e9ab2fad3e18eb06acbb06de25fdff9dc83701b296`. The build uses the existing local Debug signing configuration.

The updated native cases cover blank manual fields, their order, both protocols, four efforts and the absence of preset/vendor/catalog/Advanced controls. Their new behavior and the shorter sheet still require native interaction acceptance. Full offline acceptance, real-provider checks and distribution qualification were not run. Earlier editor screenshots and native results below apply to the previous interface.

## Open model configuration evidence

On 2026-11-09 (UTC+8), the uncommitted working tree passed `script/check.sh` on arm64 macOS 27.0.1 with Xcode 27.2: 41 tooling tests, 280 Swift tests (39 worker, 109 Core, 132 app-state), 342 Python tests, both worker bundles and the native Debug build. One formal-runtime attribution test was skipped by the development-mode configuration; this was not a formal release run. The final 164-input manifest, using the format below, has SHA-256 `376676036d3f2fdf4be6866035147eefe45114adc9d32ef53eacda209470325d`. Existing accessibility changes remain in this working tree; their independent historical evidence stays below.

Thirteen targeted native XCTest cases passed across scoped runs, covering model CRUD/preset selection, arbitrary vendor/model IDs, both protocols, the four efforts, explicit legacy conversion, credential edits and endpoint restoration, advanced-field numeric validation/persistence, and the translation/settings smoke flow. Inspected English/light and Chinese/dark collapsed-editor screenshots and the expanded advanced form. The native fixture uses synthetic in-memory credentials and a deterministic gateway. HTTP mock tests additionally capture actual Responses/Messages bodies for both operations and all four efforts, while packaged Swift/Python integration verifies the extended pipe contract. No real-provider calls were made.

A focused code self-review resolved fresh-install defaults, request-revision restoration, numeric-input handling, canceled secret-header drafts, malformed option/header validation and distinct advanced-field accessibility identifiers. Local links, public-content/Gitleaks checks, the relative `CLAUDE.md` link and Git whitespace passed. Raw logs, screenshots, source manifests and review notes remain private. This evidence does not qualify arbitrary third-party endpoints, provider semantics/latency/cost, or an installer; the changes have not been committed or published.

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

## Native UI and accessibility evidence

On 2026-11-08–09 (UTC+8), 25 serial native XCTest UI cases passed on arm64 macOS 27.0.1 with Xcode 27.2 against `3ca01bb6ed7ae632d231b55afccafde6b02dfb99` (source-input manifest `5876fab4e62e5923e31f1b96513191454ba8cccbf05e009a3f377d0e82c5690e`). The isolated fixture uses synthetic in-memory credentials and a deterministic gateway; no real-provider calls were made. Cases exercised model configuration and credential drafts, independent tabs, live language/menu changes, both reading layouts, native selection/reveal, appearance preferences, close/quit decisions and workspace reopening. At five documents above 100 KiB each, 30 native interactions recorded p95 116.4 ms and local cancel feedback 69.6 ms; all samples reported a foreground app and key window. These are native acknowledgement/drawing measurements, not hardware input latency or full visual acceptance.

Subsequent local accessibility changes use the 160-input manifest `c51449ac6bb70f811bc900c9443275442bace28a9628f3b71730a9d34458a42e`. Formal-mode offline checks passed again: 41 tooling, 270 Swift and 289 Python tests, worker packaging and native Debug build. The focused native-text accessibility regression passed for Chinese names, layout changes, live language switching and the original-text editor. Native text names now follow the interface language and layout, with an ordering hint for the combined paragraph view. Manual accessibility-tree checks also confirmed the reading-size slider's own localized name, numeric changes from 28 to 14, persistence on Save, and removal of the stale adjacent size announcement. These metadata observations do not establish actual VoiceOver speech.

Manual fixture inspection covered bilingual paste and ambiguous-direction handling, light Settings, dark columns and paragraphs, 17/28-point reading text, and 900×650 and 1399×923-point windows. On 2026-11-09 (UTC+8), keyboard navigation exercised creation, offline translation, reading focus and selection, pinning, layout changes, save and reopen, and the model editor's vendor menu and Cancel action. The Save panel's temporary destination was set via accessibility. The focused slider regression now verifies Tab focus, native direction keys at both endpoints, keyboard Save and the localized Chinese name. The reading regression verifies the static translation status. Both passed on manifest `f61c8d9692b813d7b87a0cb8b962570d5047c72b3212bf1412d8af144e2f71e5`, which also passed the full formal-mode offline check.

The earlier system accessibility audit failed on that manifest. Representative captures showed clear windows after an earlier run with a Documents-access prompt. The four unknown-role findings for translation status cleared. Across the four audited states, 59 other findings remained, including 27 missing actions, 22 contrast findings, nine missing descriptions and one parent-child mismatch. The vendor picker opened with the Space key in manual testing. The audit used dSYMs for failure reporting and its findings remain historical diagnostic evidence.

On manifest `a5fd7029d6094115be5f99a699b2191767df9a9ee7c3e33d84c06f602011d35c`, the focused localized-text and reading-refinement cases both passed. In light Settings captures, sampling the dominant interior glyph and adjacent background sRGB values for the discard explanation and model metadata gave approximately 3.1:1 before the foreground change and 12.2:1 after it. This result covers those two sampled regions.

Earlier platform checks observed thicker correspondence underlines and retained selection across a system appearance change, plus a successful layout switch with Reduce Motion enabled. VoiceOver speech and physical input-method composition were untested. The temporary system settings were restored. These platform checks and the strict audit are historical evidence outside the [app functional scope](testing.md#app-functional-acceptance).

The follow-up app smoke check used the previously built fixture for manifest `a5fd7029d6094115be5f99a699b2191767df9a9ee7c3e33d84c06f602011d35c`. It exercised paste, English-to-Chinese fixture translation, both reading layouts, selection and pinning, independent drafts across tabs, and the unsaved-close prompt. These observations apply to that fixture build and sampled workflows.

## Remaining gates

Source is published at [willaaaaaaaaa/bipara](https://github.com/willaaaaaaaaa/bipara). Before subsequent uploads, audit every outgoing commit/tag and its identities, and review new images and attribution. A passing current-tree scan does not establish that every intended commit or tag is safe to publish.

Repository settings were read back after configuration: main requires PRs and both Actions checks, including for administrators; `v*` tags cannot be updated or deleted; release environments restrict deployment refs and require manual approval. Private vulnerability reporting, dependency alerts/security updates, secret scanning and push protection are enabled. Dependabot accepted the weekly configuration and opened update proposals; automatic merge is disabled. These settings do not qualify signing credentials or a formal release workflow.

Complete the applicable [app functional checks](testing.md#app-functional-acceptance) on the release candidate. Existing evidence applies to the recorded source and workflows. Real-provider semantic quality, latency, cost and live rate-limit recovery require separate scoped checks. Installer qualification remains a separate release gate.

Public distribution still requires native/product/provider qualification, valid ad-hoc package signatures, and clean installation, upgrade and minimum-OS acceptance against the exact final DMG checksum, including the actual macOS warning and per-app exception for the initial unnotarized package. Developer ID/notarization remain a future policy option rather than a prerequisite for this initial route. Target macOS 14+ and arm64 do not establish actual minimum-OS compatibility. Every formal version still requires a protected tag and its qualified DMG under [the release procedure](releasing.md).
