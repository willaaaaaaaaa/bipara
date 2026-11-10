# Open-source readiness

## Delivery contract

Bipara is an LLM-powered native macOS translation and bilingual reading app. It uses the MIT license and initially targets Apple Silicon. Source publication and formal installer qualification are separate gates. Every formal version requires a protected `vMAJOR.MINOR.PATCH` tag and an installable GitHub Release DMG built from that tag. Experimental maturity is disclosed independently of whether an installation package is provided.

## Source publication gates

| Area | Required result |
| --- | --- |
| Public content | Current engineering contracts, portable setup, concise validation status and required attribution; no credentials, personal workflows or unused selection assets |
| History and identity | Every intended commit/tag and its author, committer or tagger identity reviewed before upload |
| Upload prevention | Worktree, index and outgoing-commit checks; pinned secret detection; local hooks and required CI |
| Reproducibility | Default checks and native build from documented public inputs without developer-specific configuration |
| Contributor setup | Discoverable, repeatable setup that preserves existing hooks and security-rule selections, explains external writes and does not require a maintainer's personal storage layout |
| Documentation | English primary README, Chinese companion, contribution instructions, privacy/security notices, MIT license and working links |
| Hosted repository | Required checks, protected branches/tags, private vulnerability reporting and release environments configured and verified |

The [repository boundaries](repository-boundaries.md) define content handling and checks. The [validation status](validation.md) records tested scope and remaining gaps; the existence of a checker or workflow is not evidence that it passed.

Issue templates and [support guidance](../SUPPORT.md) provide contributor entry points. Dependabot is configured to propose weekly GitHub Actions and worker dependency updates; proposals require review and CI, with no automatic merge. Before publication, verify the chosen vulnerability-reporting channel, dependency alerts, secret scanning and push protection on the actual repository, following [GitHub's repository guidance](https://docs.github.com/en/repositories/creating-and-managing-repositories/best-practices-for-repositories).

## Formal release gates

| Area | Required result |
| --- | --- |
| Product | [App functional acceptance](testing.md#app-functional-acceptance), including document integrity, retained-job configuration safety, reading, tabs and app-owned controls |
| Providers | Bounded real-provider checks for semantic quality, compatibility, latency and cost |
| Runtime and licenses | Qualified bundled Python build, verified dependency provenance and complete required notices |
| Packaging | Version/tag consistency, valid nested code signatures and an explicit tagged distribution policy; initial ad-hoc packages disclose missing Developer ID/notarization |
| Installation | Clean installation, upgrade and minimum-OS acceptance against the exact final DMG checksum |
| Delivery | Protected tag build produces a draft; publication verifies the exact assets and installation declarations |

Follow [the release procedure](releasing.md) for commands and package acceptance. Default offline tests do not establish real-provider, native UI or distribution qualification. Keep full execution logs and captures out of tracked documentation; record concise outcomes and limitations in the validation status.

## External prerequisites and authorization

The initial ad-hoc distribution requires no Apple membership or signing secrets. A future Developer ID/notarization policy requires an eligible account and credentials. Repository rulesets, protected release environments, private vulnerability reporting and immutable releases require actual repository configuration. Source changes do not establish those settings. Real-provider checks require eligible accounts, synthetic inputs and an explicit request/cost cap.

Repository creation, remote pushes, visibility changes, history rewriting and publication require an instruction covering those actions. This checklist does not perform or authorize them.
