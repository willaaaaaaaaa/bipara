# Translation and Correspondence Workflow

Numeric limits are engineering bounds and evaluation targets. Use named constants and change the owning contract and tests when prompt, batching, profile or retry semantics change.

Batch planning is bounded to 64 units / 8,192 UTF-8 bytes / 32 KiB serialized input. One document session may hold up to two concurrent translation batches inside four global concurrent model operations. The v2 plain output caps are 8,192/2,048 tokens; both legacy profiles keep 4096/1024. These limits bound local admission and provider work; they do not guarantee provider latency.

New model configurations follow the [model configuration design](model-settings.md). Open profiles fix OpenAI to Responses and Anthropic to Messages with user-selected options. V1/v2 profiles below remain compatibility contracts for saved configurations and retained jobs. See the [validation report](../validation.md) for implementation and provider acceptance evidence.

New jobs use `translation.v2`; retained jobs keep `translation.v1`, including Retry/Resume. The translation output schema and `alignment.v1` remain unchanged. Dispatch verifies prompt attribution. See [prompts](../../prompts/README.md) and [acceptance](../testing.md#translation-prompt-v2). The same-response check adds no model request or repair loop. Offline evidence does not establish provider quality.

## Provider profiles and dependencies

Use CPython 3.13 and the frozen dependency environment in [Worker/uv.lock](../../Worker/uv.lock). Direct runtime and development dependencies are declared in [Worker/pyproject.toml](../../Worker/pyproject.toml); PyInstaller bundles the production worker and separate test fixture. Resolve dependency changes through the normal lockfile and integration checks. Dependency conflicts require design review before changing the runtime architecture. See [validation status](../validation.md) for executed packaging and test evidence.

Use LangChain's prompt/message composition and asynchronous model invocation. Explicit provider profiles encapsulate request differences, accepting the explicit configuration URL/profile/effort rather than global hardcoded endpoints. Install only the named modules; there is no need for a general agent executor, tool registry, LangSmith account, `langchain-community`, or an explicitly authored LangGraph workflow. [LangChain's OpenAI integration](https://docs.langchain.com/oss/python/integrations/chat/openai) provides the selected `ChatOpenAI` adapter; its presence is a library choice, not proof of GLM feature parity.

### Open protocol profiles

`openai-responses-v3` and `anthropic-messages-v3` use a narrow LangChain `BaseChatModel` adapter over the existing httpx client. No new dependency or secondary orchestration path is introduced. The adapter serializes Responses `input` or Messages `system` plus `messages` explicitly; it never infers an API from the model name. The same canonical system asset and serialized user input are used, with no tools, history, streaming, retries or redirects. OpenAI sets `store: false`.

All four efforts are admitted for arbitrary model IDs. Exact option precedence and default reasoning mappings are owned by [model configuration](model-settings.md#open-configuration-contract). Native output format is explicit and local canonical validation always runs. Parse only final assistant text; ignore reasoning blocks, reject tools/refusal/malformed blocks, and treat truncation as `output_limit`. Bound the raw response to 2 MiB before strict JSON parsing; retain the existing 128 KiB decoded-content cap, 120-second invocation deadline and cancellation behavior. Provider compatibility is user-selected and real-provider acceptance is separate from captured offline requests.

### Legacy v1 profiles

The following table fixes legacy effective behavior. A v1 profile requires its original canonical Standard API URL and effective effort (OpenAI Auto; GLM Off); reject another URL/effort locally. Custom connections use a v2 profile.

| Parameter | `openai-json-schema-v1` | `glm-json-v1` |
| --- | --- | --- |
| Provider ID | `openai` | `glm` |
| API base URL | `https://api.openai.com/v1/` | `https://open.bigmodel.cn/api/paas/v4/` |
| Initial model ID | `gpt-4.1-mini-2025-04-14` | `glm-4.7-flash` |
| API | Chat Completions | OpenAI-compatible Chat Completions |
| LangChain model | `ChatOpenAI`, explicitly `use_responses_api=False` | Same class, GLM base URL explicitly supplied |
| Output mode | `bind(response_format={"type":"json_schema","json_schema":{"name":schema["title"],"strict":True,"schema":schema}})`; invoke for raw `AIMessage` | Bind `response_format={"type":"json_object"}`; parse/validate locally |
| Temperature | 0.2 | 0.2 |
| Output cap | 4096 tokens for translation; 1024 for alignment | Same caps |
| Token-limit wire field | `max_completion_tokens` | `max_tokens`, passed through `extra_body`; leave the OpenAI-specific cap unset |
| Reasoning option | Omit | `extra_body.thinking={"type":"disabled"}` |
| Retries / streaming | SDK and LangChain retries disabled; no streaming | Same |
| HTTP timeout | 10-second connect; Python-enforced 120-second total invocation deadline | Same |

The initial OpenAI snapshot supports Chat Completions and structured outputs according to its [model page](https://developers.openai.com/api/docs/models/gpt-4.1-mini). GLM documents its [compatible endpoint](https://docs.bigmodel.cn/cn/guide/develop/openai/introduction), [LangChain integration](https://docs.bigmodel.cn/cn/guide/develop/langchain/introduction), and [JSON-object mode](https://docs.bigmodel.cn/cn/guide/capabilities/struct-output). JSON mode alone does not validate the application's schema. The chosen [GLM model](https://docs.bigmodel.cn/cn/guide/models/free/glm-4.7-flash) supports structured output; the [thinking-mode guide](https://docs.bigmodel.cn/cn/guide/capabilities/thinking-mode) describes disabling thinking for its model family. Verify the actual pinned library's final outgoing body in adapter tests, especially token-limit renaming and GLM `extra_body` merging.

Bind the canonical schema dictionary directly; do not use `with_structured_output` or its automatic function-calling fallback. Before invocation reject known legacy OpenAI IDs `gpt-4`, `gpt-4-*`, and `gpt-3*` as `unsupported_capability`; this is a small known-incompatibility check, not a model catalog. A profile guard immediately before HTTP transport verifies the final serialized body against the configured model, temperature 0.2, operation-specific output cap and field, and exact two message roles/contents. Non-streaming means `stream` absent or explicitly false; the SDK may omit its default. OpenAI must retain exactly the canonical strict JSON Schema response format and no `tools`/`tool_choice`; GLM must retain JSON-object mode, disabled thinking, and no tools. Any silent adapter mutation, including dropped temperature, is `unsupported_capability` before HTTP. Preserve this typed guard failure through any SDK exception wrapping rather than misclassifying it as a network failure. A guard failure makes zero HTTP calls. Other unknown compatible model IDs may be attempted once and receive a normalized provider capability error; never change their mode automatically. Use raw `AIMessage.content` and the strict parser below. SDK `LengthFinishReasonError` and `ContentFilterFinishReasonError` may occur before an AIMessage is returned; map them to `output_limit` and `refused`.

Wrap the entire awaited LangChain invocation in Python `asyncio.timeout(120)`. HTTP client timeouts are per phase, not a total-operation deadline; retain a 10-second connect timeout and disable HTTP redirects, SDK retries, and LangChain retries. Swift’s separate 130-second transport watchdog allows a normal provider timeout to return its terminal frame without killing another request.

These are conservative legacy evaluation defaults, not current model recommendations or account-access claims. Preserve compatible existing model IDs without upgrading them during migration. Models must support text Chat Completions, their profile's output mode/parameters, at least 32K context, and the specified output caps. Reject unsupported capabilities with a useful error; do not silently downgrade API, model, prompt or connection. A future provider gets a factory/profile and contract tests, not a generic plugin system.

### Configurable v2 profiles

`openai-json-schema-v2` and `glm-json-v2` retain the corresponding v1 API/output-validation semantics while replacing fixed URL/reasoning/sampling/cap assumptions with the exact [capability mapping](model-settings.md#effort-capabilities-and-wire-mapping). OpenAI uses strict JSON Schema and `max_completion_tokens`; GLM uses JSON-object mode and `max_tokens`. Both remain `ChatOpenAI` with `use_responses_api=False`, exactly two canonical messages, no tools, no streaming, no retries and no redirects. A custom GLM Coding Plan URL uses the GLM v2 profile and requires a matching eligible key. Kimi and DeepSeek Chat Completions profiles use the same `ChatOpenAI` transport. Use JSON-object mode, local canonical schema validation and the exact token-limit field and effort mapping from the [configuration design](model-settings.md#effort-capabilities-and-wire-mapping). Both canonical prompts already specify JSON and contain an example shape. A blank JSON-mode response is invalid output. Preserve the existing single-call policy.

The final-body guard must compare against the selected profile and capability entry. For example, legacy OpenAI still requires temperature 0.2, while GPT-6 Luna v2 deliberately omits sampling fields and sends its supported effort. GLM-4.7-Flash Off sends disabled thinking without graded effort; GLM-5.3/Flash Low sends enabled thinking and `reasoning_effort: "low"`. Applying the old universal disabled-thinking/temperature guard to v2 would be incorrect. Preserve strict schema/no-tools/no-silent-mutation safeguards and test the actual pinned adapter's serialized body. Capability/preflight failures make zero HTTP calls.

V2 operation caps include reasoning: 8,192/2,048 translation/alignment for nonreasoning or explicit Off (both legacy profiles keep their original 4,096/1,024), and 16,384/4,096 for active/default reasoning or unknown models. The [configuration design](model-settings.md) owns exact conditions and dated recommendations. SDK refusal/length handling, total deadline, decoded-output limits and all validation below still apply. A pinned-library incompatibility requires design review; it does not authorize a runtime/API substitution or weakening the guard.

## Source planning in Swift

1. Accept paste or decoded UTF-8 text verbatim. Reject input above the initial 1 MiB UTF-8 bound without truncating it. Document planning accepts empty/whitespace-only drafts for local saving; reject those only when starting Translate, without a network call. Store the exact source separately from every rendered projection.
2. Direction options are Auto, Chinese to English, and English to Chinese. Auto uses the existing local classifier on the first 4,000 nonwhitespace Unicode scalars. Accept Chinese or English when its supported character count is positive and at least twice the other count; otherwise direct the user to the explicit direction choices in Settings before a network call. Resolve Auto once per job and persist the result; changing interface language cannot change it.
3. Parse paragraphs at consecutive newline sequences (`CRLF`, `LF`, or `CR`), retaining their exact ranges and separators. Preserve leading/trailing blank lines and whitespace-only paragraphs; these need no model call. Do not create a translated phantom paragraph after a trailing separator.
4. Within a nonblank paragraph, use `NLTokenizer` sentence candidates. Construct a complete, nonoverlapping partition of its source range, including whitespace. Each unit owns its full source range and an inner `text_range` excluding boundary whitespace. Empty candidates attach to adjacent boundary whitespace. Preserve the paragraph's outer indentation/trailing whitespace for rendering.
5. Split a sentence above **1,024 UTF-8 bytes** at the last clause punctuation or whitespace boundary within the limit, otherwise at a composed-character boundary. All pieces from a split sentence are `fragment` units, never falsely labeled exact sentences. An individual composed character above the bound is an explicit unsupported-input error, not an infinite split loop. Persist the unit plan with the document.
6. Form ordered batches of at most **64 units** and **8,192 UTF-8 bytes of unit text**, crossing paragraph boundaries if useful. Attach at most 512 UTF-8 bytes of preceding and 512 of following source context, clipped at composed-character boundaries. Do not include any unrelated tab or document. JSON-serialized `input` is additionally capped at 32 KiB.

Source coverage is a hard invariant: paragraph ranges plus separators cover the exact source; unit full ranges cover each nonblank paragraph with no overlap or gaps. Do not compare code-point counts to native UTF-16 counts. Tokenization can differ between OS versions; saved boundaries remain authoritative until the source changes. The bounds reduce oversized calls but are not a universal tokenizer equivalence or a guarantee for arbitrary configured models.

## Translation latency

The current worktree already reuses a worker and a shared HTTP connection pool, and permits two batches per tab within four global operations. Translation calls are non-streaming. A batch becomes available after the provider completes its full JSON reply and both layers validate it. A paragraph becomes visible only once all of its units are committed. Reasoning, full-batch generation, a paragraph spanning batches and queue contention can all delay the first readable result. A one-batch document gains no throughput from increasing concurrency.

Measure local worker stages separately from end-to-end provider latency for the selected endpoint, model, effort and input. Current evidence and unqualified performance claims are recorded in [validation status](../validation.md).

1. **Measure the existing path.** Use monotonic durations for action to dispatch, worker launch/readiness on cold runs, queue wait, provider invocation, validation/commit, first complete paragraph and whole document. Compare warm and cold runs using the same short text and a multi-batch text in each direction. Record batch count, byte counts, provider/model/effort, available aggregate token counts and failures in an opt-in local benchmark with synthetic input. Exclude source text, keys, custom URLs, and raw requests or responses. Compare the same configurations and endpoints across runs.
2. **Try a faster instance and lower explicit effort.** Start with GPT-6 Luna Off versus Low, GLM-5.3-Flash Low, Kimi K3.1 Pro Highspeed Low, or DeepSeek Flash Off versus Low where eligible. Test effort within the same model before comparing models. Auto may select Max on GLM-5.3 and Kimi K3, or High on DeepSeek. Judge meaning, terminology, omissions and valid unit coverage alongside latency. Keep the chosen instance explicit.
3. **Trial a smaller first batch only if time to first paragraph still matters.** Keep the current batch limits for the rest of the document. Prefer a first batch ending at a complete paragraph within the existing bounds. Compare first readable paragraph and total completion against the current planner, including request count, rate limits, failure rate and fidelity. Retain it only if it improves the first result without a material regression. For a short document already inside one batch, test the model and effort first.

Keep the current scheduler, strict validation and progressive display of complete paragraphs. Defer token streaming, eager process warmup, broader parallelism and prompt or runtime rewrites until a measured bottleneck justifies their cost. The [acceptance plan](../testing.md#settings-and-provider-acceptance) separates runtime, quality and performance evidence.

## Translation invocation and commit

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
4. Requires exactly the requested unit IDs, once each, in the original order. All strings are nonempty after trimming, contain no line break, and already have no leading/trailing whitespace. Each translated string is at most 8 KiB UTF-8; complete decoded model content at most 128 KiB.
5. Returns the validated data plus provider/model/prompt/token metadata. Token usage may be unavailable and must then be null, never zero or an invented cost.

Swift independently verifies the request's current owner, expected IDs and range/size constraints before one atomic batch commit. A malformed unit rejects the whole batch; previously committed batches stay readable. App display never shows raw unvalidated output.

Assemble a paragraph after all its units complete. Between translated units use one ASCII space for English and no inserted space for Chinese. Exception: adjoining fragment outputs that exactly copy their original text and were separated only by boundary whitespace preserve that exact original gap, preserving split literal strings. Also preserve the original spaces/tabs between a separately tokenized paragraph-initial numbered-list marker (`1.`/`1)`, one to nine ASCII digits) and its body when the marker is copied exactly. This keeps saved unit plans usable without changing their boundaries. Preserve paragraph indentation and its exact source newline separator in plain-text assembly. Add no automatic final punctuation. Retain per-unit translated ranges, excluding inserted separators, for correspondence. Unit whitespace or inserted separators fall back to paragraph mapping.

Target assembly is deterministic. Fragment-boundary quality problems require a scoped design correction. Complete paragraphs are displayed only after all units finish; progress advances per committed unit.

## Selection correspondence

Paragraph and unit mappings exist from stable identities and returned unit text; no second model call is needed to establish these coarse ranges. A unit from a whole sentence is labeled Sentence; a fragment is labeled Fragment. Neither label guarantees perfect semantic translation.

Hover uses the smallest available local mapping and never sends a model request. A committed reading selection first receives its unit/paragraph fallback. After a **350 ms** stable-selection debounce, request phrase analysis only if the selection is nonempty, within one completed unit’s model text (source `text_range`, excluding boundary whitespace), no more than 512 UTF-8 bytes, and the reading/counterpart texts total no more than 8 KiB UTF-8. The serialized input also obeys the 32 KiB cap. Cross-unit/cross-paragraph, oversized, untranslated, or ambiguous selections remain labeled fallbacks without a request.

Analyze the **existing** translation, using that document's provider/model/profile/effort/prompt snapshot and frozen runtime endpoint binding. Opened files require explicit configuration binding before a model call. Selection does not retranslate text. Both source-to-target and target-to-source selection use the same operation: `reading_text` is the selected side, `counterpart_text` is the other. The selection's before/text/after partition identifies repeated source words without asking the model to calculate native offsets.

```json
{
  "reading_text": "I can can fruit.",
  "counterpart_text": "我会把水果装罐。",
  "selection": {"before": "I can ", "text": "can", "after": " fruit."}
}
```

Validate `before + text + after` against reading_text by exact code units. In Swift use the shared UTF-8/UTF-16 identity rule, not canonically equivalent `String ==`. Resolve each returned quote by exact, case-sensitive, nonoverlapping, left-to-right occurrence within counterpart_text. No Unicode normalization or fuzzy matching. Python checks literal existence and order; Swift resolves again against its current immutable text, verifies composed-character boundaries, and maps to native UTF-16 ranges. Require 1–8 nonoverlapping ordered matches when status is matched, a positive occurrence integer, and reason `none`. A no_match result requires an empty array and a non-`none` reason. Reject illegal combinations.

On `no_match`, invalid output, timeout, missing credential, or unavailable worker, retain the coarse highlight and a quiet explanation; translation remains usable. Structural validity cannot prove semantic correctness. Display model phrase matches as suggestions and evaluate the corpus below. Never synthesize a numeric confidence score.

Cache validated phrase matches and legitimate no_match results in memory, up to 128 LRU entries per tab document session. Copied files with the same persistent document ID never share a cache. Target generation is unit-scoped: unrelated batch commits only advance document content generation, leaving an existing unit’s mappings/cache/pin and eligible pending alignment valid. Key: source revision, unit ID, that unit’s target generation, selected side, selection UTF-16 range relative to its reading_text, provider/model/profile/effort, private runtime binding identity, and prompt version. Request ownership and pinned selections use the same logical identity. RenderedTextIndex projects it to current absolute display ranges; resuming a valid sparse partial document may insert earlier paragraphs without invalidating a later unit’s logical selection. Do not cache transient errors. Invalidate on source/target changes, close, or explicit retranslation. A cache hit requires no call. New selections cancel/supersede the previous selection request; late responses cannot change the current pin.

## Failure and retry policy

A translation failure alert keeps the completed-paragraph notice and shows available HTTP status, a recognized provider error code, or a localized response-validation reason. Diagnostics use only the bounded fields in the [worker protocol](worker-protocol.md#terminal-responses). Provider messages, response bodies, credentials, and document text stay out of the alert and logs.

The error table’s document-stop behavior applies to translation. An ordinary alignment error affects only selection analysis and retains its fallback; fatal worker failure still resolves all requests owned by that instance.

One worker operation makes at most one HTTP model request. SDK retries, output-repair prompts, back-translation, and provider fallback stay disabled. Swift owns bounded batch recovery. On `invalid_output` with `unit_mismatch`, replace an original batch of two or more units with two contiguous halves once per attempt. Recompute source context for each half and dispatch both through the normal queue with the same job snapshot. Each half validates and commits independently. A terminal failure in either half stops the attempt and keeps committed results. Manual Retry resubmits unfinished work with the same job snapshot. Warn unobtrusively that a timed-out request may already have been processed. A new model requires the explicit Retranslate flow.

| Error | App behavior |
| --- | --- |
| Missing key, authentication, model unavailable, unsupported capability | Fail the affected operation and stop that document; open the relevant Settings section; do not retry unchanged credentials/configuration automatically |
| Network, timeout, provider 5xx, or 429 outside the GLM recovery policy | Keep completed work and offer manual recovery. Respect a supplied retry delay |
| GLM HTTP 429 with `1302` or `1305` | Apply the shared cooldown and replay only the failed batch once when the delay fits the automatic wait budget |
| Context/output limit | Keep work; explain incomplete/incompatible response; allow an explicit retry or model change, without silent truncation |
| Translation unit count, identity, or order mismatch | Reject the response. Split an eligible original batch once; otherwise keep committed results and show Retry |
| Other invalid model output | Reject the response, keep committed results, and show Retry |
| Refusal | Report that the provider declined the text; do not route around it automatically |
| Alignment unavailable/no match | Labeled unit/paragraph fallback; no document failure |
| Worker crash/protocol failure | Fail active requests, retain document data, pause queued jobs; restart lazily only on the next explicit action |

Rate limits and quota can differ by provider/account. The concurrency limit is application-wide (four concurrent model operations) even across providers; one document session holds at most two concurrent translation batches, and alignment admission alternates with translation admission so neither starves. Cancellation stops local waiting/dispatch but cannot promise the remote provider did not generate or bill a response.

### GLM rate-limit recovery

Allow two concurrent translation batches per document, with a global cap of four. HTTP 429 alone does not establish the trigger; classify recovery using the provider business code. The [GLM error reference](https://docs.bigmodel.cn/cn/api/api-code) and [rate-limit guide](https://docs.bigmodel.cn/cn/api/rate-limit) distinguish account throttling (`1302`, which can cover concurrency and request density), service overload (`1305`), usage caps (`1308`, `1310`, `1316`–`1321`), and persistent account or access conditions.

Enable recovery for GLM translation with HTTP 429 and allowlisted transient codes `1302`/`1305`. Unknown codes, usage caps, billing, eligibility and fair-use restrictions use manual recovery. Parse bounded Retry-After; skip replay above the wait budget. Defaults: 10-second fallback, 60-second automatic wait budget per batch and 60-second serialized admission after cooldown.

Apply cooldown and the temporary one-request limit in Swift admission before making the released slot available. Key the state in memory by saved configuration ID, canonical Base URL, provider and actual model ID. Documents sharing that connection and model share the cooldown. Skip blocked requests when admitting work from other routes. Existing calls can finish and commit normally. Waiting for cooldown takes no physical slot and does not start the request watchdog. After cooldown, serialize requests on the affected route and return to normal admission when the window ends without another transient limit. The route gate also covers new alignment requests to that route. A blocked selection can use its existing local fallback.

Replay only the batch that received the transient error, once per batch per translation attempt, using the same unit IDs, source context and job snapshot with a fresh worker request ID. On that route, admit ready replays before unsent translation batches so an early hole does not wait behind the rest of the document. Preserve committed results and use ordinary credential preflight when enqueuing the replay. Cancel, close, source replacement and attempt invalidation remove waiting work and prevent replay. If the retry fails, preserve committed work and surface the terminal diagnostic through the existing retry flow. Each worker operation still makes at most one HTTP request. A deferred batch also stops if later 429 responses extend the shared cooldown past its automatic wait budget.

Acceptance needs a controlled two-document fixture with different routes to prove that an unrelated request can start during cooldown, plus a same-route fixture to prove that no new request starts during cooldown and only one is admitted afterward. Verify that successful and in-flight sibling batches are not replayed, 429 after replay stops further automatic attempts, usage-cap and unknown codes cause zero automatic attempts, and cancellation during cooldown sends no HTTP call. Compare time to complete both documents and request counts including recovery. Use an eligible endpoint for any live GLM validation.

## Evaluation ownership

Use [prompt cases](../../prompts/cases.json) for transport fixtures and semantic checks. The [test plan](../testing.md) adds long-text, native, packaging, privacy, and live-provider gates. Record requested and returned model ID, prompt hashes, locked versions, corpus version, date, call counts, failures, and semantic findings. Keep raw private texts/credentials out of reports.

Prompt failures require a minimal synthetic reproduction, expected meaning, observed output and sanitized request profile. Version the design correction and repeat the affected evaluation.
