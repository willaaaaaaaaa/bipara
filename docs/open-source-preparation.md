# Open-source preparation plan

## Delivery contract

Bipara uses the MIT license and initially targets Apple Silicon. Every formal
version has a protected `vMAJOR.MINOR.PATCH` tag and an installable GitHub Release
DMG built from that tag. Experimental maturity is disclosed independently of
whether an installation package is provided. Initial public history starts from
a reviewed source snapshot. Pre-publication history remains a private read-only
archive, outside the ancestry of public commits. Ongoing development uses one
canonical code history under the [repository boundaries](repository-boundaries.md).

## Implementation and acceptance

| Area | Deliverable | Acceptance |
| --- | --- | --- |
| Content boundaries | Public engineering contracts; enduring non-secret personal context in private knowledge; temporary material in ignored `.local/`; raw evidence and archives outside the checkout | Public checkout needs no private resources; local setup and content checks exclude private material |
| Upload prevention | Worktree, index, commit-range and author checks; local hooks; required CI | Synthetic repositories demonstrate blocked paths, secrets, private context and commit identities without printing matched data |
| Public documentation | Portable agent and contribution rules, privacy/security notices, MIT license, concise validation status | Link, symlink and content checks; detailed execution records remain private |
| Document integrity | Safe source revisions, bounded text import, preservation of copied fragment gaps and close/save generations | Focused Swift regressions and the offline suites |
| Retained jobs | Local jobs retain their original endpoint; changing services requires explicit Retranslate; opened portable files require explicit binding | Configuration-loss and portable-file regressions |
| Packaging | Version/tag consistency, bundled runtime licenses, nested Developer ID signing, DMG notarization and stapling | Offline orchestration tests plus actual signed-package qualification |
| GitHub delivery | Unprivileged PR checks; protected tag build produces a draft; separate publication verifies exact assets and installation declarations | Workflow validation and a release-candidate rehearsal |

## Order

1. Review the existing boundaries, upload checks, integrity regressions and release
   tooling. Preserve useful public contracts and third-party attribution.
2. Preserve the old Git database, dirty source and required local configuration in
   an external recovery archive. Verify an isolated restoration. A Git bundle alone
   does not preserve uncommitted or ignored files.
3. Export only the reviewed public file list to an isolated checkout, preserving
   executable bits and relative symlinks. Select a public identity and create the
   initial commit without old parents, refs or private remote configuration.
4. Run default checks and a native build without private notes, local configuration
   or knowledge-service access. Verify the snapshot against the selected source.
   Switch the canonical checkout only after these checks and recovery pass; retire
   preparation copies after confirming they contain no unique work.
5. Under a publication instruction, configure GitHub protections and the public
   remote, then push only reviewed refs. Verify actual hosted checks and settings.
6. Qualify Developer ID signing, notarization, minimum-OS installation and upgrades
   against the final package. Rehearse and publish a formal tag and DMG under a
   release instruction, following [the release procedure](releasing.md).

Keep one active code history after migration. An optional backup remote stores the
same publishable history; the old private archive is never merged into it. A failed
migration is recovered from the verified archive before further writes. Current
mechanisms and observed acceptance remain distinct in [validation status](validation.md).

## External prerequisites

Developer ID Application credentials and notarization access, repository rulesets,
protected release environments, private vulnerability reporting and immutable
releases require account/repository configuration. Source changes do not establish
that these settings exist. Every commit and tag intended for publication needs
content and identity review; the private historical archive is excluded. This plan
does not authorize rewriting the archive or creating a public remote.

Real-provider checks use eligible endpoint-scoped accounts, synthetic text and an
explicit request/cost cap. They are separate from default CI and package smoke
tests. Installation declarations refer to the exact final DMG checksum, not a
development build. No offline test substitutes for those qualifications.

Keep execution logs, screenshots, receipts and full review narratives in `.local/`
or outside the repository. Record only concise current outcomes and limitations in
[validation status](validation.md).
