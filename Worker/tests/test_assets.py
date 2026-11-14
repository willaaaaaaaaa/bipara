"""Asset loading and hash verification against the canonical repository files."""

from __future__ import annotations

import hashlib
from pathlib import Path

from bipara_worker.assets import (
    ASSET_FILES,
    AssetError,
    asset_dir,
    load_assets,
    load_cases,
)

from conftest import ROOT


def test_asset_dir_points_at_canonical_prompts_in_dev():
    assert asset_dir() == ROOT / "prompts"


def test_all_canonical_assets_load_and_hash():
    assets = load_assets()
    assert set(assets.versions) == {"translation.v1", "translation.v2", "translation.markdown.v1", "alignment.v1"}
    for filename in ASSET_FILES:
        canonical = hashlib.sha256((ROOT / "prompts" / filename).read_bytes()).hexdigest()
        assert assets.hashes[filename] == canonical
    assert assets.prompts["translation.v1"].startswith("You are the translation component")
    assert assets.prompts["alignment.v1"].startswith("You are the text-correspondence component")
    assert assets.schemas["translation.v1"]["title"] == "BiparaTranslationV1"
    assert assets.schemas["alignment.v1"]["title"] == "BiparaAlignmentV1"


def test_prompt_assets_are_not_empty_or_templates():
    assets = load_assets()
    for version, text in assets.prompts.items():
        assert len(text) > 200, version
        assert "{" not in text or "JSON object" in text  # literal prose, not a format template


def test_cases_corpus_includes_both_markdown_directions():
    cases = load_cases()
    ops = [case["op"] for case in cases["cases"]]
    assert cases["corpus_version"] == "3"
    assert ops.count("translate") == 22
    assert ops.count("align") == 6
    markdown = [case for case in cases["cases"] if case.get("prompt_version") == "translation.markdown.v1"]
    assert {(case["input"]["source_language"], case["input"]["target_language"]) for case in markdown} == {
        ("en", "zh"), ("zh", "en")
    }


def test_missing_asset_directory_is_asset_error(tmp_path, monkeypatch):
    from bipara_worker import assets as assets_module

    monkeypatch.setattr(assets_module, "asset_dir", lambda: Path(tmp_path) / "absent")
    try:
        load_assets()
    except AssetError:
        pass
    else:
        raise AssertionError("expected AssetError for missing directory")
