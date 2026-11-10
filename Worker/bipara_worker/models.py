"""Provider profiles and the LangChain model operation.

The profiles follow docs/design/model-workflow.md and the capability
mapping in docs/design/model-settings.md exactly: legacy v1 profiles keep
their original fixed sampling/reasoning parameters and Standard API URL;
v2 profiles derive temperature, thinking controls, graded effort, and
reasoning-inclusive output caps from the local capability table. A guard
verifies the final serialized request body immediately before HTTP
transport; any silent SDK mutation fails as ``unsupported_capability``
with zero HTTP calls. LangChain imports stay deferred so handshake
latency is independent of the provider stack.
"""

from __future__ import annotations

import math
import re
import time
from dataclasses import dataclass, field
from email.utils import parsedate_to_datetime
from typing import Any

import httpx

from .assets import Assets
from .errors import ValidationFailure, WorkerError
from .protocol import (
    AlignInput,
    Config,
    Request,
    TranslateInput,
    decode_json_strict,
    serialize_input,
)
from .validation import validate_alignment_output, validate_translation_output

OPENAI_BASE_URL = "https://api.openai.com/v1/"
GLM_BASE_URL = "https://open.bigmodel.cn/api/paas/v4/"
GLM_CODING_PLAN_BASE_URL = "https://open.bigmodel.cn/api/coding/paas/v4/"
DEFAULT_MODELS = {"openai": "gpt-4.1-mini-2025-04-14", "glm": "glm-4.7-flash"}
TEMPERATURE = 0.2
# v2 output caps include the reasoning budget. Accepted design revision
# (owner, 2026-11-05): the v2 plain caps doubled together with the batch
# text bound; both legacy profiles keep their original caps below.
TRANSLATION_CAP_PLAIN = 8192
ALIGNMENT_CAP_PLAIN = 2048
TRANSLATION_CAP_REASONING = 16384
ALIGNMENT_CAP_REASONING = 4096
LEGACY_TRANSLATION_CAP = 4096
LEGACY_ALIGNMENT_CAP = 1024
CONNECT_TIMEOUT_SECONDS = 10.0

# Known legacy OpenAI IDs that predate Chat Completions structured outputs.
_LEGACY_OPENAI_ID = re.compile(r"^(gpt-4(-|$)|gpt-3)")


@dataclass(frozen=True)
class ModelCapability:
    """One capability-table entry: the effort choices a model supports and
    how they map to provider parameters.

    Modes: ``plain`` has no reasoning controls (Auto only); ``binary`` uses
    ``thinking.type`` enabled/disabled without graded effort; ``graded``
    accepts ``reasoning_effort`` and can also disable reasoning (Off);
    ``forced`` cannot disable thinking and accepts ``reasoning_effort``
    only.
    """

    efforts: tuple[str, ...]
    mode: str


