"""Unit tests for strict model-output validation."""

from __future__ import annotations

import pytest

from bipara_worker.errors import WorkerError
from bipara_worker.validation import validate_alignment_output, validate_translation_output

T01_IDS = ["22222222-2222-4222-8222-222222222222"]
COUNTERPART = "I can can fruit."


def translation(items):
    return {"translations": items}


class TestTranslationOutput:
    def test_valid_sample(self):
        raw = translation([{"unit_id": T01_IDS[0], "text": "Li Ming has not confirmed Friday's meeting."}])
        data = validate_translation_output(raw, T01_IDS)
        assert data == raw

    def test_missing_translations_key_rejected(self):
        with pytest.raises(WorkerError) as exc:
            validate_translation_output({"units": []}, T01_IDS)
        assert exc.value.code == "invalid_output"

    def test_extra_top_level_field_rejected(self):
        raw = translation([{"unit_id": T01_IDS[0], "text": "x"}])
        raw["note"] = "extra"
        with pytest.raises(WorkerError):
            validate_translation_output(raw, T01_IDS)

    def test_count_mismatch_rejected(self):
        with pytest.raises(WorkerError):
            validate_translation_output(translation([]), T01_IDS)

    def test_reordered_ids_rejected(self):
        ids = ["22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333"]
        raw = translation([
            {"unit_id": ids[1], "text": "b"},
            {"unit_id": ids[0], "text": "a"},
        ])
        with pytest.raises(WorkerError):
            validate_translation_output(raw, ids)

    def test_duplicate_ids_rejected(self):
        raw = translation([
            {"unit_id": T01_IDS[0], "text": "a"},
            {"unit_id": T01_IDS[0], "text": "b"},
        ])
        with pytest.raises(WorkerError):
            validate_translation_output(raw, T01_IDS + ["33333333-3333-4333-8333-333333333333"])

    def test_blank_or_whitespace_text_rejected(self):
        for bad in ("", "  ", " padded"):
            with pytest.raises(WorkerError):
                validate_translation_output(translation([{"unit_id": T01_IDS[0], "text": bad}]), T01_IDS)

    def test_line_break_in_text_rejected(self):
        with pytest.raises(WorkerError):
            validate_translation_output(
                translation([{"unit_id": T01_IDS[0], "text": "line\nbreak"}]), T01_IDS
            )

    def test_extra_item_field_rejected(self):
        raw = translation([{"unit_id": T01_IDS[0], "text": "x", "score": 1}])
        with pytest.raises(WorkerError):
            validate_translation_output(raw, T01_IDS)

    def test_oversize_text_rejected(self):
        raw = translation([{"unit_id": T01_IDS[0], "text": "长" * 5000}])
        with pytest.raises(WorkerError):
            validate_translation_output(raw, T01_IDS)

    @pytest.mark.parametrize("text", ["甲\r乙", "甲\n\n乙", "甲\n \n乙", "甲\n乙\n丙", "a" * 32769])
    def test_invalid_markdown_reply_rejected(self, text):
        raw = translation([{"unit_id": T01_IDS[0], "text": text}])
        with pytest.raises(WorkerError):
            validate_translation_output(raw, T01_IDS, source_line_feeds=[1])

    def test_markdown_allows_existing_lf_and_larger_unit_only_in_markdown(self):
        raw = translation([{"unit_id": T01_IDS[0], "text": "a" * 12000 + "  \nnext"}])
        assert validate_translation_output(raw, T01_IDS, source_line_feeds=[1]) == raw
        with pytest.raises(WorkerError):
            validate_translation_output(raw, T01_IDS)
        with pytest.raises(WorkerError):
            validate_translation_output(raw, T01_IDS, source_line_feeds=[0])

    def test_oversize_total_content_rejected(self):
        # 20 units x 2500 chars x 3 bytes = 150 KiB, each string under 8 KiB.
        ids = [f"22222222-2222-4222-8222-{i:012d}" for i in range(20)]
        raw = translation([{"unit_id": i, "text": "字" * 2500} for i in ids])
        with pytest.raises(WorkerError):
            validate_translation_output(raw, ids)


