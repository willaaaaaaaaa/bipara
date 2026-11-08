# Validation status

Bipara is an experimental source preview. Default development checks do not
qualify a public installer, real-provider behavior or the complete native UI.

## Tested source and reproduction

On 2026-11-08 (UTC+8), the complete `script/check.sh` passed in an isolated source
checkout without private notes, knowledge-service configuration, model credentials,
`script/env.local.sh` or `Config/BiparaDebug.local.xcconfig`. Dependencies were
installed before the offline suites; this is not a claim of network-free setup.
Only the documented public source and technical prerequisites were needed.

The runtime/source-input SHA-256 is
`ab5e5344df11bda996557549217a3a8b78b030f63507ac3122f24c63089f0c11`.
It covers 161 runtime, build and fixture inputs, including relative paths,
permission bits and per-file SHA-256 values. Markdown documentation and Git
attributes are excluded; detailed manifests
and execution evidence are retained privately. Subsequent documentation edits
receive content/link/whitespace checks rather than new product-coverage claims.

Use the prerequisites in [Tests/README.md](../Tests/README.md), install the pinned
check tools with `script/setup_local.sh`, and reproduce the development baseline:

```sh
uv python install 3.13.3 --no-bin
UV_PYTHON=3.13.3 UV_PYTHON_PREFERENCE=only-managed script/check.sh
```

No model key is required. Native package tests need a macOS window session.
The development baseline does not enable `BIPARA_RELEASE_BUILD`.

## Current evidence

| Layer | Observed result |
| --- | --- |
| Public content | Candidate content passed, including pinned Gitleaks; local links and the relative `CLAUDE.md` symlink passed |
| Tooling | 19 synthetic-repository tests passed |
| Worker | Frozen environment, production/fixture bundles, canonical prompt assets and notice collection passed |
| Swift | 270 tests passed: 38 worker, 108 core and 124 app-state tests |
| Python | 288 offline tests passed, including packaged-worker IPC |
| Native Debug | Build passed with the public ad-hoc signing fallback; no private signing configuration |
| Hosted workflows | Local workflow syntax checks passed; GitHub-hosted execution and protection settings remain unverified |
| Formal runtime | The selected managed CPython 3.13.3 fingerprint does not match the qualified formal-runtime manifest; formal packaging remains blocked |

The default run made no provider calls, launched no interactive UI acceptance
session and produced no qualified installer. Worker notices do not establish
complete external-dylib license coverage, asset rights or legal compatibility.
Those reviews remain separate.

## Remaining gates

Before uploading source, audit every intended commit/tag and its identities,
review images and attribution, and verify the actual public repository settings.
The old private history is excluded from the initial public ancestry; a passing
current-tree scan does not clear that archive for publication.

Native UI and accessibility, including VoiceOver, keyboard-only use, physical IME,
Increase Contrast and Reduce Motion, remain incomplete. Earlier focused interaction
and model samples are historical evidence, not fresh acceptance for this input.
Real-provider semantic quality, latency, cost and live rate-limit recovery require
separate scoped checks. See [the test plan](testing.md).

Formal distribution additionally requires the qualified runtime, complete license
review, Developer ID signing, notarization, Gatekeeper, clean installation, upgrade
and minimum-OS acceptance against the exact final DMG checksum. Target macOS 14+
and arm64 do not establish actual minimum-OS compatibility. Every formal version
still requires a protected tag and its qualified DMG under [the release procedure](releasing.md).