# Local capability table (mirrored by the Swift app), checked 2026-11-05
# against docs.bigmodel.cn and developers.openai.com. GLM notes:
# ``reasoning_effort`` is GLM-5.2+ only; the GLM-5.3 series rejects
# ``thinking.type: disabled`` and accepts reasoning_effort low/high/max
# only; GLM-5.2 additionally accepts minimal, and the provider maps
# low/medium to high and xhigh to max. OpenAI notes: ``off`` maps to
# ``reasoning_effort: "none"`` and is offered only where the model accepts
# disabling reasoning; gpt-5.5/5.4/5.2 top out at xhigh. Unknown models
# are attempted once with Auto only; an explicit effort for them requires
# a documented capability entry and tests first.
CAPABILITIES: dict[tuple[str, str], ModelCapability] = {
    # OpenAI (deprecated gpt-4.1 family removal: 2027-01-14).
    ("openai", "gpt-6-sol"): ModelCapability(("auto", "off", "low", "medium", "high", "xhigh", "max"), "graded"),
    ("kimi", "kimi-k3.1-pro"): ModelCapability(("auto", "low", "high", "max"), "graded"),
    ("kimi", "kimi-k3.1-pro-highspeed"): ModelCapability(("auto", "low", "high", "max"), "graded"),
    ("kimi", "kimi-k3"): ModelCapability(("auto", "low", "high", "max"), "graded"),
    ("deepseek", "deepseek-flash"): ModelCapability(("auto", "off", "low", "high", "max"), "graded"),
    ("deepseek", "deepseek-v4-pro"): ModelCapability(("auto", "off", "low", "high", "max"), "graded"),
    ("openai", "gpt-4.1-mini-2025-04-14"): ModelCapability(("auto",), "plain"),
    ("openai", "gpt-6-astra"): ModelCapability(("auto", "low", "medium", "high", "xhigh", "max"), "graded"),
    ("openai", "gpt-6-luna"): ModelCapability(("auto", "off", "low", "medium", "high", "xhigh", "max"), "graded"),
    ("openai", "gpt-6.1-sol"): ModelCapability(("auto", "low", "medium", "high", "xhigh", "max"), "graded"),
    ("openai", "gpt-6.1-terra"): ModelCapability(("auto", "off", "low", "medium", "high", "xhigh", "max"), "graded"),
    ("openai", "gpt-5.6"): ModelCapability(("auto", "off", "low", "medium", "high", "xhigh", "max"), "graded"),
    ("openai", "gpt-5.6-sol"): ModelCapability(("auto", "off", "low", "medium", "high", "xhigh", "max"), "graded"),
    ("openai", "gpt-5.6-terra"): ModelCapability(("auto", "off", "low", "medium", "high", "xhigh", "max"), "graded"),
    ("openai", "gpt-5.6-luna"): ModelCapability(("auto", "off", "low", "medium", "high", "xhigh", "max"), "graded"),
    ("openai", "gpt-5.5"): ModelCapability(("auto", "off", "low", "medium", "high", "xhigh"), "graded"),
    ("openai", "gpt-5.4"): ModelCapability(("auto", "off", "low", "medium", "high", "xhigh"), "graded"),
    ("openai", "gpt-5.2"): ModelCapability(("auto", "off", "low", "medium", "high", "xhigh"), "graded"),
    # GLM
    ("glm", "glm-5.3"): ModelCapability(("auto", "low", "high", "max"), "forced"),
    ("glm", "glm-5.3-flash"): ModelCapability(("auto", "low", "high", "max"), "forced"),
    ("glm", "glm-5.3-flashx"): ModelCapability(("auto", "low", "high", "max"), "forced"),
    ("glm", "glm-5.3-flashx-legal"): ModelCapability(("auto", "low", "high", "max"), "forced"),
    ("glm", "glm-5.2"): ModelCapability(("auto", "off", "minimal", "low", "medium", "high", "xhigh", "max"), "graded"),
    ("glm", "glm-5.1"): ModelCapability(("auto", "off", "on"), "binary"),
    ("glm", "glm-5"): ModelCapability(("auto", "off", "on"), "binary"),
    ("glm", "glm-5-turbo"): ModelCapability(("auto", "off", "on"), "binary"),
    ("glm", "glm-4.7"): ModelCapability(("auto", "off", "on"), "binary"),
    ("glm", "glm-4.7-flashx"): ModelCapability(("auto", "off", "on"), "binary"),
    ("glm", "glm-4.7-flash"): ModelCapability(("auto", "off", "on"), "binary"),
}


def capability_for(config: Config) -> ModelCapability | None:
    return CAPABILITIES.get((config.provider, config.model))


def efforts_for(provider: str, model: str) -> tuple[str, ...]:
    entry = CAPABILITIES.get((provider, model))
    return entry.efforts if entry is not None else ("auto",)


