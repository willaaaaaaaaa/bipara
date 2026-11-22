# Translation Workflow

Numeric limits are engineering bounds and evaluation targets. Use named constants and change the owning contract and tests when prompt, batching, profile or retry semantics change.

Batch planning is bounded to 64 units / 8,192 UTF-8 bytes / 32 KiB serialized input. One document session may hold up to two concurrent translation batches inside four global concurrent model operations. The v2 plain output caps are 8,192/2,048 tokens; both legacy profiles keep 4096/1024. These limits bound local admission and provider work; they do not guarantee provider latency.

New model configurations follow the [model configuration design](model-settings.md). Open profiles fix OpenAI to Responses and Anthropic to Messages with user-selected options. V1/v2 profiles below remain compatibility contracts for saved configurations and retained jobs. See the [validation report](../validation.md) for implementation and provider acceptance evidence.

New plain-text jobs use `translation.v3`. Retry and Resume use the prompt recorded in the job. Plain-text v3 and Markdown v4/v5 distinguish exact lookup names from translatable labels, resolve idioms and terminology in context, and retain the source register, including deliberate imagery. Ordinary translation uses the v1 output schema. Single-unit recovery uses the versioned text-only schema. Alignment uses `alignment.v1`. Dispatch verifies prompt attribution. See [prompts](../../prompts/README.md) and [acceptance](../testing.md#translation-prompts). The same-response check adds no model request or repair loop. Offline evidence does not establish provider quality.

## Provider profiles and dependencies

Use CPython 3.13 and the frozen dependency environment in [Worker/uv.lock](../../Worker/uv.lock). Direct runtime and development dependencies are declared in [Worker/pyproject.toml](../../Worker/pyproject.toml); PyInstaller bundles the production worker and separate test fixture. Resolve dependency changes through the normal lockfile and integration checks. Dependency conflicts require design review before changing the runtime architecture. See [validation status](../validation.md) for executed packaging and test evidence.

Use LangChain's prompt/message composition and asynchronous model invocation. Explicit provider profiles encapsulate request differences, accepting the explicit configuration URL/profile/effort rather than global hardcoded endpoints. Install only the named modules; there is no need for a general agent executor, tool registry, LangSmith account, `langchain-community`, or an explicitly authored LangGraph workflow. [LangChain's OpenAI integration](https://docs.langchain.com/oss/python/integrations/chat/openai) provides the selected `ChatOpenAI` adapter; its presence is a library choice, not proof of GLM feature parity.

### Open protocol profiles

`openai-responses-v3` and `anthropic-messages-v3` use a narrow LangChain `BaseChatModel` adapter over the existing httpx client. No new dependency or secondary orchestration path is introduced. The adapter serializes Responses `input` or Messages `system` plus `messages` explicitly; it never infers an API from the model name. The same canonical system asset and serialized user input are used, with no tools, history, streaming, retries or redirects. OpenAI sets `store: false`.

All four efforts are admitted for arbitrary model IDs. Exact option precedence and default reasoning mappings are owned by [model configuration](model-settings.md#open-configuration-contract). Native output format is explicit and local canonical validation always runs. Parse only final assistant text; ignore reasoning blocks, reject tools/refusal/malformed blocks, and treat truncation as `output_limit`. Bound the raw response to 2 MiB before strict JSON parsing; retain the existing 128 KiB decoded-content cap, 120-second invocation deadline and cancellation behavior. Provider compatibility is user-selected and real-provider acceptance is separate from captured offline requests.

### Legacy v1 profiles

A retained v1 profile requires its original canonical Standard API URL and effective effort. OpenAI uses Auto and GLM uses Off. Reject a different URL or effort locally. Migration preserves the saved model ID.

| Parameter | `openai-json-schema-v1` | `glm-json-v1` |
| --- | --- | --- |
| Provider ID | `openai` | `glm` |
| API base URL | `https://api.openai.com/v1/` | `https://open.bigmodel.cn/api/paas/v4/` |
| API | Chat Completions | OpenAI-compatible Chat Completions |
| LangChain model | `ChatOpenAI`, explicitly `use_responses_api=False` | Same class, GLM base URL explicitly supplied |
| Output mode | `bind(response_format={"type":"json_schema","json_schema":{"name":schema["title"],"strict":True,"schema":schema}})`; invoke for raw `AIMessage` | Bind `response_format={"type":"json_object"}`; parse/validate locally |
| Temperature | 0.2 | 0.2 |
| Output cap | 4096 tokens for translation; 1024 for alignment | Same caps |
| Token-limit wire field | `max_completion_tokens` | `max_tokens`, passed through `extra_body`; leave the OpenAI-specific cap unset |
| Reasoning option | Omit | `extra_body.thinking={"type":"disabled"}` |
| Retries / streaming | SDK and LangChain retries disabled; no streaming | Same |
| HTTP timeout | 10-second connect; Python-enforced 120-second total invocation deadline | Same |

Bind the canonical schema dictionary directly; do not use `with_structured_output` or its automatic function-calling fallback. Before invocation reject known legacy OpenAI IDs `gpt-4`, `gpt-4-*`, and `gpt-3*` as `unsupported_capability`; this is a small known-incompatibility check, not a model catalog. A profile guard immediately before HTTP transport verifies the final serialized body against the configured model, temperature 0.2, operation-specific output cap and field, and exact two message roles/contents. Non-streaming means `stream` absent or explicitly false; the SDK may omit its default. OpenAI must retain exactly the canonical strict JSON Schema response format and no `tools`/`tool_choice`; GLM must retain JSON-object mode, disabled thinking, and no tools. Any silent adapter mutation, including dropped temperature, is `unsupported_capability` before HTTP. Preserve this typed guard failure through any SDK exception wrapping rather than misclassifying it as a network failure. A guard failure makes zero HTTP calls. Other unknown compatible model IDs may be attempted once and receive a normalized provider capability error; never change their mode automatically. Use raw `AIMessage.content` and the strict parser below. SDK `LengthFinishReasonError` and `ContentFilterFinishReasonError` may occur before an AIMessage is returned; map them to `output_limit` and `refused`.

Wrap the entire awaited LangChain invocation in Python `asyncio.timeout(120)`. HTTP client timeouts are per phase, not a total-operation deadline; retain a 10-second connect timeout and disable HTTP redirects, SDK retries, and LangChain retries. Swift’s separate 130-second transport watchdog allows a normal provider timeout to return its terminal frame without killing another request.

Retained models must support text Chat Completions, their profile's output mode and parameters, at least 32K context, and the specified output caps. Reject unsupported capabilities without changing the API, model, prompt, or connection.

### Configurable v2 profiles

The retained `openai-json-schema-v2` and `glm-json-v2` profiles keep the corresponding v1 API/output-validation semantics while replacing fixed URL/reasoning/sampling/cap assumptions with the exact [capability mapping](model-settings.md#effort-capabilities-and-wire-mapping). OpenAI uses strict JSON Schema and `max_completion_tokens`; GLM uses JSON-object mode and `max_tokens`. Both remain `ChatOpenAI` with `use_responses_api=False`, exactly two canonical messages, no tools, no streaming, no retries and no redirects. A custom GLM Coding Plan URL uses the GLM v2 profile and requires a matching eligible key. Kimi and DeepSeek Chat Completions profiles use the same `ChatOpenAI` transport. Use JSON-object mode, local canonical schema validation and the exact token-limit field and effort mapping from the [configuration design](model-settings.md#effort-capabilities-and-wire-mapping). Both canonical prompts already specify JSON and contain an example shape. A blank JSON-mode response is invalid output. Preserve the existing single-call policy.

The final-body guard compares the serialized request with the selected profile and capability entry. Keep the profile's schema, effort, and sampling rules and require a request without tools. Test the actual pinned adapter's serialized body. Capability and preflight failures make zero HTTP calls.

The configuration design specifies effort mappings and output caps, including reasoning. SDK refusal and length handling, the total deadline, decoded-output limits, and response validation still apply. Resolve pinned-library incompatibilities through design review before changing the runtime, API, or request guard. [V2 capability mapping](model-settings.md#effort-capabilities-and-wire-mapping)

## Source planning in Swift

This section defines the existing plain-text planner. The [Markdown planner](#markdown-translation) is selected only for newly applied Markdown revisions; saved legacy plans keep their original semantics.

1. Accept paste or decoded UTF-8 text verbatim. Reject input above the initial 1 MiB UTF-8 bound without truncating it. Document planning accepts empty/whitespace-only drafts for local saving; reject those only when starting Translate, without a network call. Store the exact source separately from every rendered projection.
2. Direction options are Auto, Chinese to English, and English to Chinese. Auto uses the existing local classifier on the first 4,000 nonwhitespace Unicode scalars. Accept Chinese or English when its supported character count is positive and at least twice the other count; otherwise direct the user to the explicit direction choices in Settings before a network call. Resolve Auto once per job and persist the result; changing interface language cannot change it.
3. Parse paragraphs at consecutive newline sequences (`CRLF`, `LF`, or `CR`), retaining their exact ranges and separators. Preserve leading/trailing blank lines and whitespace-only paragraphs; these need no model call. Do not create a translated phantom paragraph after a trailing separator.
4. Within a nonblank paragraph, use `NLTokenizer` sentence candidates. Construct a complete, nonoverlapping partition of its source range, including whitespace. Each unit owns its full source range and an inner `text_range` excluding boundary whitespace. Empty candidates attach to adjacent boundary whitespace. Preserve the paragraph's outer indentation/trailing whitespace for rendering.
5. Split a sentence above **1,024 UTF-8 bytes** at the last clause punctuation or whitespace boundary within the limit, otherwise at a composed-character boundary. All pieces from a split sentence are `fragment` units, never falsely labeled exact sentences. An individual composed character above the bound is an explicit unsupported-input error, not an infinite split loop. Persist the unit plan with the document.
6. Form ordered batches of at most **64 units** and **8,192 UTF-8 bytes of unit text**, crossing paragraph boundaries if useful. Attach at most 512 UTF-8 bytes of preceding and 512 of following source context, clipped at composed-character boundaries. Do not include any unrelated tab or document. JSON-serialized `input` is additionally capped at 32 KiB.

Source coverage is a hard invariant: paragraph ranges plus separators cover the exact source; unit full ranges cover each nonblank paragraph with no overlap or gaps. Do not compare code-point counts to native UTF-16 counts. Tokenization can differ between OS versions; saved boundaries remain authoritative until the source changes. The bounds reduce oversized calls but are not a universal tokenizer equivalence or a guarantee for arbitrary configured models.

## Translation latency

The app reuses a worker and a shared HTTP connection pool. It permits two batches per tab within four global operations. The provider returns a complete JSON reply for each batch. Swift and the worker validate the reply before committing the batch. A paragraph appears once all its units are committed. Reasoning, full-batch generation, a paragraph spanning batches, and queue contention can delay the first readable result. A one-batch document cannot use additional concurrency.

The performance check measures local stages, provider latency, and time to first readable output separately. [Performance acceptance](../testing.md#settings-and-provider-acceptance)

## Translation invocation and commit

The following input and string constraints apply to `translation.v1`/`translation.v2`. The separately versioned [Markdown extension](#markdown-translation) retains output object shape but has its own payload and structural validation.

The [prompt contract](../../prompts/README.md) supplies the entire prompt, schema, message composition, and versions. The exact `input` object is:

```json
{
  "source_language": "en",
  "target_language": "zh",
  "context_before": "",
  "context_after": "",
  "units": [
    {"unit_id": "unit-example-1", "kind": "sentence", "text": "The window is open."}
  ]
}
```

Use actual UUIDs in application requests; short IDs in prompt fixtures are readable synthetic examples. Input language values are exactly `en` and `zh` and must differ. Validate fields and bounds before dispatch.

Python performs one LangChain invocation, then:

1. Classifies transport/API error, explicit refusal, and non-success finish reason. A length-truncated response is `output_limit`, even if some JSON parses. Never parse reasoning content or a tool call as translation.
2. Parses one complete JSON value; no code-fence stripping, substring extraction, `eval`, or automatic repair.
3. Validates the canonical schema with strict types; rejects duplicate object keys, NaN/infinity, unknown output fields, and coercion of strings into integers.
4. Requires each requested unit ID exactly once. Uppercase and lowercase UUID hex digits represent the same ID. Keep the hyphens and reject unknown or duplicate IDs. Match each row to its source by ID, apply that unit’s limits, and return the rows to Swift in request order. A permutation of complete rows needs no extra call. All strings are nonempty after trimming, contain no line break, and already have no leading/trailing whitespace. Each translated string is at most 8 KiB UTF-8; complete decoded model content at most 128 KiB.
5. Returns the validated data plus provider/model/prompt/token metadata. Token usage may be unavailable and must then be null, never zero or an invented cost.

For the plain-text operation, Swift verifies the current owner, expected IDs, ranges, and limits before committing a batch. A malformed unit rejects that batch. Earlier batches stay readable. App display never shows raw unvalidated output.

Assemble a paragraph after all its units complete. Between translated units use one ASCII space for English and no inserted space for Chinese. Exception: adjoining fragment outputs that exactly copy their original text and were separated only by boundary whitespace preserve that exact original gap, preserving split literal strings. Also preserve the original spaces/tabs between a separately tokenized paragraph-initial numbered-list marker (`1.`/`1)`, one to nine ASCII digits) and its body when the marker is copied exactly. This keeps saved unit plans usable without changing their boundaries. Preserve paragraph indentation and its exact source newline separator in plain-text assembly. Add no automatic final punctuation. Retain per-unit translated ranges, excluding inserted separators.

Target assembly is deterministic. Fragment-boundary quality problems require a scoped design correction. Complete paragraphs are displayed only after all units finish; progress advances per committed unit.

## Retained alignment operation

The desktop reader performs no selection-triggered model work. The worker still accepts the versioned alignment operation for protocol compatibility and tests. See the [worker protocol](worker-protocol.md) for its request and response contract.

## Failure and retry policy

A translation failure alert keeps the completed-paragraph notice and shows available HTTP status, a recognized provider error code, or a localized response-validation reason. Diagnostics use only the bounded fields in the [worker protocol](worker-protocol.md#terminal-responses). Provider messages, response bodies, credentials, and document text stay out of the alert and logs.

The error table applies to translation. Fatal worker failure resolves all requests owned by that instance.

Each worker operation makes at most one HTTP request. Swift owns unit recovery. Earlier prompts reject a batch with missing, repeated, or unexpected IDs. Markdown v5 can keep valid uniquely identified rows and recover only the outstanding IDs. Split only that batch into contiguous halves and recompute each half’s source context. Queue recovery behind pending batches and use the same admission rules, model, prompt and attempt. A new identity mismatch can split a half again. A one-unit recovery uses the [single-text.v1 output contract](../../prompts/single-text.v1.txt). The worker binds the validated text to the sole requested ID. An ordinary one-unit batch that fails identity validation can also use this recovery once.

Each document attempt can schedule up to 16 additional requests for unit recovery. If that budget cannot cover recovery, or a single-text reply fails output validation, leave those units unfinished and continue dispatching other batches. After the queue drains, report the remaining unit numbers. Manual Retry queues only unfinished units with the retained snapshot and a fresh recovery budget. Transport, credential, refusal and Markdown structure failures follow their own policies. A timeout may already have incurred a charge. Switching models requires Retranslate.

| Error | App behavior |
| --- | --- |
| Missing key, authentication, model unavailable, unsupported capability | Fail the affected operation and stop that document; open the relevant Settings section; do not retry unchanged credentials/configuration automatically |
| Network, timeout, provider 5xx, or 429 outside the GLM recovery policy | Keep completed work and offer manual recovery. Respect a supplied retry delay |
| GLM HTTP 429 with `1302` or `1305` | Apply the shared cooldown and replay only the failed batch once when the delay fits the automatic wait budget |
| Context/output limit | Keep work; explain incomplete/incompatible response; allow an explicit retry or model change, without silent truncation |
| Translation unit count or ID mismatch | Retry the affected batch within the unit recovery budget. Continue independent batches and report any remaining gaps after they finish |
| Other invalid model output | Reject the response, keep committed results, and show Retry |
| Refusal | Report that the provider declined the text; do not route around it automatically |
| Worker crash/protocol failure | Fail active requests, retain document data, pause queued jobs; restart lazily only on the next explicit action |

Rate limits and quota can differ by provider/account. The concurrency limit is application-wide (four concurrent model operations) even across providers. One document session holds at most two concurrent translation batches. Cancellation stops local waiting/dispatch but cannot promise the remote provider did not generate or bill a response.

### GLM rate-limit recovery

Allow two concurrent translation batches per document, with a global cap of four. HTTP 429 alone does not establish the trigger; classify recovery using the provider business code. The [GLM error reference](https://docs.bigmodel.cn/cn/api/api-code) and [rate-limit guide](https://docs.bigmodel.cn/cn/api/rate-limit) distinguish account throttling (`1302`, which can cover concurrency and request density), service overload (`1305`), usage caps (`1308`, `1310`, `1316`–`1321`), and persistent account or access conditions.

Enable recovery for GLM translation with HTTP 429 and allowlisted transient codes `1302`/`1305`. Unknown codes, usage caps, billing, eligibility and fair-use restrictions use manual recovery. Parse bounded Retry-After; skip replay above the wait budget. Defaults: 10-second fallback, 60-second automatic wait budget per batch and 60-second serialized admission after cooldown.

Apply cooldown and the temporary one-request limit in Swift admission before making the released slot available. Key the state in memory by saved configuration ID, canonical Base URL, provider and actual model ID. Documents sharing that connection and model share the cooldown. Skip blocked requests when admitting work from other routes. Existing calls can finish and commit normally. Waiting for cooldown takes no physical slot and does not start the request watchdog. After cooldown, serialize requests on the affected route and return to normal admission when the window ends without another transient limit.

Replay only the batch that received the transient error, once per batch per translation attempt, using the same unit IDs, source context and job snapshot with a fresh worker request ID. On that route, admit ready replays before unsent translation batches so an early hole does not wait behind the rest of the document. Preserve committed results and use ordinary credential preflight when enqueuing the replay. Cancel, close, source replacement and attempt invalidation remove waiting work and prevent replay. If the retry fails, preserve committed work and surface the terminal diagnostic through the existing retry flow. Each worker operation still makes at most one HTTP request. A deferred batch also stops if later 429 responses extend the shared cooldown past its automatic wait budget.

Acceptance needs a controlled two-document fixture with different routes to prove that an unrelated request can start during cooldown, plus a same-route fixture to prove that no new request starts during cooldown and only one is admitted afterward. Verify that successful and in-flight sibling batches are not replayed, 429 after replay stops further automatic attempts, usage-cap and unknown codes cause zero automatic attempts, and cancellation during cooldown sends no HTTP call. Compare time to complete both documents and request counts including recovery. Use an eligible endpoint for any live GLM validation.

## Evaluation ownership

Use [prompt cases](../../prompts/cases.json) for transport fixtures and semantic checks. The [test plan](../testing.md) adds long-text, native, packaging, privacy, and live-provider gates. Record requested and returned model ID, prompt hashes, locked versions, corpus version, date, call counts, failures, and semantic findings. Keep raw private texts/credentials out of reports.

Prompt failures require a minimal synthetic reproduction, expected meaning, observed output and sanitized request profile. Version the design correction and repeat the affected evaluation.

## Markdown translation

New Markdown jobs use `markdown-plan.v5` and `translation.markdown.v5`. Opening a document restores its recorded plan and units. Continuing an unfinished v4 job upgrades the plan if its saved translations pass v5 validation, keeping their IDs, text, and captured v3 or v4 prompt. A job with incompatible saved translations continues under v4. A v3 plan permits code reordering only in code-and-prose units. V1 and v2 plans preserve order. Retranslate starts a new job with the current plan and prompt.

### Planning, literals and budgets

Create translatable inline payloads for each heading, paragraph (including paragraphs inside list items/quotes), and table cell. Resolve reference links against the full source. Normalize ordinary soft wraps to one space in the model payload while retaining exact original bytes and a source map; preserve hard-break semantics. Preserve inline emphasis, link labels/destinations, inline code and image references as inline Markdown, retaining exact protected slices. Heading/list/quote prefixes, table delimiters and enclosing containers are application-owned structure, not text for the model to recreate.

Fenced/indented code blocks, protected metadata, raw HTML, reference definitions, thematic breaks and syntax-only/whitespace pieces are copied locally and never submitted as standalone translation units. Their source and target node identities correspond directly. Top-level frontmatter `title` and `description` single-line prose scalars are translated as inline payloads after decoding supported quotes, then safely serialized as YAML strings; other fields and unsupported YAML remain exact. These descriptive fields participate in language detection. Code comments inside protected blocks are also preserved. Inline code, URLs, reference IDs, image destinations and technical identifier literals stay exact; translate link labels and image alt text. Images still render as placeholders. Excluding a literal from translation does not guarantee it never occurs in bounded neighboring context; the usual provider disclosure applies.

Use whole inline payloads when bounded, preserving sentence context across emphasis and link boundaries. Do not separately translate every AST text leaf. A Markdown unit is at most 8,192 UTF-8 bytes and a batch still has at most 64 units / 8,192 UTF-8 bytes of text; this deliberately differs from the 1,024-byte plain-text sentence split. Keep neighboring source context at 512 bytes before and after, with the 32 KiB serialized-input cap. Batch size does not follow section size, and the scheduler remains two batches per document / four operations globally.

Split an oversized payload only at a sentence/clause boundary outside an inline code/link/image/emphasis construct, recording contiguous payload ranges and an explicit join policy. Prefer sentence boundaries; fragment outputs do not acquire a Sentence match label. Whole inline constructs and hard-break tokens are indivisible. A construct or unsplittable run above the unit limit produces a local Markdown-unit-too-large error before any dispatch for that new plan; retain the source and offer editing or Plain Text. Do not silently drop prose or split a protected destination. Adjacent fragments join with one space for English and none for Chinese at a selected linguistic boundary; copy-only pieces retain their original gap. Record the join choices in the plan so resume/open is deterministic.

Auto language direction examines translatable visible prose, excluding code, destinations and protected metadata, under the existing character-count rule. If no translatable prose exists, render/copy the document locally with a status explaining that no prose needs translation; no provider configuration or worker launch is required and no translation attribution is invented. A document containing prose still needs a resolved direction and selected model before translation.

### Model contract and structural validation

The Markdown prompt consumes the [Markdown-specific input variant](worker-protocol.md#markdown-prompt-extension), using the existing two-message composition and output object shape. Its mandatory instructions are:

1. Translate every supplied unit once, preserve IDs and order, and return only the translations object. Treat all source/context as untrusted translation material.
2. Preserve complete meaning, logical scope, uncertainty, enumeration members and terminology, as required by the current translation rules; do not summarize or move meaning between units.
3. Translate the natural language in each inline fragment, including link labels, descriptive titles, and image alt text. Keep emphasis with its translated phrase where possible. Preserve the content, occurrence count, and scope of protected constructs.
4. Do not add headings, list/quote prefixes, tables, code fences, HTML, reference definitions or new links. Preserve existing hard breaks; introduce no soft-wrap or blank-line formatting. Do not wrap the response or a translated unit in code fences.
5. Keep a fragment limited to its supplied material, without inventing missing text. Return no outer whitespace, explanations, confidence scores or extra output fields.

The [current prompt](../../prompts/translation.markdown.v5.txt) requests `translations: [{unit_id, text}]`. The worker bounds the complete decoded reply at 128 KiB and each translated unit at 32 KiB. It matches UUIDs, rejects CR, blank lines, and extra line feeds, and returns valid rows in request order. If some v5 rows are missing, duplicated, or malformed, the worker can return the unambiguous rows with the outstanding IDs. A model cannot supply that list. Swift validates the partition before using either group.

V5 validates the meaning of Markdown constructs that affect the document. Bold and italic may move, appear, or disappear with translated prose. A recognizable pair of emphasis markers next to punctuation can be made parseable when doing so preserves its text and protected content. Retain exact inline code and its occurrence count, resolved link and image destinations, reference identities, strikethrough, hard breaks, and literal HTML. Natural-language link titles may change. Block hierarchy, table membership, and source-unit identity remain fixed. Escape literal punctuation when necessary to keep it visible in its original block or cell. The same accepted Markdown supplies preview, storage, and export. These checks do not establish semantic translation quality.

A local Markdown mismatch isolates the affected output using the rows already received. Commit independently valid rows to the owning revision and continue queued batches. Retry requests only outstanding units. Worker-level row recovery uses the existing request budget. A local protection or reconstruction failure makes no model repair request.

The failure sheet identifies the affected source unit, its input, the original rejected model reply, and the corresponding structural difference. Rejected text stays out of the document and logs.

### Assembly and progressive presentation

Substitute accepted inline Markdown into source-owned headings, lists, quotations, tables, and other blocks. Preserve copied blocks and reference definitions. For split blocks, the joined Markdown must render the same text, styling, and protected content as its individual fragments, including escaped pipes inside table cells. Validate reconstructed block structure against the current document before publishing any new results. Keep only the validated representation for reading, copying, saving, and export.

Unit commit and block display are distinct. Keep completed units in partial documents, but display a heading/paragraph only after all its units complete. Completed prose blocks in list items appear in their source order with their list indentation. Table headers and individual rows wait for all their cells; a header must be available before displaying target data rows. A rendered table can show completed rows with a non-text unfinished indication, while partial Markdown export omits the incomplete table. Code and other local-copy nodes are visible without a model result, clearly distinguished from translated prose in progress accounting.

Render from typed blocks rather than parsing an incomplete concatenated target string. This prevents an unfinished fence, list or table from absorbing later sections. The full canonical target Markdown becomes exportable when every required prose unit completes. Save partial unit results without fabricating empty translated content. Reopening uses the recorded planner version and restores the saved identities after verifying the reconstructed ranges.
