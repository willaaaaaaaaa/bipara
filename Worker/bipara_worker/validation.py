"""Strict validation of raw model output before it becomes a result frame.

The output schemas in ``prompts/`` describe shape only; this module adds
the rules from the model workflow contract: exact ID coverage and
order, nonempty trimmed strings with prompt-specific line rules, UTF-8 budgets, legal
status/match combinations, and literal quote resolution against the actual
counterpart text.
"""

from __future__ import annotations

from typing import Any, Sequence

from .errors import ValidationFailure, WorkerError
from .protocol import (
    MAX_DECODED_CONTENT_BYTES,
    MAX_MARKDOWN_TRANSLATION_BYTES,
    MAX_MATCHES,
    MAX_TRANSLATION_BYTES,
    has_markdown_line_shape,
)


def _output_utf8_len(value: str) -> int:
    """UTF-8 size for model-output validation; unpaired surrogates make
    the output invalid rather than crashing the request task."""

    try:
        return len(value.encode("utf-8"))
    except UnicodeEncodeError as exc:
        raise WorkerError("invalid_output", validation_reason=ValidationFailure.INVALID_TRANSLATION_TEXT) from exc

ALIGNMENT_REASONS = ("none", "not_expressed", "ambiguous", "selection_too_broad")
NO_MATCH_REASONS = ("not_expressed", "ambiguous", "selection_too_broad")


def _fail(reason: ValidationFailure) -> None:
    raise WorkerError("invalid_output", validation_reason=reason) from None


def _checked_text(value: Any, source_line_feeds: int | None) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        _fail(ValidationFailure.INVALID_TRANSLATION_TEXT)
    if source_line_feeds is None:
        if "\n" in value or "\r" in value:
            _fail(ValidationFailure.INVALID_TRANSLATION_TEXT)
    elif not has_markdown_line_shape(value) or value.count("\n") > source_line_feeds:
        _fail(ValidationFailure.INVALID_TRANSLATION_TEXT)
    return value


def validate_translation_output(
    raw: Any, requested_unit_ids: Sequence[str], *, source_line_feeds: Sequence[int] | None = None
) -> dict[str, Any]:
    """Validate output shape and budgets. Markdown supplies per-unit LF bounds."""

    if not isinstance(raw, dict) or set(raw.keys()) != {"translations"}:
        _fail(ValidationFailure.TRANSLATION_SHAPE)
    items = raw["translations"]
    if not isinstance(items, list) or len(items) != len(requested_unit_ids):
        _fail(ValidationFailure.UNIT_MISMATCH)
    if source_line_feeds is not None and len(source_line_feeds) != len(requested_unit_ids):
        _fail(ValidationFailure.UNIT_MISMATCH)
    max_text_bytes = MAX_MARKDOWN_TRANSLATION_BYTES if source_line_feeds is not None else MAX_TRANSLATION_BYTES
    canonical: list[dict[str, str]] = []
    for index, (item, expected_id) in enumerate(zip(items, requested_unit_ids)):
        if not isinstance(item, dict) or set(item.keys()) != {"unit_id", "text"}:
            _fail(ValidationFailure.TRANSLATION_SHAPE)
        if item["unit_id"] != expected_id:
            _fail(ValidationFailure.UNIT_MISMATCH)
        line_feeds = source_line_feeds[index] if source_line_feeds is not None else None
        text = _checked_text(item["text"], line_feeds)
        if _output_utf8_len(text) > max_text_bytes:
            _fail(ValidationFailure.OUTPUT_TOO_LARGE)
        canonical.append({"unit_id": expected_id, "text": text})
    if _decoded_size(raw) > MAX_DECODED_CONTENT_BYTES:
        _fail(ValidationFailure.OUTPUT_TOO_LARGE)
    return {"translations": canonical}


def validate_alignment_output(raw: Any, counterpart_text: str) -> dict[str, Any]:
    """Validate raw alignment output and resolve quotes literally."""

    if not isinstance(raw, dict) or set(raw.keys()) != {"status", "matches", "reason"}:
        _fail(ValidationFailure.ALIGNMENT_SHAPE)
    status = raw["status"]
    reason = raw["reason"]
    matches = raw["matches"]
    if status not in ("matched", "no_match"):
        _fail(ValidationFailure.ALIGNMENT_SHAPE)
    if not isinstance(reason, str) or reason not in ALIGNMENT_REASONS:
        _fail(ValidationFailure.ALIGNMENT_SHAPE)
    if not isinstance(matches, list):
        _fail(ValidationFailure.ALIGNMENT_SHAPE)
    if status == "no_match":
        if matches:
            _fail(ValidationFailure.ALIGNMENT_SHAPE)
        if reason == "none":
            _fail(ValidationFailure.ALIGNMENT_SHAPE)
        return {"status": "no_match", "matches": [], "reason": reason}
    if reason != "none":
        _fail(ValidationFailure.ALIGNMENT_SHAPE)
    if not 1 <= len(matches) <= MAX_MATCHES:
        _fail(ValidationFailure.ALIGNMENT_SHAPE)
    cursor = 0
    for item in matches:
        if not isinstance(item, dict) or set(item.keys()) != {"quote", "occurrence"}:
            _fail(ValidationFailure.ALIGNMENT_SHAPE)
        quote = item["quote"]
        occurrence = item["occurrence"]
        if not isinstance(quote, str) or not quote:
            _fail(ValidationFailure.ALIGNMENT_SHAPE)
        if not isinstance(occurrence, int) or isinstance(occurrence, bool) or occurrence < 1:
            _fail(ValidationFailure.ALIGNMENT_SHAPE)
        start = _nth_nonoverlapping(counterpart_text, quote, occurrence)
        if start is None or start < cursor:
            _fail(ValidationFailure.ALIGNMENT_SHAPE)
        cursor = start + len(quote)
    return {
        "status": "matched",
        "matches": [
            {"quote": item["quote"], "occurrence": item["occurrence"]} for item in matches
        ],
        "reason": "none",
    }


def _nth_nonoverlapping(text: str, quote: str, occurrence: int) -> int | None:
    """Index of the occurrence-th nonoverlapping literal run, or None."""

    count = 0
    start = 0
    while True:
        index = text.find(quote, start)
        if index < 0:
            return None
        count += 1
        if count == occurrence:
            return index
        start = index + len(quote)


def _decoded_size(raw: Any) -> int:
    import json

    return _output_utf8_len(json.dumps(raw, ensure_ascii=False, separators=(",", ":")))