def check_capability(config: Config) -> None:
    """Reject unsupported effort/model combinations before any model call.

    Legacy OpenAI IDs and unsupported v2 effort values are
    ``unsupported_capability``; v1 profile URL/effort exactness is enforced
    at envelope parsing.
    """

    if config.options is not None:
        return
    if config.provider == "openai" and _LEGACY_OPENAI_ID.match(config.model):
        raise WorkerError("unsupported_capability")
    if config.profile.endswith("-v2") and config.effort not in efforts_for(
        config.provider, config.model
    ):
        raise WorkerError("unsupported_capability")


def output_caps(config: Config, op: str) -> tuple[int, int]:
    """(translation, alignment) output caps including reasoning budget.

    Both legacy profiles keep their original 4096/1024 caps. In v2, a
    known plain model or explicit Off uses the plain caps; enabled,
    graded, Auto reasoning and unknown v2 entries use the larger initial
    totals.
    """

    capability = capability_for(config)
    reasoning = (
        config.profile.endswith("-v2")
        and config.effort != "off"
        and (capability is None or capability.mode != "plain")
    )
    if config.profile.endswith("-v1"):
        return LEGACY_TRANSLATION_CAP, LEGACY_ALIGNMENT_CAP
    if not reasoning:
        return TRANSLATION_CAP_PLAIN, ALIGNMENT_CAP_PLAIN
    return TRANSLATION_CAP_REASONING, ALIGNMENT_CAP_REASONING


def build_shared_http_client() -> httpx.AsyncClient:
    """One shared async HTTP client for every provider request.

    ``trust_env=False`` ignores proxy/CA environment variables so a
    developer proxy can never silently receive credentials, redirects are
    disabled, and the only timeout is the 10-second connect phase (the
    120-second total deadline is enforced by the runtime).
    """

    return httpx.AsyncClient(
        trust_env=False,
        follow_redirects=False,
        timeout=httpx.Timeout(connect=CONNECT_TIMEOUT_SECONDS, read=None, write=None, pool=None),
    )


@dataclass(frozen=True)
class ExpectedBody:
    """The profile/capability-derived contract for the final HTTP body."""

    temperature: float | None = None
    token_field: str = "max_completion_tokens"
    token_cap: int = 0
    thinking: dict[str, Any] | None = None
    reasoning_effort: str | None = None
    response_format: dict[str, Any] | None = None


@dataclass(frozen=True)
class BuiltModel:
    """The bound model plus the exact kwargs used to bind it and the
    expected final body, so the guard can serialize and verify the same
    payload the invocation will send. Test fakes carry ``expected=None``."""

    model: Any
    bind_kwargs: dict[str, Any] = field(default_factory=dict)
    expected: ExpectedBody | None = None


def _strict_json_schema_binding(schema: dict[str, Any]) -> dict[str, Any]:
    return {
        "response_format": {
            "type": "json_schema",
            "json_schema": {
                "name": schema["title"],
                "strict": True,
                "schema": schema,
            },
        }
    }


