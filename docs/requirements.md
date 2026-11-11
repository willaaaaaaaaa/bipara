# Product Requirements

The tables below define current product behavior. See [validation status](validation.md) for evidence and limitations.

## Objective

Provide a native macOS translation and bilingual reading app powered by large language models (LLMs). Make long Chinese and English texts comfortable to translate and read together, with useful correspondence between the original and translated passages.

## Confirmed requirements

| ID | Requirement |
| --- | --- |
| R1 | Translate Chinese to English and English to Chinese from long text input. |
| R2 | Keep source and translated content visible together. |
| R3 | Provide a side-by-side layout with source on the left and translation on the right. |
| R4 | Provide a paragraph-based layout showing source and translated paragraphs together in a single alternating reading flow. |
| R5 | Hovering over source text or selecting words/phrases should reveal corresponding translated content. Exact granularity and fallback behavior need validation. |
| R6 | Deliver a native macOS app first, targeting macOS 26 and 27 on Apple Silicon, plus macOS 26 on compatible Intel Macs with minimum deployment version 26.0. Acceptance covers the maintainer's local OS only; users verify compatibility on other target systems. Preserve the possibility of later iPad/iPhone versions. |
| R7 | Run business logic locally with the app, without a separately deployed local or cloud server. |
| R8 | Use one custom model form with Name, Protocol, Model ID, Reasoning Effort, API Base URL and API key, in that order. New text fields start empty for manual entry; protocol offers OpenAI Responses and Anthropic Messages, and effort offers Off, Low, Medium and High. Remove presets, vendor/catalog controls and advanced settings; preserve existing configurations/jobs. |
| R9 | Trial LangChain first; consider explicit LangGraph orchestration later if a concrete need appears. |
| R10 | Use a dedicated repository with a documented contribution and independent review workflow. |
| R11 | Use MIT licensing, public-safe contents and tagged formal releases with installable DMGs. |
| R12 | Use Swift for native presentation and Python for LangChain integration. Bundle Python with the app and launch a child process on demand over pipes, with no listener or user-installed runtime. |
| R13 | Use English as the default product and project language, with an English primary README and a Chinese companion README. Translation content remains bilingual. |
| R14 | Provide a dedicated Settings interface for model configuration, interface language, translation direction (Automatic by default), and reading preferences such as typography. Keep frequent layout and active-model switching on the reading surface. |
| R15 | Support multiple independent translation documents in tabs, with add, switch, and close actions. Multiple documents can translate concurrently without mixing their contents, results, or task state. |
| R16 | Support System, Light, and Dark appearance in Settings. Default to System; apply changes across app windows without altering documents, task state, or reading position. |
| R17 | Manage multiple independent named model configurations, including multiple instances per vendor. List instance name, vendor, exact model and effort. Select one Active Model from saved instances in Settings or from a picker to the left of Translate. Preserve existing configurations and credentials, and keep retained job snapshots stable. |
| R18 | Expose exactly one localized Settings app-menu command and Command-comma shortcut, with a consistently localized Settings window title. |
| R19 | Keep translation progress out of reading text: remove repeated Original/Translation labels in Paragraphs mode and repeated untranslated messages during translation. Distinguish source and translation without relying on color alone. |
| R20 | Use more of a wide reading window in both layouts so each line can contain more text. Preserve readable typography, correspondence and reading position. |
| R21 | Give every document a useful default title and show compact, document-specific translation elapsed time. |
| R22 | Default to appearance-adaptive Amber correspondence highlights in Light and Dark, and allow choosing a highlight color in Reading settings. Preserve native text selection and explicitly saved color choices. |
| R23 | Add an opt-in setting that skips the document save prompt on close. Make the resulting discard behavior explicit. |

Reading preferences retain the global Active Model and explicit interface-language contracts. Detailed current behavior is owned by [interaction](design/interaction.md) and [model configuration](design/model-settings.md).

## First-release implementation baseline

The detailed design adopts the following behavior within the confirmed scope; implementation and acceptance evidence are reported separately:

- Paste plain text or import UTF-8 `.txt`. Detect the input language locally by default, with an explicit direction available in Settings.
- Retain paragraph boundaries and original text. Offer both layouts without losing the current reading position or re-running translation.
- Link scrolling by paragraph identity rather than raw scroll percentages, since translated lengths differ.
- Use paragraph correspondence as the stable base. Add sentence mapping and on-demand phrase mapping against the existing translation.
- Support correspondence in both directions. Hover uses available mappings; a selection may request additional analysis and show progress.
- Where a precise phrase correspondence cannot be established, explain the limitation and highlight a larger relevant passage. Do not imply that every word has a unique translated equivalent.
- Show completed translation segments progressively; allow cancellation and retry of failed work.
- Save/Open local `.bipara` documents and provide copy/plain-text export under the [document and storage design](design/document-format.md).

PDF/Word parsing, OCR, webpage extraction, automatic session recovery, cloud synchronization, shared accounts, billing, and autonomous multi-agent editing are outside the first-release scope. Adding them requires a scoped product decision.

## Text and task integrity

Long text may contain one oversized paragraph. Internal request splitting must preserve the original presentation and account for input, output, and correspondence length limits.

Correspondence can be one-to-many, many-to-one, non-contiguous, or absent. Keep document revision and passage identity with each translation/mapping result. Source or translation edits invalidate affected mappings, and late responses must not overwrite newer revisions.

Model output is untrusted data. Validate its structure and resolve spans against the actual source and translated text. Structural checks can prevent invalid ranges but do not prove semantic correctness. Repeated phrases, punctuation, mixed Chinese/English text, and Unicode sequences need explicit evaluation.

## Acceptance evidence for the first working version

| Area | Evidence to collect |
| --- | --- |
| Translation | Representative texts in both directions, checking omissions, meaning, terminology, and paragraph preservation |
| Layout | Actual macOS interaction in both modes at multiple window sizes and text sizes |
| Correspondence | Clear and ambiguous examples, repeated text, reordered phrases, and honest fallback behavior |
| Long text | No missing/duplicated passages after splitting; measured responsiveness and documented tested size limits |
| Task lifecycle | Cancellation, partial failure/retry, edits during requests, and stale-response protection |
| Multiple documents | Independent drafts, progress, results, layout and pinned correspondence; background completion while switching tabs; closing one tab cannot cancel or overwrite another |
| Providers | Real calls for OpenAI, Kimi, GLM and DeepSeek with eligible accounts, plus deterministic offline tests for request/response handling |
| Configuration | Keys/endpoint overrides absent from exports/logs; independent model entries and credentials; correct endpoint/effort mapping; offline migration; no reliance on developer-local configuration |
| Settings | Independent model management and shared active selection in Settings and the toolbar. Unique localized menu/shortcut/title, saved direction independent of interface language, draft cancellation and stable job snapshots. |
| Appearance | System-default behavior and explicit Light/Dark overrides across windows, text, selection and correspondence; runtime switching preserves reading/task state |
| Portability | Shared logic isolated from macOS UI; mobile feasibility assessed separately from Mac acceptance |

Use synthetic or redistributable evaluation texts. A mock provider test is not evidence of real-provider quality, latency, or availability. The detailed design specifies initial engineering bounds and evaluation targets; claim actual supported performance only after measuring the relevant prototype/app. See the [test plan](testing.md) for traceable checks and evidence boundaries.
