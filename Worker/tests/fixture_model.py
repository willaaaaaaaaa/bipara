"""Test-only fixture model factory.

Answers requests deterministically from the canonical synthetic corpus in
prompts/cases.json and never touches a network. This module is used by the
test entry point (fixture_worker.py) and packaged fixture builds only; it
is not reachable from the release worker bundle.
"""

from __future__ import annotations

import asyncio
from typing import Any

from bipara_worker.errors import WorkerError
from bipara_worker.protocol import AlignInput, Request, TranslateInput
from bipara_worker.validation import validate_alignment_output, validate_translation_output


def build_case_indexes(cases: dict[str, Any]) -> tuple[dict[tuple[Any, ...], str], dict[tuple[Any, ...], dict[str, Any]]]:
    translations: dict[tuple[Any, ...], str] = {}
    alignments: dict[tuple[Any, ...], dict[str, Any]] = {}
    for case in cases["cases"]:
        if case["op"] == "translate":
            source = case["input"]["source_language"]
            target = case["input"]["target_language"]
            outputs = case["sample_output"]["translations"]
            for unit, output in zip(case["input"]["units"], outputs):
                translations[(source, target, unit["text"])] = output["text"]
        else:
            inp = case["input"]
            alignments[(inp["reading_text"], inp["counterpart_text"], inp["selection"]["text"])] = (
                case["sample_output"]
            )
    return translations, alignments


def make_fixture_operation(
    cases: dict[str, Any],
    *,
    delay_seconds: float = 0.0,
    delay_translate: float | None = None,
    delay_align: float | None = None,
    fail_code: str | None = None,
):
    """Deterministic offline operation with optional delay/failure injection.

    Per-operation delays let tests construct deterministic completion
    ordering (e.g. a slower translate finishing after a fast align).
    """

    translations, alignments = build_case_indexes(cases)

    async def operation(request: Request) -> tuple[dict[str, Any], dict[str, Any]]:
        if fail_code is not None:
            raise WorkerError(fail_code)
        delay = delay_seconds
        if isinstance(request.input, TranslateInput) and delay_translate is not None:
            delay = delay_translate
        elif isinstance(request.input, AlignInput) and delay_align is not None:
            delay = delay_align
        if delay > 0:
            await asyncio.sleep(delay)
        if isinstance(request.input, TranslateInput):
            texts = []
            for unit in request.input.units:
                sample = translations.get(
                    (request.input.source_language, request.input.target_language, unit.text)
                )
                if sample is None:
                    # Deterministic, obviously synthetic fallback for
                    # transport-only inputs that are not part of the corpus.
                    sample = f"[bipara-fixture:{len(unit.text.encode('utf-8'))}] {unit.text}"
                texts.append(sample)
            raw = {
                "translations": [
                    {"unit_id": unit.unit_id, "text": text}
                    for unit, text in zip(request.input.units, texts)
                ]
            }
            data = validate_translation_output(
                raw, [unit.unit_id for unit in request.input.units]
            )
        elif isinstance(request.input, AlignInput):
            raw = alignments.get(
                (
                    request.input.reading_text,
                    request.input.counterpart_text,
                    request.input.selection.text,
                )
            )
            if raw is None:
                raw = {"status": "no_match", "matches": [], "reason": "ambiguous"}
            data = validate_alignment_output(raw, request.input.counterpart_text)
        else:  # pragma: no cover - parse_request only yields the two input types
            raise WorkerError("invalid_request")
        meta = {
            "provider": request.config.provider,
            "requested_model": request.config.model,
            "requested_effort": request.config.effort,
            "returned_model": None,
            "prompt_version": request.prompt_version,
            "input_tokens": None,
            "output_tokens": None,
        }
        return data, meta

    async def aclose() -> None:
        return None

    return operation, aclose