class TestAlignmentOutput:
    def test_valid_matched(self):
        raw = {"status": "matched", "matches": [{"quote": "can", "occurrence": 2}], "reason": "none"}
        data = validate_alignment_output(raw, COUNTERPART)
        assert data == raw

    def test_valid_no_match(self):
        for reason in ("not_expressed", "ambiguous", "selection_too_broad"):
            raw = {"status": "no_match", "matches": [], "reason": reason}
            assert validate_alignment_output(raw, COUNTERPART) == raw

    def test_unknown_status_rejected(self):
        with pytest.raises(WorkerError):
            validate_alignment_output({"status": "partial", "matches": [], "reason": "none"}, COUNTERPART)

    def test_matched_with_bad_reason_rejected(self):
        raw = {"status": "matched", "matches": [{"quote": "can", "occurrence": 1}], "reason": "ambiguous"}
        with pytest.raises(WorkerError):
            validate_alignment_output(raw, COUNTERPART)

    def test_no_match_with_matches_rejected(self):
        raw = {"status": "no_match", "matches": [{"quote": "can", "occurrence": 1}], "reason": "ambiguous"}
        with pytest.raises(WorkerError):
            validate_alignment_output(raw, COUNTERPART)

    def test_no_match_with_reason_none_rejected(self):
        with pytest.raises(WorkerError):
            validate_alignment_output({"status": "no_match", "matches": [], "reason": "none"}, COUNTERPART)

    def test_quote_absent_from_counterpart_rejected(self):
        raw = {"status": "matched", "matches": [{"quote": "missing", "occurrence": 1}], "reason": "none"}
        with pytest.raises(WorkerError):
            validate_alignment_output(raw, COUNTERPART)

    def test_occurrence_out_of_range_rejected(self):
        raw = {"status": "matched", "matches": [{"quote": "can", "occurrence": 3}], "reason": "none"}
        with pytest.raises(WorkerError):
            validate_alignment_output(raw, COUNTERPART)

    def test_occurrence_zero_and_bool_rejected(self):
        for bad in (0, -1, True):
            raw = {"status": "matched", "matches": [{"quote": "can", "occurrence": bad}], "reason": "none"}
            with pytest.raises(WorkerError):
                validate_alignment_output(raw, COUNTERPART)

    def test_overlapping_or_unordered_matches_rejected(self):
        raw = {
            "status": "matched",
            "matches": [
                {"quote": "fruit", "occurrence": 1},
                {"quote": "can", "occurrence": 2},
            ],
            "reason": "none",
        }
        with pytest.raises(WorkerError):
            validate_alignment_output(raw, COUNTERPART)

    def test_nonoverlapping_occurrence_semantics(self):
        # Greedy nonoverlapping counting: "aa" occurs once in "aaa" at index 0.
        raw = {"status": "matched", "matches": [{"quote": "aa", "occurrence": 1}], "reason": "none"}
        assert validate_alignment_output(raw, "aaa") == raw
        raw2 = {"status": "matched", "matches": [{"quote": "aa", "occurrence": 2}], "reason": "none"}
        with pytest.raises(WorkerError):
            validate_alignment_output(raw2, "aaa")

    def test_nine_matches_rejected_but_eight_accepted(self):
        counterpart = "a a a a a a a a a b"
        eight = [{"quote": "a", "occurrence": i} for i in range(1, 9)]
        raw8 = {"status": "matched", "matches": eight, "reason": "none"}
        assert validate_alignment_output(raw8, counterpart) == raw8
        raw9 = {
            "status": "matched",
            "matches": [{"quote": "a", "occurrence": i} for i in range(1, 10)],
            "reason": "none",
        }
        with pytest.raises(WorkerError):
            validate_alignment_output(raw9, counterpart)

    def test_extra_match_field_rejected(self):
        raw = {"status": "matched", "matches": [{"quote": "can", "occurrence": 1, "why": "x"}], "reason": "none"}
        with pytest.raises(WorkerError):
            validate_alignment_output(raw, COUNTERPART)

    def test_occurrence_continuation_across_combining_marks(self):
        # Mirrors the Swift-side S8 case: Python counts code-point
        # occurrences and resolves the second standalone "e" at index 2.
        raw = {"status": "matched", "matches": [{"quote": "e", "occurrence": 2}], "reason": "none"}
        data = validate_alignment_output(raw, "e\u0301e")
        assert data == raw

    def test_surrogate_in_translation_output_is_invalid_output(self):
        raw = translation([{"unit_id": T01_IDS[0], "text": "\ud800窗"}])
        with pytest.raises(WorkerError) as exc:
            validate_translation_output(raw, T01_IDS)
        assert exc.value.code == "invalid_output"

    def test_discontinuous_ordered_spans_accepted(self):
        raw = {
            "status": "matched",
            "matches": [{"quote": "gave", "occurrence": 1}, {"quote": "back", "occurrence": 1}],
            "reason": "none",
        }
        assert validate_alignment_output(raw, "I gave the book back.") == raw
