# Prompt Contract

These UTF-8 assets own prompt behavior and output schemas. Changes to prompts, examples, model parameters or repair behavior require a corresponding versioned design and evaluation update. Implementations load the canonical assets without silently rewriting them.

| Operation | System message | Output schema |
| --- | --- | --- |
| `translate` (new jobs: `translation.v2`) | [translation.v2.txt](translation.v2.txt) | [translation-output.v1.schema.json](translation-output.v1.schema.json) |
| `translate` (retained `translation.v1` jobs) | [translation.v1.txt](translation.v1.txt) | [translation-output.v1.schema.json](translation-output.v1.schema.json) |
| `align` | [alignment.v1.txt](alignment.v1.txt) | [alignment-output.v1.schema.json](alignment-output.v1.schema.json) |

Use exactly two model messages: the system asset verbatim, then a user message containing the JSON serialization of the operation's `input` object from [worker protocol](../docs/design/worker-protocol.md). Use UTF-8 with `ensure_ascii=False`; ordinary JSON escaping is required. Do not interpolate document strings into a template or system message. A LangChain prompt may bind one `{payload}` variable to the already serialized JSON string; the system asset is a literal `SystemMessage`, not a format template containing JSON braces.

Serialize these logical messages as Responses `input`, Messages top-level `system` plus user `messages`, or retained Chat Completions `messages`, without changing asset/payload text. Use a fresh invocation with no conversation history, memory, tools, search, or retrieval. Never include the API key, local path, clipboard metadata, tab title, app language, appearance, or UI state in a model message. App interface language is independent of translation direction.

Output schemas are deliberately a small JSON Schema subset compatible with the selected OpenAI structured-output profile. They describe shape. [Model workflow](../docs/design/model-workflow.md) additionally requires exact ID coverage, order, UTF-8 budgets, nonempty values, legal statuses, literal quote resolution, and range/meaning checks. Shape validation does not establish translation quality or semantic alignment.

`translation.v2` is the current translation prompt; `alignment.v1` is the current alignment prompt. Versioned prompt files are runtime assets, not a changelog. Both supported translation prompts use the v1 output schema because their output shape is identical. Package these assets from this directory; do not maintain a second edited copy in Swift/Python source. The build records their SHA-256 hashes. New jobs capture v2; retained v1 jobs dispatch the unmodified v1 asset on every batch, Retry and Resume. Explicit Retranslate captures the current version. A semantic prompt/schema change creates a new version and requires a new provider evaluation; it must not mutate a running job or silently reinterpret a saved one. Mechanical packaging must preserve asset bytes.

V2 makes logical scope, complete clauses/enumerations, and protected technical syntax explicit. Natural-language headings, labels and descriptive values are translated; configuration keys, identifier values, executable code and Markdown syntax remain literal. Plain text describes each output string, not permission to strip markup. Paragraph separators and outer indentation remain application-owned. A silent comparison within the same response checks conditions, omissions and literals without adding another model call or output field.

[cases.json](cases.json), corpus version 2, contains 20 translation and six alignment cases with original synthetic inputs, valid example outputs, and review expectations. T07–T10 cover logical scope and fragments; T11–T14 cover omissions and distinctions; T15–T20 cover frontmatter, Markdown, links, code and configuration. `literal_checks` specify exact literal, prefix, substring or occurrence-count invariants per unit. Logical truth tables and `semantic_checks` require review of actual translations. Example outputs establish an admissible shape and meaning, not an exact-string oracle for a live model. Do not send these examples in ordinary production calls. Test transport with their fixed outputs, and evaluate live responses using the specified semantic checks.

Prompt fixtures use short readable unit IDs. When exercising the application IPC, map them to deterministic UUIDs in both the input and expected output; keep the case ID separately. This preserves the same prompt case without weakening the protocol's identity validation.

No extra repair call, translation critique loop, back-translation, or model-based grading is introduced. Validation failure returns a typed error; uncertain correspondence returns a labeled larger match. Offline fixture tests validate packaging, dispatch and sample invariants; they do not establish that a provider obeys v2. The separate [v2 acceptance gates](../docs/testing.md#translation-prompt-v2) own live semantic acceptance.

The [validation status](../docs/validation.md) records executed offline/build evidence and pending live acceptance.
