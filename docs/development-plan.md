# Development plan

Use this read order: [requirements](requirements.md), [design principles](design-principles.md), [architecture](architecture.md), [technical design](design/technical-design.md), [model configuration](design/model-settings.md), [model workflow](design/model-workflow.md), [worker protocol](design/worker-protocol.md), [document format](design/document-format.md), [prompts](../prompts/README.md), then [testing](testing.md).

Each document owns its topic. Resolve material contract conflicts before changing observable behavior; continue independent work. Keep shared document logic separate from presentation and provider frameworks. Do not introduce another runtime or service to work around a failed feasibility check.

## Delivery gates

| Gate | Scope |
| --- | --- |
| M0 | Packaged-worker startup, assets, local pipes, lifecycle and copied-development-bundle feasibility |
| M1 | Document integrity, native reading/settings/tabs, save/close and responsiveness |
| M2 | Multiplexed IPC, task fairness, cancellation/draining, restart and stale-result isolation |
| M3 | Offline provider/prompt composition, output validation and message/privacy canaries |
| M4 | Bounded opt-in real-provider semantic, compatibility, latency and cost evidence |
| M5 | Signed/notarized distribution, minimum OS, clean-machine installation, upgrades and accessibility |

Acceptance is cumulative but reported per check and tested revision. Fixtures do not qualify real models, and copied development bundles do not qualify a clean Mac. Use [current validation status](validation.md) and [open-source preparation](open-source-preparation.md) for remaining release work.

## Working commands

Run script/setup.sh once per checkout. Run script/check.sh for the default offline suites, packaged-worker checks and native build. It requires full Xcode, uv and a macOS window session for native package tests. See [Tests/README.md](../Tests/README.md).

Use script/build_and_run.sh for a development launch and script/build_dmg.sh --development for an explicitly ad-hoc local package. Formal tag builds and publication follow [releasing](releasing.md). A bounded real-provider verifier remains separate from default tests; never expose credentials or infer a live pass from a fixture.

Write technical outcomes and limitations to the owning document. Keep complete execution logs and temporary reports in .local/; long-lived private material stays outside the checkout. A milestone or command description is not a publication action.
