# Changelog

## Unreleased

## 0.2.0 (2026-11-22)

### Added

- Open or paste Markdown, read the original and translation with their formatting, and export the translated Markdown. Code, commands, and link destinations stay intact.
- Switch a tab to Translation Reader for a translation-only view. Return to a paired layout at the same reading position, or copy the completed translation from the reader.
- Choose a reading theme in Settings and apply it across open documents.

### Changed

- New installations start with an empty model list. Add your own connection to start translating. Upgrades retain saved connections and the active model.
- The installer checks the candidate before replacing Bipara in Applications and refuses to overwrite a running app or install an older build.

### Fixed

- Translation accepts reordered response rows by matching their unit IDs. If a batch has missing or repeated IDs, Bipara retries the affected units within a bounded request budget and keeps completed work.
