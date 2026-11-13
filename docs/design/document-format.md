# Local Document Format

A `.bipara` file is a single UTF-8 JSON object. Open reads versions 1–3 and explicit Save writes version 3. The [schema 3 extension](#schema-3-for-markdown) adds Markdown format and plan metadata to the shared records below.

Required root keys: `format`, `schema_version`, `document_id`, `title`, `source`, `source_revision`, `direction`, `paragraphs`, `units`, `translations`, `job_snapshot`, `layout`, and `reading_anchor`. Nullable values are written explicitly as null. Unknown extra fields within a supported version may be ignored; a schema_version above 3 is rejected without rewriting the original. Save only the known canonical fields.

| Field | Type / meaning |
| --- | --- |
| `format`, `schema_version` | Literal `bipara`, integer `2`; integer `1` is read through the migration below |
| `document_id` | UUID; preserved across saves; a tab gets a separate fresh runtime session ID |
| `title` | Nonempty single-line string, up to 256 Unicode characters; existing saved titles are preserved; new automatic titles follow the meaningful-line/imported-filename and numbered Untitled rules in [interaction](interaction.md#default-titles-and-elapsed-time) |
| `source` | Exact string, initially at most 1 MiB UTF-8 |
| `source_revision` | Nonnegative integer, incremented on applied source/direction changes |
| `direction` | `requested`: `auto`/`zh_to_en`/`en_to_zh`; `resolved`: null/`zh_to_en`/`en_to_zh` |
| `paragraphs` | Ordered paragraph records below |
| `units` | Ordered unit records below |
| `translations` | Completed unit records only, in source order |
| `job_snapshot` | Null before any job, otherwise the immutable job configuration below |
| `layout` | `side_by_side` or `paragraphs` |
| `reading_anchor` | Null or `{paragraph_id, side, fraction}`; side is `source`/`translation`, fraction is a finite number in [0,1] |

All ranges are `{location, length}`, nonnegative integers in UTF-16 units, with checked addition and valid composed-character boundaries. Paragraph fields are `id`, `source_range`, `separator_range`, and `unit_ids`. Separator ranges contain only the actual trailing CR/LF sequence; a final paragraph may have length zero there. A whitespace-only paragraph has no unit IDs. Leading separators may belong to a zero-length source paragraph. Do not fabricate a trailing empty paragraph after a separator.

Unit fields are `id`, `paragraph_id`, `source_range`, `text_range`, and `kind` (`sentence`/`fragment`). Its full source range participates in the paragraph partition; text_range lies within it and contains the trimmed model input. The difference is preserved boundary whitespace. Derive whitespace strings from source/ranges rather than serializing duplicates. Nonblank units must have nonempty text_range.

Translation fields are `unit_id`, `text`, nullable `returned_model`, and `completed_at` (UTC ISO-8601 timestamp). Global requested provider/model/profile/effort and prompt attribution live once in job_snapshot because one document revision has one translation job snapshot. No placeholder, pending result, or speculative correspondence is saved. Target strings obey the same validation as model results; translated ranges are rebuilt deterministically on open.

Open-profile snapshots additionally require `configuration_revision`, a nonsecret UUID identifying the exact saved request settings. Legacy snapshots omit it. Snapshot fields are `job_id`, `source_revision`, `source_language`, `target_language`, `provider`, `model`, `profile`, `effort`, `translation_prompt_version`, and `alignment_prompt_version`. Language codes are `zh`/`en`, distinct. Its source revision and direction must match the document. Completed-unit membership is derived from translations, not a second serialized list. A snapshot with an unavailable old prompt/profile still opens for reading, but Resume is disabled with an explicit Retranslate option; do not silently substitute a current prompt.

V2 adds required snapshot `effort`, one of the canonical [configuration values](model-settings.md#effort-capabilities-and-wire-mapping), validated against its profile/model. A v1 file has no effort: derive Auto for `openai-json-schema-v1` and Off for `glm-json-v1`, preserving the original profile, IDs, revision, text, units and results. Unknown old profiles remain readable but unavailable for model calls; use Auto only as unspecified attribution, never infer a supported execution profile. Migration is in memory; opening does not rewrite the original or mark it dirty. An explicit later Save writes schema 3 with the derived effort. Unknown future schemas still fail without rewriting.

The endpoint and local configuration identity are intentionally absent. Before Resume or uncached phrase analysis on an opened file, require the explicit session-local binding described in [model configuration](model-settings.md#runtime-snapshots-credentials-and-portable-documents), matching provider/model/profile/effort and the open-profile configuration revision, and disclosing the actual selected request host. The revision rotates on effective connection/generation edits, so a recreated lookalike entry cannot silently resume an old job. Request options, header values and credentials are never exported. Loading a file, binding a configuration or reading completed text makes no network call. A v1 file saved as v2 retains its legacy profile and effective effort; do not silently upgrade its request contract.

Example of one complete v2 document:

```json
{
  "format": "bipara",
  "schema_version": 2,
  "document_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "title": "The window is open.",
  "source": "The window is open.\n",
  "source_revision": 1,
  "direction": {"requested": "en_to_zh", "resolved": "en_to_zh"},
  "paragraphs": [
    {
      "id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      "source_range": {"location": 0, "length": 19},
      "separator_range": {"location": 19, "length": 1},
      "unit_ids": ["cccccccc-cccc-4ccc-8ccc-cccccccccccc"]
    }
  ],
  "units": [
    {
      "id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      "paragraph_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      "source_range": {"location": 0, "length": 19},
      "text_range": {"location": 0, "length": 19},
      "kind": "sentence"
    }
  ],
  "translations": [
    {"unit_id": "cccccccc-cccc-4ccc-8ccc-cccccccccccc", "text": "窗户开着。", "returned_model": null, "completed_at": "2026-10-31T08:00:00Z"}
  ],
  "job_snapshot": {
    "job_id": "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
    "source_revision": 1,
    "source_language": "en",
    "target_language": "zh",
    "provider": "openai",
    "model": "gpt-4.1-mini-2025-04-14",
    "profile": "openai-json-schema-v2",
    "effort": "auto",
    "translation_prompt_version": "translation.v1",
    "alignment_prompt_version": "alignment.v1"
  },
  "layout": "side_by_side",
  "reading_anchor": {"paragraph_id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "side": "source", "fraction": 0.0}
}
```

Before loading: cap the file at 20 MiB, require strict UTF-8/JSON, use the shared Core strict preflight to reject duplicate decoded keys before Codable, and reject non-finite numbers, validate all types/UUIDs and references, and verify paragraph/unit partitions against the actual source. Reject duplicate IDs/translations, out-of-bounds ranges, half-surrogate or partial-grapheme ranges, wrong snapshot direction/revision, or translations without a snapshot. Do not trust stored counts or a claimed schema version as validation. An invalid optional reading anchor may be reset to the first paragraph; invalid content cannot be silently repaired.

The input-draft save/apply/confirmation rules live in [native design](technical-design.md#local-files-and-close-behavior): saving an unsubmitted draft first commits its current text/direction locally, not an older canonical source. An empty draft may be saved with empty source, empty arrays, null snapshot/resolved direction/anchor. A nonempty untranslated document still has its validated paragraph/unit plan. Partial translated paragraphs retain individual completed units for later resume, although the reader waits for the paragraph to complete before displaying its assembled translation.

No credentials, Keychain references, display aliases, local configuration IDs, local filesystem paths, endpoint overrides, global settings, active request identifiers, or phrase caches belong here. Save/Open must work offline without the worker. Source and translation are plain text; loading cannot execute HTML, scripts, shell fragments, or model tools.

Source revisions must be nonnegative and less than the platform integer maximum. Editing an exhausted revision returns a local error rather than overflowing.

## Schema 3 for Markdown

Schema 3 adds the following root fields to the shared records above.

| Field | Contract |
| --- | --- |
| `content_format` | Object containing `requested` (`auto`, `markdown` or `plain_text`), `resolved` (`markdown` or `plain_text`) and nullable `detector_version`. Explicit choices match the resolved format. Auto records the detector version. |
| `reading_mode` | `rendered` or `source`. Plain text uses `source`. |
| `markdown_plan_version` | `markdown-plan.v2` for new Markdown plans; supported v1 documents retain their instance version and original unit identities until explicit retranslation. Null for plain text. |
| `paragraphs`, `units` | Plain-text records retain their old validation. Markdown stores the stable block and unit IDs and the exact source ranges used to rebuild its plan. Several fragments may share the range of one normalized inline payload. The payload itself is derived. |
| `reading_anchor` | The shared `paragraph_id`, `side`, `fraction` anchor also accepts optional `section_id` and UTF-16 `offset` for Markdown. The paragraph ID identifies the logical Markdown block. |
| `translations`, `job_snapshot` | A completed translation references a unit in the active plan. Markdown jobs record the Markdown prompt version. A document containing only copied literals has an empty result list and no job snapshot. |

The decoder rebuilds a supported Markdown plan with the pinned parser and verifies ordered block ranges, unit ownership, unit kinds and references before restoring persisted UUIDs. It validates result text and assembled structure against that plan. The root source string contains every original byte, including syntax between blocks. The file does not serialize a library AST, a second plan, renderer state or credentials.

Versions 1 and 2 open in Plain Text with their existing IDs and results, even when their source contains Markdown. Applying a different resolved format creates a new revision through the format-replacement confirmation. Auto documents reopen in their saved resolved format. Changing a format choice that resolves to the same supported format keeps the source revision.

An unavailable Markdown plan version opens as literal source and literal stored results. The original file bytes are preserved on save until an explicit edit or replan replaces it. Resume, phrase analysis and structured export require a supported plan. Unsupported outer file schemas fail to open. File and input limits remain 20 MiB and 1 MiB respectively, and opening or saving a local document requires no worker.
