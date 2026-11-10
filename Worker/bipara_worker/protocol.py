"""Strict wire-format codec and envelope validation for worker protocol v2.

Every inbound frame is decoded strictly before any interpretation:
UTF-8, one complete JSON value, no duplicate object keys (including keys
that differ only in escape spelling), no non-finite numbers. Frames that
cannot be trusted for request correlation raise FatalError; malformed
requests that still carry a valid unique request ID raise RequestError so
the caller can answer with a per-request ``invalid_request`` error frame.

Protocol v2 carries the explicit Base URL and effort in request config and
the requested effort in result metadata. A protocol-1 peer is rejected at
handshake before any credential is transmitted.
"""

from __future__ import annotations

import json
import math
import re
import uuid
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urlsplit

PROTOCOL_VERSION = 2
MAX_FRAME_BYTES = 1024 * 1024  # 1 MiB including the terminating LF

INBOUND_KINDS = ("hello", "request", "cancel", "shutdown")
FATAL_CODES = ("incompatible_protocol", "invalid_frame", "missing_asset", "worker_failed")

ERROR_CODES = (
    "invalid_request",
    "unsupported_capability",
    "missing_credential",
    "authentication",
    "model_unavailable",
    "quota_exceeded",
    "rate_limited",
    "network",
    "timeout",
    "context_limit",
    "output_limit",
    "refused",
    "invalid_output",
    "busy",
    "worker_failed",
)

PROVIDERS = ("openai", "kimi", "glm", "deepseek", "anthropic")
OPEN_PROFILES = {"openai-responses-v3": "openai", "anthropic-messages-v3": "anthropic"}
PROFILES_BY_PROVIDER = {
    "openai": ("openai-json-schema-v1", "openai-json-schema-v2", "openai-responses-v3"),
    "glm": ("glm-json-v1", "glm-json-v2"),
    "kimi": ("kimi-json-v2",),
    "deepseek": ("deepseek-json-v2",),
    "anthropic": ("anthropic-messages-v3",),
}
# A v1 profile accepts only its original Standard API URL and effective
# effort (OpenAI Auto, GLM Off).
LEGACY_PROFILE_BASE_URL = {
    "openai-json-schema-v1": "https://api.openai.com/v1/",
    "glm-json-v1": "https://open.bigmodel.cn/api/paas/v4/",
}
LEGACY_PROFILE_EFFORT = {"openai-json-schema-v1": "auto", "glm-json-v1": "off"}
TRANSLATE_PROMPT_VERSION = "translation.v2"
TRANSLATE_PROMPT_VERSIONS = ("translation.v1", TRANSLATE_PROMPT_VERSION)
ALIGN_PROMPT_VERSION = "alignment.v1"
PROMPT_VERSIONS = (*TRANSLATE_PROMPT_VERSIONS, ALIGN_PROMPT_VERSION)
# Accepted design revision (owner, 2026-11-05): 2 -> 4 so phrase alignment
# keeps headroom while up to two translation batches per document session
# run in parallel.
MAX_INFLIGHT = 4

# Canonical effort values from the model configuration design. `minimal` is
# offered only for capability entries whose provider documents it.
EFFORTS = ("auto", "off", "on", "minimal", "low", "medium", "high", "xhigh", "max")
MAX_BASE_URL_BYTES = 2048

# Input bounds from the model workflow contract. Accepted design revision
# (owner, 2026-11-05): doubled the batch-text and unit bounds so a typical
# document plans into fewer batches.
LANGUAGES = ("en", "zh")
UNIT_KINDS = ("sentence", "fragment")
MAX_UNITS_PER_BATCH = 64
MAX_BATCH_TEXT_BYTES = 8192
MAX_CONTEXT_BYTES = 512
MAX_INPUT_JSON_BYTES = 32768
MAX_MODEL_ID_BYTES = 256
MAX_API_KEY_BYTES = 4096
MAX_ALIGN_SELECTION_BYTES = 512
MAX_ALIGN_TEXT_BYTES = 8192  # reading_text + counterpart_text combined

# Model-output bounds from the model workflow contract.
MAX_TRANSLATION_BYTES = 8192
MAX_DECODED_CONTENT_BYTES = 131072
MAX_MATCHES = 8


