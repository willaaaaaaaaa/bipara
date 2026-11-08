# Contributing

Start with [AGENTS.md](AGENTS.md), the [requirements](docs/requirements.md) and the [development plan](docs/development-plan.md). Human and automated contributions use the same contracts.

## Workflow

1. Describe the concrete problem and proposed behavior. Discuss consequential product/runtime changes before implementation.
2. Update the owning design when its contract changes. Keep changes focused; preserve document identity, credential isolation and native reading behavior.
3. Implement and add regressions for meaningful behavioral risks.
4. Open a focused pull request with behavior, relevant validation and unresolved limitations. Review against the design and tests; fix accepted findings.
5. Repeat only checks affected by subsequent changes or unresolved failures.

Use separate worktrees for parallel implementation, with an integration owner. Public PRs, comments and commit messages contain technical outcomes rather than private coordination, account details or full execution narratives.

## Local setup and checks

Run `script/setup.sh` to prepare ignored scratch directories, enable pre-commit/pre-push hooks and install checksum-pinned Gitleaks and actionlint in an external cache. It is safe to repeat with the same valid configuration. Initial tool installation requires access to official GitHub releases. Setup preserves configured private-rule files and stops before writes if a selected file is invalid or custom hooks need manual integration. It does not install app dependencies or create a private archive. See [repository boundaries](docs/repository-boundaries.md#local-setup-and-storage) for write locations and optional rules.

Select a public Git author identity before committing. New project commits use GitHub noreply identities; see [identity checks and exceptions](docs/repository-boundaries.md#enforcement).

Run script/check.sh. See [Tests/README.md](Tests/README.md) for prerequisites and separate native UI checks. Default checks make no provider calls. Keep credentials, real documents and full logs out of PRs and CI artifacts.

The content checker inspects the actual index at commit time and every outgoing commit before push. Hooks are local and bypassable; required CI and release checks provide additional enforcement. CI cannot retract already uploaded material. Follow [repository boundaries](docs/repository-boundaries.md).

Follow the [documentation and asset rules](docs/repository-boundaries.md#current-documentation-and-history). Keep each prose paragraph and logical list item on one source line, relying on editor soft wrapping; preserve structural and code newlines.

Use the issue templates for bug reports and feature requests; [Support](SUPPORT.md) explains where to ask questions and report vulnerabilities. Automated dependency PRs require review and the same checks as other changes; update the worker lockfile with its manifest, retain pinned Action revisions, and review runtime/license effects before merging. Worker updates use the [uv Dependabot integration](https://docs.astral.sh/uv/guides/integration/dependabot/).

## Licensing and releases

Contributions are made under the [MIT license](LICENSE). Preserve third-party attribution and compatible terms. Release work follows [releasing](docs/releasing.md); formal versions require a tagged, signed, notarized and installation-qualified DMG.