def _build_model(
    request: Request,
    api_key: str,
    schema: dict[str, Any],
    http_async_client: httpx.AsyncClient | None,
) -> BuiltModel:
    if request.config.options is not None:
        from .open_protocol import build_model
        return BuiltModel(model=build_model(request, schema, http_async_client))

    from langchain_openai import ChatOpenAI

    config = request.config
    translation_cap, alignment_cap = output_caps(config, request.op)
    cap = translation_cap if request.op == "translate" else alignment_cap
    common: dict[str, Any] = {
        "model": config.model,
        "api_key": api_key,
        "max_retries": 0,
        "use_responses_api": False,
        "base_url": config.base_url,
    }
    if http_async_client is not None:
        common["http_async_client"] = http_async_client

    if config.provider == "openai":
        if config.profile == "openai-json-schema-v1":
            common.update(temperature=TEMPERATURE, max_completion_tokens=cap)
            kwargs = _strict_json_schema_binding(schema)
            return BuiltModel(
                model=ChatOpenAI(**common).bind(**kwargs),
                bind_kwargs=kwargs,
                expected=ExpectedBody(
                    temperature=TEMPERATURE,
                    token_field="max_completion_tokens",
                    token_cap=cap,
                    response_format=kwargs["response_format"],
                ),
            )
        # openai-json-schema-v2: capability-derived parameters.
        capability = capability_for(config)
        plain = capability is not None and capability.mode == "plain"
        if plain:
            common.update(temperature=TEMPERATURE, max_completion_tokens=cap)
            reasoning_effort = None
        else:
            # Known graded entries and unknown models alike: no sampling
            # fields; Off maps to "none", a graded value is sent verbatim,
            # Auto omits it. check_capability rejects an Off the model does
            # not accept and an explicit effort for an unknown model.
            common.update(max_completion_tokens=cap)
            reasoning_effort = (
                "none" if config.effort == "off"
                else config.effort if config.effort != "auto"
                else None
            )
            if reasoning_effort is not None:
                common["reasoning_effort"] = reasoning_effort
        kwargs = _strict_json_schema_binding(schema)
        return BuiltModel(
            model=ChatOpenAI(**common).bind(**kwargs),
            bind_kwargs=kwargs,
            expected=ExpectedBody(
                temperature=TEMPERATURE if plain else None,
                token_field="max_completion_tokens",
                token_cap=cap,
                reasoning_effort=reasoning_effort,
                response_format=kwargs["response_format"],
            ),
        )

    # Compatible providers use JSON-object mode with local validation.
    token_field = "max_completion_tokens" if config.provider == "kimi" else "max_tokens"
    capability = capability_for(config)
    mode = capability.mode if capability is not None else None
    extra: dict[str, Any] = {token_field: cap}
    temperature: float | None = None
    reasoning_effort: str | None = None
    if config.profile == "glm-json-v1":
        common.update(temperature=TEMPERATURE)
        extra["thinking"] = {"type": "disabled"}
        temperature = TEMPERATURE
    elif mode == "binary":
        # Binary thinking models; never a graded effort.
        common.update(temperature=TEMPERATURE)
        temperature = TEMPERATURE
        thinking_type = {"off": "disabled", "on": "enabled"}.get(config.effort)
        if thinking_type is not None:
            extra["thinking"] = {"type": thinking_type}
    elif mode == "forced":
        # GLM-5.3 series: thinking cannot be disabled; omit sampling.
        extra["thinking"] = {"type": "enabled"}
        if config.effort != "auto":
            reasoning_effort = config.effort
    elif config.provider == "kimi":
        if config.effort != "auto":
            reasoning_effort = config.effort
    elif mode == "graded":
        # GLM-5.2 and DeepSeek: Off disables thinking; a graded value enables it and is
        # sent verbatim; Auto omits both.
        if config.effort == "off":
            extra["thinking"] = {"type": "disabled"}
        elif config.effort != "auto":
            extra["thinking"] = {"type": "enabled"}
            reasoning_effort = config.effort
    else:
        # Unknown model: Auto only, no
        # model-specific thinking/sampling fields.
        pass
    if reasoning_effort is not None:
        extra["reasoning_effort"] = reasoning_effort
    kwargs = {"response_format": {"type": "json_object"}, "extra_body": extra}
    return BuiltModel(
        model=ChatOpenAI(**common).bind(**kwargs),
        bind_kwargs=kwargs,
        expected=ExpectedBody(
            temperature=temperature,
            token_field=token_field,
            token_cap=cap,
            thinking=extra.get("thinking"),
            reasoning_effort=reasoning_effort,
            response_format=kwargs["response_format"],
        ),
    )


def _effective_body(payload: dict[str, Any]) -> dict[str, Any]:
    """The wire body the OpenAI client sends: payload with ``extra_body``
    contents merged at the top level."""

    effective = {key: value for key, value in payload.items() if key != "extra_body"}
    extra = payload.get("extra_body")
    if isinstance(extra, dict):
        effective.update(extra)
    return effective


