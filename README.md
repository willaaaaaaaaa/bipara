# Bipara

English · [Simplified Chinese](README.zh-CN.md)

Bipara is a large language model (LLM)-powered native macOS app for translation and bilingual reading, built for long Chinese and English texts. Read in side-by-side panes or alternating paragraphs, select text to find corresponding passages, and work with independent documents in tabs.

Bipara uses Swift for native presentation and document/task logic, plus a bundled Python worker with LangChain. End users do not install Python or run a server. Model connections use OpenAI Responses or Anthropic Messages, with a custom form for name, protocol, model ID, effort, API Base URL and API key. Users choose compatible models and parameters; provider calls require network access, an eligible account and may incur charges.

Status: experimental source preview. This README does not announce a public release or a qualified installer. Real-provider semantic quality, latency and cost are not fully qualified; native UI and accessibility acceptance is incomplete.

## Install and use

For source builds, follow the development instructions below. Source-readiness requires public-content, history and identity review, plus offline regression checks; their current results and blockers are in [validation status](docs/validation.md).

Every public installer must have a protected version tag and an arm64 DMG qualified for clean installation, upgrade and minimum-OS use against its exact checksum. The initial distribution uses ad-hoc signing without Apple notarization or a verified Developer ID. macOS may require a per-app Open Anyway exception; see [installation and trust](docs/releasing.md#install-and-publish). No qualified download is available yet.

Open Settings, add a model configuration with its exact model, API Base URL and key, and choose an Active Model. Paste text or open a UTF-8 .txt file, then translate. Switch reading layouts without retranslating. Save editable work as .bipara or explicitly export/copy text. Read [Privacy](PRIVACY.md) before sending documents.

Platform target: Apple Silicon and macOS 14+. Tested environments and minimum-OS qualification are listed separately; the deployment target alone is not acceptance. VoiceOver, keyboard-only workflows, Increase Contrast and Reduce Motion still require complete native acceptance; offline fixtures do not establish it.

## Develop

Requirements: full Xcode, Python 3.12+ for tooling and uv. The worker uses the frozen CPython 3.13 environment. Native package/UI tests require a macOS window session. No provider key is needed for default checks.

```sh
script/setup.sh
uv sync --project Worker --frozen --group dev
script/check.sh
script/build_and_run.sh
script/build_dmg.sh --development
```

Local setup installs Git hooks and pinned check tools for this checkout. Select a public Git author identity before committing. See [Contributing](CONTRIBUTING.md) for setup details and [repository boundaries](docs/repository-boundaries.md) for handling development artifacts and credentials.

The check script runs public-content/tooling checks, worker packaging, Swift and Python offline suites, then a native build. Native UI, real-model and actual distribution checks are separate. See [Tests/README.md](Tests/README.md). Formal tag builds use [the release procedure](docs/releasing.md), including the installation gate before a draft becomes public.

## Project documentation

| Document | Purpose |
| --- | --- |
| [Requirements](docs/requirements.md) | Product behavior and acceptance boundaries |
| [Architecture](docs/architecture.md) | Module/runtime ownership and detailed contracts |
| [Design principles](docs/design-principles.md) | Simplicity, native presentation and trade-offs |
| [Development plan](docs/development-plan.md) | Contract read order and delivery gates |
| [Open-source readiness](docs/open-source-preparation.md) | Source publication and installer qualification gates |
| [Prompts](prompts/README.md) | Canonical assets, schemas and synthetic evaluation corpus |
| [Contributing](CONTRIBUTING.md) | Contribution and review workflow |
| [Support](SUPPORT.md) | Bug reports, feature requests and usage questions |
| [Security](SECURITY.md) | Private vulnerability reporting and support boundary |

The [icon provenance](docs/design/icons/README.md) records the current artwork's source. Build output stays ignored; use script/clean.sh --dry-run before cleaning.

## License

[MIT](LICENSE) for project-owned work. Preserve dependency and asset attribution. [Worker notices](Worker/THIRD_PARTY_NOTICES.md) describe license collection. Complete licensing for external dylibs and legal compatibility remain unverified. See [validation status](docs/validation.md).
