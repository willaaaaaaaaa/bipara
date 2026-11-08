# Contributing

Start with [AGENTS.md](AGENTS.md), the [requirements](docs/requirements.md) and the
[development plan](docs/development-plan.md). Human and automated contributions use
the same contracts.

## Workflow

1. Describe the concrete problem and proposed behavior. Discuss consequential
   product/runtime changes before implementation.
2. Update the owning design when its contract changes. Keep changes focused;
   preserve document identity, credential isolation and native reading behavior.
3. Implement and add regressions for meaningful behavioral risks.
4. Open a focused pull request with behavior, relevant validation and unresolved
   limitations. Review against the design and tests; fix accepted findings.
5. Repeat only checks affected by subsequent changes or unresolved failures.

Use separate worktrees for parallel implementation, with an integration owner.
Public PRs, comments and commit messages contain technical outcomes rather than
private coordination, account details or full execution narratives.

## Local setup and checks

Run script/setup_local.sh to create ignored temporary storage and install local
pre-commit/pre-push checks with checksum-pinned Gitleaks and actionlint in an
external cache. Initial setup requires access to their official GitHub releases.
Existing custom hook configuration is preserved and
requires manual integration. New project commits use GitHub noreply identities;
reserved example addresses are accepted only for synthetic tooling fixtures.
Other author/committer addresses stop for explicit publication review. After
review, set `BIPARA_APPROVED_COMMIT_EMAIL` to the exact approved address for
the commit and push checks. This exception also applies to history checks run
with that environment; CI needs the same reviewed setting when applicable.

Run script/check.sh. See [Tests/README.md](Tests/README.md) for prerequisites and
separate native UI checks. Default checks make no provider calls. Keep credentials,
real documents and full logs out of PRs and CI artifacts.

The content checker inspects the actual index at commit time and every outgoing
commit before push. Hooks are local and bypassable; required CI and release checks
provide additional enforcement. CI cannot retract already uploaded material.
Follow [repository boundaries](docs/repository-boundaries.md).

## Licensing and releases

Contributions are made under the [MIT license](LICENSE). Preserve third-party
attribution and compatible terms. Release work follows [releasing](docs/releasing.md);
formal versions require a tagged, signed, notarized and installation-qualified DMG.
