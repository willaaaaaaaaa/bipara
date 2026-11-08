# Swift–Python Worker Protocol v2

This document defines the current v2 transport contract. App and bundled worker upgrade together; reject protocol v1 at handshake before transmitting a credential. New jobs use `translation.v2`; retained `translation.v1` remains supported. Alignment and output schemas remain v1. [Model workflow](model-workflow.md) owns model inputs/validation; [prompt assets](../../prompts/README.md) own model output schemas. This protocol is local process IPC, not a network service or public API.

## Transport and lifecycle

Launch one bundled worker lazily on the first operation. Use `Foundation.Process` with absolute bundle-derived executable URL and three pipes; never invoke a shell or search `PATH` for Python. No text or credentials in arguments, files, sockets, or environment variables. Keep the worker alive until the app exits, so subsequent operations avoid repeated interpreter startup. Use stopped/starting/ready/stopping lifecycle states and one shared startup task: simultaneous first requests await the same launch, never spawn duplicate workers.

Use UTF-8 newline-delimited JSON on stdin/stdout. Exactly one compact JSON object per LF-terminated frame; escape embedded newlines normally. Maximum frame: **1 MiB including LF**. Bound the byte accumulator before decoding, handle partial/multiple reads, and reject malformed UTF-8, duplicate JSON keys, non-finite numbers, missing required fields, invalid types, and unknown message kinds. Ignore additional envelope fields within v2 for forward-compatible metadata; model output objects remain strict. Swift uses the shared Core strict JSON preflight before Codable to detect duplicate decoded keys, including escaped aliases; Python uses a rejecting `object_pairs_hook` before strict model validation. No pretty-printed frames, banners, logs, progress text, or JSON-RPC dependency.

One writer serializes complete frames on each side; flush immediately. Continuously drain stdout and stderr independently without blocking the UI or async model tasks. Stderr content is discarded in the app; count bytes for a sanitized diagnostic, never persist arbitrary traceback text. Worker entry-point errors emit known error codes, without raw request/exception representations. Network/model libraries must not print to stdout.

Before launch, construct a small environment containing only required system locale/temp settings; clear inherited Python path/home, provider credentials/base URLs, LangSmith/tracing, and SDK debug settings. Use the bundled environment with user site packages disabled. Configure HTTP clients with the request snapshot's validated Base URL and credentials, TLS verification enabled, and `trust_env=False`; do not silently use a developer proxy or alternate CA setting. System-level routing still applies. Missing network reachability is an environment failure; proxy UI/configuration is deferred.

After spawn, the app sends hello. No credential is sent until ready validates. Startup deadline is 10 seconds. If executable/assets are missing, version/capabilities mismatch, or startup times out, fail locally without a model request. Do not silently fall back to system Python.

```json
{"v":2,"type":"hello"}
```

```json
{"v":2,"type":"ready","worker_version":"0.1.0","max_inflight":4,"prompt_versions":["translation.v1","translation.v2","alignment.v1"]}
```

`v` is integer 2 in every frame. `worker_version` is the actual packaged version string, not a success signal. All required prompt versions and `max_inflight: 4` must match this app's contract. Accept exactly one ready event after hello. An incompatible handshake may emit `fatal` and exit. Python does not write ready before successfully loading/validating its assets.

## Request envelope

| Field | Type / rule |
| --- | --- |
| `v` | Integer 2 |
| `type` | `request` |
| `id` | Fresh UUID string; never reuse within or across worker launches |
| `op` | `translate` or `align` |
| `config` | Required fields: `provider` (`openai`/`kimi`/`glm`/`deepseek`), nonempty `model` (at most 256 UTF-8 bytes), compatible `profile`, canonical HTTPS `base_url` (at most 2048 UTF-8 bytes), and `effort` from the configuration design. Reject unknown config fields and unsupported combinations before HTTP |
| `credentials` | Object: nonempty `api_key` string, at most 4096 UTF-8 bytes; pipe-only and never echoed |
| `prompt_version` | The job's recorded `translation.v1` or `translation.v2` for translate; `alignment.v1` for align. New jobs capture `translation.v2`; do not silently upgrade retained jobs. |
| `input` | Exact operation object below; validate before HTTP |

