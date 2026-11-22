# Validation status

Bipara is experimental. The results below apply to the source and workflows checked. Each published installer has its own compatibility and qualification record. [GitHub Releases](https://github.com/willaaaaaaaaa/bipara/releases)

## Release candidate v0.2.0

On 2026-11-22 (UTC+8), `script/check.sh` passed on the arm64 tree based on `d96f571` with the 0.2.0 version bump, using macOS 27.0.1 and Xcode 27.2. The run covered 55 tooling tests, 332 Swift tests, and 425 offline Python tests with one skip, plus both worker bundles and the native Debug build. The skipped test is the formal-runtime attribution check covered by the formal CI baseline. The formal-mode offline suite reruns in the protected-tag workflow before draft assets are created. Real-provider, native UI and distribution qualification for this candidate remain pending; see the version's [release notes](https://github.com/willaaaaaaaaa/bipara/releases) for final installer checks and their scope.

## First-run model configuration

On 2026-11-21 (UTC+8), 332 Swift tests passed on the arm64 development tree based on `b1c39a1` with macOS 27.0.1 and Xcode 27.2. Coverage included an empty first launch and relaunch, saved model selection, and legacy migration. Two native UI tests used an offline gateway. One canceled the first model draft, then saved a configuration and translated with it. The other verified that both columns of a bilingual Markdown article retained the literal diff.

## Workspace, settings and packaging review

On 2026-11-21 (UTC+8), `script/check.sh` passed on the arm64 development tree based on `b1c39a1` with macOS 27.0.1 and Xcode 27.2. The run covered 331 Swift tests, 425 offline Python tests, 52 tooling tests, both worker bundles, and the native Debug build. One attribution check requires the formal release runtime and was skipped.

Across focused native sessions, 13 XCUI cases passed with offline fixtures. They covered background failure inspection, new-tab access with an overflowing tab strip, settings and model selection, dirty close, workspace themes, and bilingual Markdown reading. These sessions ran on macOS 27.0.1 with the macOS 26 deployment target. The final 196-file source-input manifest SHA-256, excluding Markdown and documentation artwork, is `8c1235f7380dd4c3989d29bb174bdb2b85844d23ce32579867b363a2d72fabcf`.

## Contextual translation prompts and unit recovery

On 2026-11-21 (UTC+8), 33 focused Swift tests and 292 offline Python tests passed on the arm64 working tree based on `b1c39a1` for `translation.v3` and `translation.markdown.v4`. Both worker bundles matched the canonical prompt bytes. Offline requests exercised batch and single-unit messages. A reopened partial job used its saved v3 Markdown prompt, then explicit retranslation used v4. The formal-release attribution check was skipped. Live bilingual quality comparisons remain pending.

The packaged offline fixture exercised reversed, missing, and duplicate model rows through the Swift coordinator on the arm64 working tree based on `b1c39a1`. A fresh Debug product passed strict signature verification and the bundled worker's recovery-capability handshake. The recovery run's 193-input source manifest SHA-256 is `f5804cb04d7eaf1be15ca4fb2e1a984159faf72addcc4f4ab3edc933cb556744`. Live-provider quality and cost remain unmeasured.

## Translation reader and completion copy

On 2026-11-21 (UTC+8), 70 focused Swift tests passed on the arm64 working tree based on `b1c39a1` with macOS 27.0.1 and Xcode 27.2. They covered local selection, position restoration, Markdown rendering, clipboard ownership, and configuration and credential regressions. The 191-input source manifest SHA-256 is `351877d95bf8c8284fe21e5c719989d5e407185a1b97ee266f7b917ac394fe97`.

A focused native theme test passed on macOS 27.0.1 with a macOS 14.0 deployment target. It saved all three themes and checked that the translation and Copy control remained available. The fixture executable SHA-256 is `70e0a3662374d89a92f6e6f25793adae75d4aad85619b4a1f9c891f682b67c44`. Complete interactive coverage at the minimum width, VoiceOver, and system motion and transparency combinations remain open. [Reading acceptance](testing.md#translation-reader-and-completion-copy)

## Installation

On 2026-11-21 (UTC+8), `script/build_dmg.sh --install` installed an arm64 development build signed with an Apple Development identity. Strict bundle verification passed, and saved preferences and the previously open document matched their pre-install checksums. The app launched and reopened the translated document offline. The build used the same source manifest as the 70-test reader run. Cross-install Keychain authorization during a model call and formal distribution remain unverified.

The arm64 development installer based on `5fc1904` with local installer changes updated the same Applications path from a mounted development DMG and a source build. It rejected a lower build and refused to replace a running copy. The signed executable stayed unchanged after each rejection. Finder interaction on the mounted DMG, browser quarantine, Intel runtime, and formal release qualification were outside this check.

## Markdown validation

On 2026-11-21 (UTC+8), 66 focused Swift tests passed on the tree identified by the 191-input source manifest SHA-256 `6c9f406c774b6ed2e903256af932fc7ffd63e8aa75df02136fbda17c4b45dbda`. The tests covered leading frontmatter with a short body, explicit format overrides, offline Apply, Rendered/Source switching, and legacy migration. Native UI acceptance was outside this run.

On 2026-11-20 (UTC+8), 40 focused Swift and 195 Python tests passed on the arm64 working tree based on `5fc1904` for `markdown-plan.v4`. A packaged offline fixture preserved accepted code-span reordering within its formatting boundaries through save, reopen, and export. The formal-release attribution check was skipped. Live-provider quality and manual UI acceptance remain open.

## macOS compatibility policy

On 2026-11-21 (UTC+8), the local arm64 Mac running macOS 27.0.1 with Xcode 27.2 built the Debug and Release apps for the macOS 14.0 deployment target with a freshly bundled development worker. All bundled Mach-O files passed the deployment-target check. Both builds passed strict signature and embedded asset verification, plus the worker handshake and shutdown. The Release executable SHA-256 is `62aacaf79580cbfd08096e1e0fd1f826c4fee3a49ce56aa4a6277b5a1e3e269b`. macOS 14 and Intel runtime behavior, clean-machine isolation, and installation or upgrade of a new formal DMG remain unverified.

## Remaining gates

Complete the applicable functional, native accessibility, and installer checks against the next release candidate. Real-provider semantic quality, latency, cost, and live rate-limit recovery require separate scoped checks. [App acceptance plan](testing.md#app-functional-acceptance)

Formal distribution requires a protected tag, valid package signatures, binary deployment-target checks, and local installation and upgrade acceptance against the exact final DMG checksum. Record the tested macOS version and any per-app security exception. [Release procedure](releasing.md)
