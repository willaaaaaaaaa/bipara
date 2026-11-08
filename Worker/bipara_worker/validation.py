"""Strict validation of raw model output before it becomes a result frame.

The output schemas in ``prompts/`` describe shape only; this module adds
the semantic rules from the model workflow contract: exact ID coverage and
order, nonempty trimmed strings without line breaks, UTF-8 budgets, legal
status/match combinations, and literal quote resolution against the actual
counterpart text.
"""

from __future__ import annotations

from typing import Any, Sequence

from .errors import ValidationFailure, WorkerError
from .protocol import (
    MAX_DECODED_CONTENT_BYTES,
    MAX_MATCHES,
    MAX_TRANSLATION_BYTES,
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


def _checked_text(value: Any) -> str:
    if not isinstance(value, str) or not value or value != value.strip():
        _fail(ValidationFailure.INVALID_TRANSLATION_TEXT)
    if "\n" in value or "\r" in value:
        _fail(ValidationFailure.INVALID_TRANSLATION_TEXT)
    return value


def validate_translation_output(
    raw: Any, requested_unit_ids: Sequence[str]
) -> dict[str, Any]:
    """Validate raw translation output against the exact requested units."""

    if not isinstance(raw, dict) or set(raw.keys()) != {"translations"}:
        _fail(ValidationFailure.TRANSLATION_SHAPE)
    items = raw["translations"]
    if not isinstance(items, list) or len(items) != len(requested_unit_ids):
        _fail(ValidationFailure.UNIT_MISMATCH)
    canonical: list[dict[str, str]] = []
    for item, expected_id in zip(items, requested_unit_ids):
        if not isinstance(item, dict) or set(item.keys()) != {"unit_id", "text"}:
            _fail(ValidationFailure.TRANSLATION_SHAPE)
        if item["unit_id"] != expected_id:
            _fail(ValidationFailure.UNIT_MISMATCH)
        text = _checked_text(item["text"])
        if _output_utf8_len(text) > MAX_TRANSLATION_BYTES:
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