class FatalError(Exception):
    """The frame or process state cannot be trusted; the worker must stop."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class RequestError(Exception):
    """A malformed request whose valid unique ID still allows a reply."""


def _reject_constant(name: str) -> Any:
    raise ValueError("non-finite JSON number")


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    obj: dict[str, Any] = {}
    for key, value in pairs:
        if key in obj:
            raise ValueError("duplicate JSON object key")
        obj[key] = value
    return obj


def _reject_nonfinite_float(text: str) -> float:
    value = float(text)
    if not math.isfinite(value):
        raise ValueError("non-finite JSON number")
    return value


def decode_json_strict(text: str) -> Any:
    """Parse one complete strict JSON value.

    Rejects duplicate decoded keys, NaN/Infinity literals, and numbers
    that overflow to a non-finite value (e.g. ``1e999``), including inside
    forward-compatible envelope fields.
    """

    try:
        return json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_constant,
            parse_float=_reject_nonfinite_float,
        )
    except ValueError as exc:
        raise FatalError("invalid_frame") from exc


def decode_frame(line: bytes) -> Any:
    """Decode one LF-terminated wire frame (LF included) strictly."""

    if len(line) > MAX_FRAME_BYTES:
        raise FatalError("invalid_frame")
    try:
        text = line.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise FatalError("invalid_frame") from exc
    return decode_json_strict(text)


def encode_frame(value: Any) -> bytes:
    """Encode one compact wire frame including the terminating LF."""

    text = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    data = text.encode("utf-8") + b"\n"
    if len(data) > MAX_FRAME_BYTES:
        raise ValueError("outbound frame exceeds the 1 MiB bound")
    return data


def is_canonical_uuid(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError):
        return False
    return str(parsed) == value


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def utf8_len(value: str) -> int:
    return len(value.encode("utf-8"))


def request_utf8_len(value: str, what: str) -> int:
    """UTF-8 size for request validation.

    An unpaired surrogate (e.g. from an escaped ``\\ud800`` in the frame)
    cannot be encoded; the request carries a valid unique ID, so this is
    an identifiable malformed request, not a transport failure.
    """

    try:
        return len(value.encode("utf-8"))
    except UnicodeEncodeError as exc:
        raise RequestError(f"{what} contains unpaired surrogate code points") from exc


def serialize_input(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def input_json_size(value: Any) -> int:
    try:
        return len(serialize_input(value).encode("utf-8"))
    except UnicodeEncodeError as exc:
        raise RequestError("serialized input contains unpaired surrogate code points") from exc


@dataclass(frozen=True)
class Config:
    provider: str
    model: str
    profile: str
    base_url: str
    effort: str
    options: dict[str, Any] | None = None


@dataclass(frozen=True)
class TranslateUnit:
    unit_id: str
    kind: str
    text: str


@dataclass(frozen=True)
class TranslateInput:
    source_language: str
    target_language: str
    context_before: str
    context_after: str
    units: tuple[TranslateUnit, ...]

    def as_input_object(self) -> dict[str, Any]:
        return {
            "source_language": self.source_language,
            "target_language": self.target_language,
            "context_before": self.context_before,
            "context_after": self.context_after,
            "units": [
                {"unit_id": u.unit_id, "kind": u.kind, "text": u.text}
                for u in self.units
            ],
        }


@dataclass(frozen=True)
class AlignSelection:
    before: str
    text: str
    after: str


@dataclass(frozen=True)
class AlignInput:
    reading_text: str
    counterpart_text: str
    selection: AlignSelection

    def as_input_object(self) -> dict[str, Any]:
        return {
            "reading_text": self.reading_text,
            "counterpart_text": self.counterpart_text,
            "selection": {
                "before": self.selection.before,
                "text": self.selection.text,
                "after": self.selection.after,
            },
        }


@dataclass(frozen=True)
class Request:
    id: str
    op: str
    config: Config
    api_key: str
    prompt_version: str
    input: TranslateInput | AlignInput
    secret_headers: dict[str, str] = field(default_factory=dict)


def _exact_object(value: Any, keys: frozenset[str], what: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value.keys()) != set(keys):
        raise RequestError(f"{what} must be an object with exactly {sorted(keys)}")
    return value


TRANSLATE_INPUT_KEYS = frozenset(
    {"source_language", "target_language", "context_before", "context_after", "units"}
)
TRANSLATE_UNIT_KEYS = frozenset({"unit_id", "kind", "text"})
ALIGN_INPUT_KEYS = frozenset({"reading_text", "counterpart_text", "selection"})
ALIGN_SELECTION_KEYS = frozenset({"before", "text", "after"})
CONFIG_KEYS = frozenset({"provider", "model", "profile", "base_url", "effort"})
CREDENTIAL_KEYS = frozenset({"api_key"})


def _parse_base_url(raw: Any, *, operation_url: bool = False) -> str:
    """Validate a canonical HTTPS API Base URL.

    Agrees with the Swift editor's canonical rules on the wire-relevant
    parts: requires a host and HTTPS; rejects user information, query,
    fragment, literal whitespace/control characters, invalid ports, and
    full operation suffixes such as ``/chat/completions``. The Swift
    editor canonicalizes before saving; this is the wire-side check.
    """

    if not isinstance(raw, str) or not raw or request_utf8_len(raw, "base_url") > MAX_BASE_URL_BYTES:
        raise RequestError(
            f"base_url must be a nonempty string of at most {MAX_BASE_URL_BYTES} UTF-8 bytes"
        )
    if any(ch.isspace() or ord(ch) < 0x20 or ord(ch) == 0x7F for ch in raw):
        raise RequestError("base_url must not contain whitespace or control characters")
    # Malformed percent-encoding is rejected, never silently retyped
    # (agrees with the Swift editor's raw-string rule).
    if re.search(r"%(?![0-9A-Fa-f]{2})", raw):
        raise RequestError("base_url contains malformed percent-encoding")
    # A query/fragment delimiter is rejected even when its value is empty
    # (agrees with the Swift raw-character rule).
    if "?" in raw or "#" in raw:
        raise RequestError("base_url must not contain a query or fragment")
    try:
        parts = urlsplit(raw)
        # Accessing .port raises ValueError for a syntactically invalid or
        # out-of-range port; port 0 is rejected to match Swift's rule.
        port = parts.port
        if port is not None and not 0 < port <= 65535:
            raise ValueError("port out of range")
    except ValueError as exc:
        raise RequestError("base_url is not a valid URL") from exc
    if parts.scheme != "https" or not parts.hostname:
        raise RequestError("base_url must be an HTTPS URL with a host")
    if "%" in parts.hostname:
        # A percent-encoded host is rejected, never silently decoded.
        raise RequestError("base_url must not contain percent-encoding in the host")
    if parts.username is not None or parts.password is not None:
        raise RequestError("base_url must not contain user information")
    if parts.query or parts.fragment:
        raise RequestError("base_url must not contain a query or fragment")
    # Operation-suffix rejection accounts for permitted trailing-slash
    # normalization: /v1/chat/completions/ and /v1/messages/// are
    # operation paths (agrees with the Swift rule).
    path = parts.path.lower()
    while len(path) > 1 and path.endswith("/"):
        path = path[:-1]
    if not operation_url and any(path.endswith(suffix) for suffix in ("/chat/completions", "/responses", "/messages")):
        raise RequestError("base_url must not include a full operation path such as /chat/completions")
    return raw


def _parse_translate_input(raw: Any) -> TranslateInput:
    obj = _exact_object(raw, TRANSLATE_INPUT_KEYS, "translate input")
    source_language = obj["source_language"]
    target_language = obj["target_language"]
    if source_language not in LANGUAGES or target_language not in LANGUAGES:
        raise RequestError("languages must be en or zh")
    if source_language == target_language:
        raise RequestError("source_language and target_language must differ")
    context_before = obj["context_before"]
    context_after = obj["context_after"]
    for name, context in (("context_before", context_before), ("context_after", context_after)):
        if not isinstance(context, str) or request_utf8_len(context, name) > MAX_CONTEXT_BYTES:
            raise RequestError(f"{name} must be a string of at most {MAX_CONTEXT_BYTES} UTF-8 bytes")
    units_raw = obj["units"]
    if not isinstance(units_raw, list) or not 1 <= len(units_raw) <= MAX_UNITS_PER_BATCH:
        raise RequestError(f"units must be a list of 1 to {MAX_UNITS_PER_BATCH} objects")
    units: list[TranslateUnit] = []
    seen_ids: set[str] = set()
    total_text_bytes = 0
    for unit_raw in units_raw:
        unit = _exact_object(unit_raw, TRANSLATE_UNIT_KEYS, "unit")
        unit_id = unit["unit_id"]
        if not is_canonical_uuid(unit_id):
            raise RequestError("unit_id must be a canonical UUID string")
        if unit_id in seen_ids:
            raise RequestError("unit_id values must be unique within a request")
        seen_ids.add(unit_id)
        kind = unit["kind"]
        if kind not in UNIT_KINDS:
            raise RequestError("kind must be sentence or fragment")
        text = unit["text"]
        if not isinstance(text, str) or not text or text != text.strip():
            raise RequestError("unit text must be a nonempty string trimmed at its outer boundaries")
        if "\n" in text or "\r" in text:
            raise RequestError("unit text must not contain line breaks")
        total_text_bytes += request_utf8_len(text, "unit text")
        units.append(TranslateUnit(unit_id=unit_id, kind=kind, text=text))
    if total_text_bytes > MAX_BATCH_TEXT_BYTES:
        raise RequestError(f"batch unit text exceeds {MAX_BATCH_TEXT_BYTES} UTF-8 bytes")
    if input_json_size(raw) > MAX_INPUT_JSON_BYTES:
        raise RequestError(f"serialized input exceeds {MAX_INPUT_JSON_BYTES} bytes")
    return TranslateInput(
        source_language=source_language,
        target_language=target_language,
        context_before=context_before,
        context_after=context_after,
        units=tuple(units),
    )


def _parse_align_input(raw: Any) -> AlignInput:
    obj = _exact_object(raw, ALIGN_INPUT_KEYS, "align input")
    reading_text = obj["reading_text"]
    counterpart_text = obj["counterpart_text"]
    for name, value in (("reading_text", reading_text), ("counterpart_text", counterpart_text)):
        if not isinstance(value, str):
            raise RequestError(f"{name} must be a string")
    if (request_utf8_len(reading_text, "reading_text")
            + request_utf8_len(counterpart_text, "counterpart_text") > MAX_ALIGN_TEXT_BYTES):
        raise RequestError(
            f"reading_text plus counterpart_text exceeds {MAX_ALIGN_TEXT_BYTES} UTF-8 bytes"
        )
    selection_raw = obj["selection"]
    selection = _exact_object(selection_raw, ALIGN_SELECTION_KEYS, "selection")
    before = selection["before"]
    text = selection["text"]
    after = selection["after"]
    for name, value in (("before", before), ("text", text), ("after", after)):
        if not isinstance(value, str):
            raise RequestError(f"selection.{name} must be a string")
    if not text:
        raise RequestError("selection.text must be nonempty")
    if request_utf8_len(text, "selection.text") > MAX_ALIGN_SELECTION_BYTES:
        raise RequestError(f"selection.text exceeds {MAX_ALIGN_SELECTION_BYTES} UTF-8 bytes")
    if before + text + after != reading_text:
        raise RequestError("selection parts must concatenate exactly to reading_text")
    if input_json_size(raw) > MAX_INPUT_JSON_BYTES:
        raise RequestError(f"serialized input exceeds {MAX_INPUT_JSON_BYTES} bytes")
    return AlignInput(
        reading_text=reading_text,
        counterpart_text=counterpart_text,
        selection=AlignSelection(before=before, text=text, after=after),
    )


def parse_request(env: Any) -> Request:
    """Validate a request envelope that already carries a valid unique ID."""

    try:
        if not isinstance(env, dict):
            raise RequestError("request envelope must be an object")
        op = env.get("op")
        if op not in ("translate", "align"):
            raise RequestError("op must be translate or align")
        raw_config = env.get("config")
        is_open = isinstance(raw_config, dict) and raw_config.get("profile") in OPEN_PROFILES
        config_obj = _exact_object(raw_config, CONFIG_KEYS | {"options"} if is_open else CONFIG_KEYS, "config")
        provider = config_obj["provider"]
        if provider not in PROVIDERS:
            raise RequestError("provider is unsupported")
        model = config_obj["model"]
        if not isinstance(model, str) or not model or request_utf8_len(model, "model") > MAX_MODEL_ID_BYTES:
            raise RequestError(
                f"model must be a nonempty string of at most {MAX_MODEL_ID_BYTES} UTF-8 bytes"
            )
        profile = config_obj["profile"]
        if profile not in PROFILES_BY_PROVIDER[provider]:
            raise RequestError("profile must match the provider")
        base_url = _parse_base_url(config_obj["base_url"])
        effort = config_obj["effort"]
        if effort not in EFFORTS:
            raise RequestError("effort must be a canonical effort value")
        if profile in LEGACY_PROFILE_BASE_URL:
            # A legacy profile accepts only its original Standard API Base
            # URL and effective effort; custom connections use a v2 profile.
            if base_url != LEGACY_PROFILE_BASE_URL[profile] or effort != LEGACY_PROFILE_EFFORT[profile]:
                raise RequestError("legacy profile requires its original URL and effort")
        options = None
        if is_open:
            from .open_protocol import validate_options
            if effort not in ("off", "low", "medium", "high"):
                raise RequestError("open profiles require a four-level effort")
            options = validate_options(config_obj["options"], provider)
        credentials = _exact_object(env.get("credentials"), CREDENTIAL_KEYS | {"headers"} if is_open else CREDENTIAL_KEYS, "credentials")
        api_key = credentials["api_key"]
        if not isinstance(api_key, str) or (not api_key and not (options and options["authentication"] == "none")) or request_utf8_len(api_key, "api_key") > MAX_API_KEY_BYTES:
            raise RequestError(
                f"api_key must be a nonempty string of at most {MAX_API_KEY_BYTES} UTF-8 bytes"
            )
        secret_headers = {}
        if is_open:
            if options["authentication"] != "none" and any(not 32 <= ord(c) <= 126 for c in api_key):
                raise RequestError("invalid authentication header value")
            from .open_protocol import validate_headers
            secret_headers = validate_headers(credentials["headers"])
            if options["authentication"] == "custom" and options["headerName"].lower() in {key.lower() for key in secret_headers}:
                raise RequestError("duplicate authentication header")
        prompt_version = env.get("prompt_version")
        expected_versions = (
            TRANSLATE_PROMPT_VERSIONS if op == "translate" else (ALIGN_PROMPT_VERSION,)
        )
        if prompt_version not in expected_versions:
            raise RequestError(f"prompt_version must be one of {expected_versions}")
        input_parser = _parse_translate_input if op == "translate" else _parse_align_input
        parsed_input = input_parser(env.get("input"))
    except RequestError:
        raise
    except (TypeError, AttributeError) as exc:
        raise RequestError("malformed request field") from exc
    return Request(
        id=env["id"],
        op=op,
        config=Config(
            provider=provider,
            model=model,
            profile=profile,
            base_url=base_url,
            effort=effort,
            options=options,
        ),
        api_key=api_key,
        prompt_version=prompt_version,
        input=parsed_input,
        secret_headers=secret_headers,
    )


def check_envelope_header(env: Any) -> str:
    """Validate the shared envelope header and return the inbound kind."""

    if not isinstance(env, dict):
        raise FatalError("invalid_frame")
    if "v" not in env or not _is_int(env["v"]):
        raise FatalError("invalid_frame")
    if env["v"] != PROTOCOL_VERSION:
        raise FatalError("incompatible_protocol")
    kind = env.get("type")
    if not isinstance(kind, str) or kind not in INBOUND_KINDS:
        raise FatalError("invalid_frame")
    return kind


def check_cancel_frame(env: dict[str, Any]) -> str | None:
    """Return the cancel target ID, or None when it names no active request."""

    target = env.get("id")
    if not isinstance(target, str):
        raise FatalError("invalid_frame")
    return target
