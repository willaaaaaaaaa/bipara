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

    @pytest.mark.parametrize("items", [[], None, {}])
    def test_absent_rows_are_recoverable(self, items):
        with pytest.raises(WorkerError) as exc:
            validate_translation_output(translation(items), T01_IDS)
        assert exc.value.validation_reason == "unit_mismatch"

    @pytest.mark.parametrize("line_feeds", [None, [0, 1]])
    def test_reordered_results_follow_requested_ids(self, line_feeds):
        ids = ["22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333"]
        second_text = "b" if line_feeds is None else "b  \nnext"
        raw = translation([
            {"unit_id": ids[1], "text": second_text},
            {"unit_id": ids[0], "text": "a"},
        ])
        assert validate_translation_output(raw, ids, source_line_feeds=line_feeds) == translation([
            {"unit_id": ids[0], "text": "a"},
            {"unit_id": ids[1], "text": second_text},
        ])

    def test_partial_markdown_result_keeps_only_identifiable_valid_rows(self):
        ids = ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa0" + str(i) for i in range(5)]
        raw = translation([
            {"unit_id": ids[4], "text": "last"},
            {"unit_id": ids[0].upper(), "text": "first"},
            {"unit_id": ids[1], "text": "one"},
            {"unit_id": ids[1].upper(), "text": "two"},
            {"unit_id": ids[2], "text": "line\nbreak"},
            {"unit_id": "unknown", "text": "unrequested"},
        ])
        assert validate_translation_output(raw, ids, source_line_feeds=[0] * 5, allow_partial=True) == {
            "translations": [{"unit_id": ids[0], "text": "first"}, {"unit_id": ids[4], "text": "last"}],
            "incomplete_unit_ids": ids[1:4],
        }
        with pytest.raises(WorkerError) as exc:
            validate_translation_output(raw, ids, source_line_feeds=[0] * 5)
        assert exc.value.validation_reason == "unit_mismatch"

    def test_unpaired_surrogate_in_one_row_keeps_valid_markdown_sibling(self):
        rows = [{"unit_id": "one", "text": "bad \ud800"}, {"unit_id": "two", "text": "valid"}]
        assert validate_translation_output(translation(rows), ["one", "two"], source_line_feeds=[0, 0], allow_partial=True) == {
            "translations": [rows[1]], "incomplete_unit_ids": ["one"],
        }

    def test_conflicting_rows_remain_incomplete_even_when_one_has_invalid_text(self):
        rows = [{"unit_id": "one", "text": "valid"}, {"unit_id": "two", "text": "valid"}, {"unit_id": "one"}]
        assert validate_translation_output(translation(rows), ["one", "two"], source_line_feeds=[0, 0], allow_partial=True) == {
            "translations": [rows[1]], "incomplete_unit_ids": ["one"],
        }

    def test_reordered_results_do_not_borrow_another_units_line_budget(self):
        ids = ["one", "two"]
        raw = translation([{"unit_id": "two", "text": "b"}, {"unit_id": "one", "text": "a\nb"}])
        with pytest.raises(WorkerError) as exc:
            validate_translation_output(raw, ids, source_line_feeds=[0, 1])
        assert exc.value.validation_reason == "invalid_translation_text"

    def test_uuid_hex_case_keeps_identity_and_cannot_hide_duplicates(self):
        ids = ["abcdefab-1234-4123-8123-abcdefabcdef", "fedcbafe-1234-4123-8123-abcdefabcdef"]
        rows = [{"unit_id": ids[1].upper(), "text": "second"}, {"unit_id": ids[0], "text": "first"}]
        assert validate_translation_output(translation(rows), ids) == translation([
            {"unit_id": ids[0], "text": "first"}, {"unit_id": ids[1], "text": "second"},
        ])
        for bad_id in [ids[0].upper(), ids[1].replace("-", ""), " " + ids[1]]:
            with pytest.raises(WorkerError) as exc:
                validate_translation_output(translation([{**rows[0], "unit_id": bad_id}, rows[1]]), ids)
            assert exc.value.validation_reason == "unit_mismatch"

    @pytest.mark.parametrize("identity", [{"unit_id": T01_IDS[0]}, {"unit_id": "unknown"}, {"unit_id": []}, {}])
    def test_duplicate_unknown_or_missing_id_is_recoverable(self, identity):
        raw = translation([{"unit_id": T01_IDS[0], "text": "a"}, {**identity, "text": "b"}])
        with pytest.raises(WorkerError) as exc:
            validate_translation_output(raw, T01_IDS + ["33333333-3333-4333-8333-333333333333"])
        assert exc.value.validation_reason == "unit_mismatch"

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
