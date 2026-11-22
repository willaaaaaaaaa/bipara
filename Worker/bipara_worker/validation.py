"""Strict validation of raw model output before it becomes a result frame.

The output schemas in ``prompts/`` describe shape only; this module adds
the rules from the model workflow contract: exact ID coverage, request-order
results, nonempty trimmed strings with prompt-specific line rules, UTF-8 budgets, legal
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
    is_canonical_uuid,
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
    raw: Any, requested_unit_ids: Sequence[str], *, source_line_feeds: Sequence[int] | None = None,
    single_text: bool = False, allow_partial: bool = False,
) -> dict[str, Any]:
    """Validate output shape and budgets. Markdown supplies per-unit LF bounds."""

    if _decoded_size(raw) > MAX_DECODED_CONTENT_BYTES:
        _fail(ValidationFailure.OUTPUT_TOO_LARGE)
    if source_line_feeds is not None and len(source_line_feeds) != len(requested_unit_ids):
        _fail(ValidationFailure.UNIT_MISMATCH)
    allow_partial = allow_partial and source_line_feeds is not None and not single_text
    duplicate_ids = set()
    if single_text:
        if not isinstance(raw, dict) or set(raw) != {"text"} or len(requested_unit_ids) != 1:
            _fail(ValidationFailure.TRANSLATION_SHAPE)
        texts = {requested_unit_ids[0]: raw["text"]}
    else:
        if not isinstance(raw, dict) or set(raw) != {"translations"}:
            _fail(ValidationFailure.TRANSLATION_SHAPE)
        items = raw["translations"]
        if not isinstance(items, list) or (not allow_partial and len(items) != len(requested_unit_ids)):
            _fail(ValidationFailure.UNIT_MISMATCH)
        expected_ids = set(requested_unit_ids)
        texts = {}
        for item in items:
            valid_row = isinstance(item, dict) and item.keys() == {"unit_id", "text"}
            if not allow_partial and (not isinstance(item, dict) or "text" not in item or item.keys() - {"unit_id", "text"}):
                _fail(ValidationFailure.TRANSLATION_SHAPE)
            unit_id = item.get("unit_id") if isinstance(item, dict) else None
            if isinstance(unit_id, str) and unit_id not in expected_ids and len(unit_id) == 36 and unit_id.isascii():
                folded = unit_id.lower()
                if is_canonical_uuid(folded):
                    unit_id = folded
            if not isinstance(unit_id, str) or unit_id not in expected_ids:
                if allow_partial:
                    continue
                _fail(ValidationFailure.UNIT_MISMATCH)
            if unit_id in texts:
                if not allow_partial:
                    _fail(ValidationFailure.UNIT_MISMATCH)
                duplicate_ids.add(unit_id)
            else:
                texts[unit_id] = item["text"] if valid_row else None
    max_text_bytes = MAX_MARKDOWN_TRANSLATION_BYTES if source_line_feeds is not None else MAX_TRANSLATION_BYTES
    canonical: list[dict[str, str]] = []
    incomplete = []
    first_failure = None
    for index, expected_id in enumerate(requested_unit_ids):
        line_feeds = source_line_feeds[index] if source_line_feeds is not None else None
        try:
            if expected_id not in texts or expected_id in duplicate_ids:
                _fail(ValidationFailure.UNIT_MISMATCH)
            text = _checked_text(texts[expected_id], line_feeds)
            if _output_utf8_len(text) > max_text_bytes:
                _fail(ValidationFailure.OUTPUT_TOO_LARGE)
        except WorkerError as exc:
            if not allow_partial:
                raise
            if first_failure is None:
                first_failure = exc
            incomplete.append(expected_id)
            continue
        canonical.append({"unit_id": expected_id, "text": text})
    if not canonical and first_failure is not None:
        raise first_failure
    if incomplete:
        return {"translations": canonical, "incomplete_unit_ids": incomplete}
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

    serialized = json.dumps(raw, ensure_ascii=False, separators=(",", ":"))
    # Count unpaired surrogates by their JSON escape until individual rows are checked.
    return len(serialized.encode("utf-8", errors="backslashreplace"))
