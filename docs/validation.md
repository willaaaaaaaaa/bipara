# Validation status

Bipara is an experimental source preview. Default development checks do not qualify a public installer, real-provider behavior or the complete native UI.

## Tested source and reproduction

On 2026-11-08 (UTC+8), the default offline suites, worker packaging and native Debug build passed for the source inputs below. Public-content checks passed for the working tree and existing Git history after local check setup. These results do not qualify hosted GitHub settings, live providers or an installer. Dependencies were installed before the offline suites; setup may require network access. No provider calls were made. The default native build used the checkout's optional local Debug signing configuration; the separate ad-hoc build below overrides its signing identity and team.

The source-input manifest SHA-256 is `9d918d98a6187f7f4d427f93aadd43ebb70e137ba38b9fd3853445ff1d8ea828`. It covers the 157 tracked or nonignored non-Markdown files present in the tested tree, excluding `.gitattributes`. The manifest sorts repository-relative paths and records one UTF-8 line per file: path, four-digit octal permission bits and file SHA-256, separated by tabs and terminated by LF. Detailed manifests and execution evidence stay outside tracked documentation. Documentation-only edits receive content, link and whitespace checks without new product-coverage claims.

Use the prerequisites in [Tests/README.md](../Tests/README.md), install the pinned check tools with `script/setup.sh`, and reproduce the development baseline:

```sh
uv python install 3.13.3 --no-bin
UV_PYTHON=3.13.3 UV_PYTHON_PREFERENCE=only-managed script/check.sh
```

No model key is required. Native package tests need a macOS window session. The development baseline does not enable `BIPARA_RELEASE_BUILD`. To reproduce a development build with ad-hoc signing even when optional local signing settings exist:

```sh
xcodebuild -project Bipara.xcodeproj -scheme Bipara \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/native-check CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

## Current evidence

| Layer | Observed result |
| --- | --- |
| Public content | Working tree and existing one-commit history passed built-in rules and pinned Gitleaks; identity, local links and the relative `CLAUDE.md` symlink passed. Custom private-literal rules are initially empty |
| Tooling | 32 synthetic-repository tests passed, including 13 setup regressions for repeated execution, configuration preservation, custom hooks, invalid rule files and path boundaries |
| Contributor setup | `script/setup.sh` passed two consecutive runs in the development checkout, preserving existing Git configuration, rule-file bytes and external permissions |
| Worker | Frozen environment, production/fixture bundles, canonical prompt assets and notice collection passed |
| Swift | 270 tests passed: 38 worker, 108 core and 124 app-state tests |
| Python | 288 offline tests passed, including packaged-worker IPC |
| Native Debug | Default build passed with local Debug signing configuration; a separate build with explicit ad-hoc signing overrides also passed |
| Hosted workflows | Local workflow syntax checks passed; GitHub-hosted execution and protection settings remain unverified |
| Formal runtime | The recorded CPython 3.13.3 fingerprint mismatch remains unresolved; formal-runtime qualification was not rerun |

The default run made no provider calls, launched no interactive UI acceptance session and produced no qualified installer. Worker notices do not establish complete external-dylib license coverage, asset rights or legal compatibility. Those reviews remain separate.

## Remaining gates

Before uploading source, audit every intended commit/tag and its identities, review images and attribution, and verify the actual public repository settings. A passing current-tree scan does not establish that every intended commit or tag is safe to publish.

Issue templates, support guidance and weekly dependency-update configuration are present. Hosted issue rendering, Dependabot execution, vulnerability reporting and repository protections still require verification on the actual GitHub repository.

Native UI and accessibility, including VoiceOver, keyboard-only use, physical IME, Increase Contrast and Reduce Motion, remain incomplete. Offline component tests do not establish complete native or live-model acceptance for this input. Real-provider semantic quality, latency, cost and live rate-limit recovery require separate scoped checks. See [the test plan](testing.md).

Formal distribution additionally requires the qualified runtime, complete license review, Developer ID signing, notarization, Gatekeeper, clean installation, upgrade and minimum-OS acceptance against the exact final DMG checksum. Target macOS 14+ and arm64 do not establish actual minimum-OS compatibility. Every formal version still requires a protected tag and its qualified DMG under [the release procedure](releasing.md).
