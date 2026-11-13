"""Offline fixture validity and protected-literal checks, not model-quality proof.

Semantic checks and truth tables in cases.json require human review of live
output. These tests exercise the structural validator and literal expectations
against admissible samples and deliberately damaged technical text.
"""
from __future__ import annotations

from copy import deepcopy
from uuid import NAMESPACE_URL, uuid5

import pytest

from bipara_worker.assets import load_cases
from bipara_worker.protocol import MARKDOWN_TRANSLATE_PROMPT_VERSION
from bipara_worker.validation import validate_alignment_output, validate_translation_output

CASES = load_cases()["cases"]


def literal_violations(case, output):
    texts = {item["unit_id"]: item["text"] for item in output["translations"]}
    failures = []
    for check in case.get("literal_checks", []):
        text = texts[check["unit_id"]]
        if ("equals" in check and text != check["equals"]
                or "prefix" in check and not text.startswith(check["prefix"])
                or "contains" in check and check["contains"] not in text
                or "count" in check and text.count(check["literal"]) != check["count"]):
            failures.append(check)
    return failures


@pytest.mark.parametrize("case", CASES, ids=lambda case: case["id"])
def test_corpus_samples_pass_real_output_validation(case):
    assert case["semantic_checks"]
    if case["op"] == "translate":
        output = deepcopy(case["sample_output"])
        ids = [str(uuid5(NAMESPACE_URL, f'bipara:{case["id"]}:{unit["unit_id"]}'))
               for unit in case["input"]["units"]]
        for item, identifier in zip(output["translations"], ids):
            item["unit_id"] = identifier
        source_line_feeds = (
            [unit["text"].count("\n") for unit in case["input"]["units"]]
            if case.get("prompt_version") == MARKDOWN_TRANSLATE_PROMPT_VERSION else None
        )
        assert validate_translation_output(output, ids, source_line_feeds=source_line_feeds) == output
        assert not literal_violations(case, case["sample_output"])
    else:
        assert validate_alignment_output(case["sample_output"], case["input"]["counterpart_text"]) == case["sample_output"]


@pytest.mark.parametrize("case_id,unit_id,bad_text", [
    ("T15-frontmatter", "t15a", "——"),
    ("T15-frontmatter", "t15c", "描述：阅读所选文档。"),
    ("T16-markdown-markers", "t16b", "**警告：**不要删除 `cache_id`。"),
    ("T17-link-and-literals-reverse", "t17", "Open the user guide and retain `cache_id`."),
    ("T18-code-fences", "t18a", "json"),
    ("T19-descriptive-config-value", "t19", '{"描述": "只读", "enabled": false}'),
    ("T20-markdown-table", "t20b", "| —— | —— |"),
])
def test_literal_expectations_detect_known_format_damage(case_id, unit_id, bad_text):
    case = next(case for case in CASES if case["id"] == case_id)
    output = deepcopy(case["sample_output"])
    next(item for item in output["translations"] if item["unit_id"] == unit_id)["text"] = bad_text
    assert literal_violations(case, output)