Supported profiles are `openai-json-schema-v1/v2` and `glm-json-v1/v2` (the slash abbreviates two literal IDs), plus `kimi-json-v2` and `deepseek-json-v2`, all within the v2 envelope. Ship the app and worker as a pair. Legacy profiles accept only their original Standard API Base URL and effective effort; v2 profiles follow [model configuration](model-settings.md#effort-capabilities-and-wire-mapping). Base URLs and keys travel only in local request frames; neither is echoed in metadata, model messages, errors or diagnostics. The worker must never substitute a hardcoded/environment endpoint. A local missing/deleted/changed configuration is `configuration_unavailable` before worker dispatch, not a new Python wire error.

The app keeps request ownership in its registry: tab session ID, document ID, source revision, job ID, attempt generation, operation, selection identity if applicable, expected units, and target generation. Do not send this entire state to Python or the model. The request ID is the transport correlation key; a result only updates the registry's current owner after all generation checks pass.

### Translate input

Required fields: `source_language`, `target_language` (`en`/`zh`, distinct); `context_before`, `context_after` (strings); `units` (1–64 objects containing exactly `unit_id`, `kind`, `text`). Unit IDs are unique UUID strings in application IPC. Kind is `sentence` or `fragment`. Text is nonempty, trimmed at its outer boundaries. Apply all byte and context limits from model workflow.

```json
{
  "v": 2,
  "type": "request",
  "id": "11111111-1111-4111-8111-111111111111",
  "op": "translate",
  "config": {"provider": "openai", "model": "gpt-4.1-mini-2025-04-14", "profile": "openai-json-schema-v2", "base_url": "https://api.openai.com/v1/", "effort": "auto"},
  "credentials": {"api_key": "SYNTHETIC_TEST_CREDENTIAL"},
  "prompt_version": "translation.v2",
  "input": {
    "source_language": "en",
    "target_language": "zh",
    "context_before": "",
    "context_after": "",
    "units": [{"unit_id": "22222222-2222-4222-8222-222222222222", "kind": "sentence", "text": "The window is open."}]
  }
}
```

These examples are pretty-printed for reading; the actual wire frame is compact and occupies one line. The credential above is deliberately synthetic, not a key format example.

### Align input

Required fields: `reading_text`, `counterpart_text`, and `selection` with `before`, `text`, `after`. All are strings. The selection must be nonempty, and its three parts must concatenate exactly to reading_text. Apply the selection/unit and serialized-input limits from model workflow. Config selects the existing translation job's frozen profile/model/effort/endpoint, not the current default. Reverse selection swaps reading/counterpart sides without changing the protocol.

```json
{
  "v": 2,
  "type": "request",
  "id": "33333333-3333-4333-8333-333333333333",
  "op": "align",
  "config": {"provider": "glm", "model": "glm-4.7-flash", "profile": "glm-json-v2", "base_url": "https://open.bigmodel.cn/api/paas/v4/", "effort": "off"},
  "credentials": {"api_key": "SYNTHETIC_TEST_CREDENTIAL"},
  "prompt_version": "alignment.v1",
  "input": {
    "reading_text": "I can can fruit.",
    "counterpart_text": "我会把水果装罐。",
    "selection": {"before": "I can ", "text": "can", "after": " fruit."}
  }
}
```

## Terminal responses

Every accepted request produces exactly one terminal event: `result`, `error`, or `cancelled`. Different requests may finish out of order. Python owns the terminal-event guard, including cancellation/success races. An unknown or duplicate terminal ID from the current live worker is a protocol failure: do not mutate a document, stop that worker, and fail its remaining requests. Callbacks from an already invalidated worker instance are simply ignored. Never attach an unknown result to the currently selected tab.

A result contains `v`, `type`, `id`, `data`, and `meta`. `data` is the canonical validated model output. Required `meta` fields: `provider`, `requested_model`, `requested_effort`, nullable `returned_model`, `prompt_version`, nullable nonnegative integer `input_tokens` and `output_tokens`. Match provider/requested model/requested effort/prompt to the registry. Effort echoes the canonical requested value, including Auto; it is not a claim about measured provider reasoning. A returned model name is attribution, not permission to select a different requested model.

```json
{
  "v": 2,
  "type": "result",
  "id": "11111111-1111-4111-8111-111111111111",
  "data": {"translations": [{"unit_id": "22222222-2222-4222-8222-222222222222", "text": "窗户开着。"}]},
  "meta": {"provider": "openai", "requested_model": "gpt-4.1-mini-2025-04-14", "requested_effort": "auto", "returned_model": null, "prompt_version": "translation.v2", "input_tokens": null, "output_tokens": null}
}
```

```json
{
  "v": 2,
  "type": "result",
  "id": "33333333-3333-4333-8333-333333333333",
  "data": {"status": "matched", "matches": [{"quote": "装罐", "occurrence": 1}], "reason": "none"},
  "meta": {"provider": "glm", "requested_model": "glm-4.7-flash", "requested_effort": "off", "returned_model": null, "prompt_version": "alignment.v1", "input_tokens": null, "output_tokens": null}
}
```

An error contains `v`, `type`, `id`, `code`, and `retry_after_ms` (null or an integer 0–3600000). Codes: `invalid_request`, `unsupported_capability`, `missing_credential`, `authentication`, `model_unavailable`, `quota_exceeded`, `rate_limited`, `network`, `timeout`, `context_limit`, `output_limit`, `refused`, `invalid_output`, `busy`, `worker_failed`. Swift owns localized messages and actions. The optional diagnostics are `http_status` (integer 300–599), `provider_code` (a recognized provider code as a string), and `validation_reason` (a fixed worker validation category). Omit unavailable values. Swift accepts legacy error frames and discards unrecognized optional diagnostics. Never forward provider messages, response bodies, exceptions, credentials, or document text. Retry policy is defined in model workflow; there is no model call for a preflight/validation error.

For rate-limit responses, convert the HTTP `Retry-After` delay in seconds or HTTP date to the existing bounded millisecond field. An elapsed date yields zero and an unavailable or unparseable value yields null. The raw header stays in the worker.

```json
{"v":2,"type":"error","id":"11111111-1111-4111-8111-111111111111","code":"rate_limited","retry_after_ms":2000,"http_status":429,"provider_code":"1302"}
```

Malformed requests with a valid unique request ID receive `invalid_request`. An unidentifiable/malformed frame, duplicate active request ID, or invalid handshake is fatal because correlation cannot be trusted. A fifth concurrent request receives `busy` with no HTTP call (four physical slots); this is an app scheduling defect to test, not a normal hidden queue.

## Cancellation, deadlines, and exit

```json
{"v":2,"type":"cancel","id":"11111111-1111-4111-8111-111111111111"}
```

```json
{"v":2,"type":"cancelled","id":"11111111-1111-4111-8111-111111111111"}
```

Cancel uses the target request ID and has no separate acknowledgement/request ID. For active requests, cancel the async task and its HTTP operation, then emit cancelled once unless another terminal event already won. For unknown/already terminal IDs, do nothing. Do not close a shared HTTP client in a way that cancels another request.

Swift cancellation invalidates the result generation immediately, resumes its caller with cancellation, and keeps a small draining registry entry until the terminal event or worker failure. A physical concurrency slot is released only then. Resume waits for the prior translation requests of that tab session (up to two concurrent batches) to drain. A late result may release that slot but cannot commit text. Python enforces the 120-second total invocation deadline and normally returns a per-request `timeout` error. Use a separate 130-second transport watchdog from actual dispatch: only absence of any terminal frame by that later deadline poisons/stops the unresponsive worker and explicitly fails remaining active requests. The 10-second margin permits normal timeout/cancellation-frame delivery; a normal 120-second provider timeout must leave another live request intact. Cancellation responsiveness is a separate acceptance gate, not permission to block the UI during either deadline.

On malformed output, unexpected EOF, or worker crash, invalidate every request owned by that worker instance, retain committed text, pause queued jobs, and show the failure. Never auto-replay a paid operation. The next explicit Retry/Translate may launch a new instance after the old one is fully reaped. Associate callbacks with a worker-instance UUID so old pipe callbacks cannot affect its replacement.

On approved application quit, send shutdown, close stdin, and stop accepting work:

```json
{"v":2,"type":"shutdown"}
```

Worker cancels active tasks, closes HTTP clients, emits stopped, and exits. Stdin EOF has the same effect even if the parent crashed. Swift waits asynchronously up to 2 seconds, sends terminate if necessary, then force-kills only its owned child after a further second and reaps it. Never terminate by a global process-name match. The onedir helper must not leave a launcher/grandchild behind.

```json
{"v":2,"type":"stopped"}
```

Fatal process errors use a bounded code, then exit nonzero:

```json
{"v":2,"type":"fatal","code":"incompatible_protocol"}
```

Other fatal codes are `invalid_frame`, `missing_asset`, and `worker_failed`. The app does not wait for terminal events after a fatal/EOF; it resolves outstanding operations from its registry. Authentication and model failures are per-request errors and must not normally kill the worker.

## Required cross-language checks

Turn every JSON example here into a shared fixture consumed by Swift Codable and Python models. Add negative cases for split UTF-8 reads, embedded newlines, duplicate keys/IDs, wrong versions, unknown fields/kinds, oversize frames, corrupt JSON, stdout pollution, out-of-order completion, duplicate terminal events, cancellation races, hung worker, EOF, and no-credentials-before-ready. Tests must launch the real worker in a fixture-only mode without network access; fixture mode is unavailable in a release bundle.

A fake provider proves transport, not provider compatibility. Both live-provider and copied-bundle checks remain required by the [test plan](../testing.md).