def _guard_final_body(built: BuiltModel, messages: list[Any]) -> None:
    """Verify the final serialized request body against the profile and
    capability entry immediately before HTTP. Any silent adapter mutation
    — dropped temperature, changed cap, added tools — is
    ``unsupported_capability`` with zero HTTP calls."""

    expected = built.expected
    assert expected is not None  # guarded by the caller
    payload = built.model._get_request_payload(messages, **built.bind_kwargs)
    if not isinstance(payload, dict):
        raise WorkerError("unsupported_capability")
    body = _effective_body(payload)

    if body.get("model") != built.model.model_name:
        raise WorkerError("unsupported_capability")
    if body.get("stream") not in (None, False):
        raise WorkerError("unsupported_capability")
    if "tools" in body or "tool_choice" in body:
        raise WorkerError("unsupported_capability")
    if expected.temperature is None:
        if "temperature" in body:
            raise WorkerError("unsupported_capability")
    elif body.get("temperature") != expected.temperature:
        raise WorkerError("unsupported_capability")
    if body.get(expected.token_field) != expected.token_cap:
        raise WorkerError("unsupported_capability")
    other_field = "max_tokens" if expected.token_field == "max_completion_tokens" else "max_completion_tokens"
    if other_field in body:
        raise WorkerError("unsupported_capability")
    if expected.thinking is None:
        if "thinking" in body:
            raise WorkerError("unsupported_capability")
    elif body.get("thinking") != expected.thinking:
        raise WorkerError("unsupported_capability")
    if expected.reasoning_effort is None:
        if "reasoning_effort" in body:
            raise WorkerError("unsupported_capability")
    elif body.get("reasoning_effort") != expected.reasoning_effort:
        raise WorkerError("unsupported_capability")
    if expected.response_format is not None and body.get("response_format") != expected.response_format:
        raise WorkerError("unsupported_capability")
    wire_messages = payload.get("messages")
    if not isinstance(wire_messages, list) or len(wire_messages) != 2:
        raise WorkerError("unsupported_capability")
    expected_roles = ("system", "user")
    for wire, message, role in zip(wire_messages, messages, expected_roles):
        if not isinstance(wire, dict):
            raise WorkerError("unsupported_capability")
        if wire.get("role") != role or wire.get("content") != message.content:
            raise WorkerError("unsupported_capability")


def _normalize_provider_error(exc: BaseException) -> WorkerError:
    """Map SDK failures without retaining provider messages or response bodies."""

    from openai import APIStatusError

    mapping = {
        "AuthenticationError": "authentication",
        "RateLimitError": "rate_limited",
        "NotFoundError": "model_unavailable",
        "PermissionDeniedError": "authentication",
        "APIConnectionError": "network",
        "APITimeoutError": "timeout",
        "InternalServerError": "network",
        "LengthFinishReasonError": "output_limit",
        "ContentFilterFinishReasonError": "refused",
        "UnprocessableEntityError": "unsupported_capability",
        "OpenAIContextOverflowError": "context_limit",
        "OpenAIAPIContextOverflowError": "context_limit",
        "BadRequestError": "invalid_request",
    }
    # LangChain subclasses SDK exceptions with its own class names.
    code = next((mapping[cls.__name__] for cls in type(exc).__mro__ if cls.__name__ in mapping), "worker_failed")
    http_status = None
    provider_code = None
    if isinstance(exc, APIStatusError):
        http_status = exc.status_code
        body = exc.body
        if isinstance(body, dict):
            error = body.get("error", body)
            if isinstance(error, dict):
                provider_code = error.get("code")
        if http_status == 402:
            code = "quota_exceeded"
        elif http_status == 413:
            code = "context_limit"
    retry_after_ms = _retry_after_ms(exc) if code == "rate_limited" else None
    return WorkerError(code, retry_after_ms, http_status=http_status, provider_code=provider_code)


def _retry_after_ms(exc: BaseException) -> int | None:
    response = getattr(exc, "response", None)
    header = response.headers.get("Retry-After") if response is not None else None
    try:
        if header is None:
            delay = float(getattr(exc, "retry_after", None))
        elif header.isascii() and header.isdecimal():
            delay = float(header)
        else:
            retry_date = parsedate_to_datetime(header)
            if retry_date.tzinfo is None:
                return None
            delay = retry_date.timestamp() - time.time()
        if math.isnan(delay):
            return None
        return math.ceil(max(0, min(delay, 3600)) * 1000)
    except (TypeError, ValueError, OverflowError, OSError):
        return None


def _parse_model_content(content: Any) -> Any:
    if not isinstance(content, str) or not content.strip():
        raise WorkerError("invalid_output", validation_reason=ValidationFailure.MISSING_CONTENT)
    try:
        return decode_json_strict(content)
    except Exception as exc:
        if isinstance(exc, WorkerError):
            raise
        raise WorkerError("invalid_output", validation_reason=ValidationFailure.INVALID_JSON) from exc


def _returned_model(message: Any) -> str | None:
    metadata = getattr(message, "response_metadata", None)
    if not isinstance(metadata, dict):
        return None
    value = metadata.get("model_name") or metadata.get("model")
    return value if isinstance(value, str) and value else None


def _token_usage(message: Any) -> tuple[int | None, int | None]:
    usage = getattr(message, "usage_metadata", None)
    if isinstance(usage, dict):
        input_tokens = usage.get("input_tokens")
        output_tokens = usage.get("output_tokens")

        def _clean(value: Any) -> int | None:
            if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
                return value
            return None

        return _clean(input_tokens), _clean(output_tokens)
    return None, None


def make_langchain_operation(
    assets: Assets, http_async_client: httpx.AsyncClient | None = None
):
    """Build the single model operation and its shutdown cleanup.

    The operation performs one LangChain invocation per request. The
    optional shared HTTP client must be closed through the returned
    ``aclose`` coroutine on shutdown.
    """

    async def operation(request: Request) -> tuple[dict[str, Any], dict[str, Any]]:
        check_capability(request.config)
        prompt_text = assets.prompts[request.prompt_version]
        schema = assets.schemas[request.prompt_version]
        payload = serialize_input(request.input.as_input_object())
        # Imported lazily: handshake and fixture paths stay LangChain-free.
        from langchain_core.messages import HumanMessage, SystemMessage

        built = _build_model(request, request.api_key, schema, http_async_client)
        messages = [
            SystemMessage(content=prompt_text),
            HumanMessage(content=payload),
        ]
        if built.expected is not None:
            # Profile guard before HTTP transport: verify the exact body
            # this invocation will send. Zero HTTP calls on failure.
            _guard_final_body(built, messages)
        try:
            message = await built.model.ainvoke(messages)
        except WorkerError:
            raise
        except Exception as exc:
            raise _normalize_provider_error(exc) from exc

        finish_reason = None
        metadata = getattr(message, "response_metadata", None)
        if isinstance(metadata, dict):
            finish_reason = metadata.get("finish_reason")
        if finish_reason == "length":
            raise WorkerError("output_limit")
        if finish_reason == "content_filter":
            raise WorkerError("refused")

        data = _parse_model_content(getattr(message, "content", None))
        if isinstance(request.input, TranslateInput):
            validated = validate_translation_output(
                data, [unit.unit_id for unit in request.input.units]
            )
        elif isinstance(request.input, AlignInput):
            validated = validate_alignment_output(data, request.input.counterpart_text)
        else:  # pragma: no cover - parse_request only yields the two input types
            raise WorkerError("invalid_request")
        input_tokens, output_tokens = _token_usage(message)
        meta = {
            "provider": request.config.provider,
            "requested_model": request.config.model,
            "requested_effort": request.config.effort,
            "returned_model": _returned_model(message),
            "prompt_version": request.prompt_version,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
        }
        return validated, meta

    async def aclose() -> None:
        if http_async_client is not None:
            await http_async_client.aclose()

    return operation, aclose
