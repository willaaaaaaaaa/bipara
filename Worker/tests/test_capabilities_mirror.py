"""Cross-language capability-table mirror test.

The Swift app and the Python worker each carry a local capability table
(``Sources/BiparaCore/ModelEffort.swift`` vs ``bipara_worker.models``) and a
canonical effort vocabulary. Nothing else keeps them in sync, so this test
parses the Swift source and asserts both tables agree exactly: same model
IDs, same effort sets in the same canonical order, equivalent modes, and
the same effort vocabulary. A one-sided edit on either side fails here.
"""

from __future__ import annotations

import re
from pathlib import Path

from bipara_worker.models import CAPABILITIES
from bipara_worker.protocol import EFFORTS

REPO_ROOT = Path(__file__).resolve().parents[2]
SWIFT_SOURCE = REPO_ROOT / "Sources" / "BiparaCore" / "ModelEffort.swift"


def _swift_source() -> str:
    assert SWIFT_SOURCE.is_file(), f"missing Swift capability source: {SWIFT_SOURCE}"
    return SWIFT_SOURCE.read_text(encoding="utf-8")


def _swift_enum_cases() -> list[str]:
    body = _swift_source()
    match = re.search(r"public enum ModelEffort: String.*?\{(.*?)\n\}", body, re.DOTALL)
    assert match, "ModelEffort enum not found"
    return re.findall(r"^\s+case (\w+)$", match.group(1), re.MULTILINE)


def _swift_string_set(constant: str) -> set[str]:
    body = _swift_source()
    match = re.search(rf"public static let {constant}: Set<String> = \[(.*?)\]", body, re.DOTALL)
    assert match, f"constant {constant} not found"
    return set(re.findall(r'"([^"]+)"', match.group(1)))


def _swift_entries() -> dict[tuple[str, str], tuple[str, ...]]:
    body = _swift_source()
    match = re.search(r"private static let entries: \[String: ModelCapability\] = \[(.*?)\n    \]", body, re.DOTALL)
    assert match, "entries table not found"
    table = match.group(1)
    entries: dict[tuple[str, str], tuple[str, ...]] = {}
    pattern = re.compile(
        r'(?:"(?P<model>[^"]+)"|(?P<constant>\w+)):\s*ModelCapability\(\s*'
        r'provider:\s*"(?P<provider>[^"]+)",\s*'
        r"efforts:\s*\[(?P<efforts>[^\]]*)\],",
        re.DOTALL,
    )
    constants = {
        "openaiNonreasoningModel": "gpt-4.1-mini-2025-04-14",
        "openAIReasoningModel": "gpt-6-luna",
        "glmBinaryThinkingModel": "glm-4.7-flash",
    }
    for found in pattern.finditer(table):
        model = found.group("model") or constants[found.group("constant")]
        efforts = tuple(
            case.lstrip(".") for case in re.split(r",\s*", found.group("efforts").strip()) if case
        )
        key = (found.group("provider"), model)
        assert key not in entries, f"duplicate Swift entry {key}"
        entries[key] = efforts
    assert entries, "no Swift capability entries parsed"
    return entries


def _swift_mode(provider: str, model: str, nonreasoning: bool) -> str:
    if nonreasoning:
        return "plain"
    if model in _swift_string_set("glmForcedThinkingModels"):
        return "forced"
    if model in _swift_string_set("glmBinaryModels"):
        return "binary"
    return "graded"


def _swift_nonreasoning_models() -> set[str]:
    body = _swift_source()
    nonreasoning: set[str] = set()
    pattern = re.compile(
        r'(?:"(?P<model>[^"]+)"|(?P<constant>\w+)):\s*ModelCapability\([^)]*nonreasoning:\s*true',
        re.DOTALL,
    )
    constants = {
        "openaiNonreasoningModel": "gpt-4.1-mini-2025-04-14",
        "openAIReasoningModel": "gpt-6-luna",
        "glmBinaryThinkingModel": "glm-4.7-flash",
    }
    for found in pattern.finditer(body):
        nonreasoning.add(found.group("model") or constants[found.group("constant")])
    return nonreasoning


class TestCapabilityMirror:
    def test_effort_vocabulary_matches(self):
        assert _swift_enum_cases() == list(EFFORTS)

    def test_model_entries_match_exactly(self):
        swift = _swift_entries()
        python = {key: value.efforts for key, value in CAPABILITIES.items()}
        assert swift == python

    def test_modes_match(self):
        nonreasoning = _swift_nonreasoning_models()
        for (provider, model), capability in CAPABILITIES.items():
            swift_efforts = _swift_entries()[(provider, model)]
            swift_mode = _swift_mode(provider, model, model in nonreasoning)
            assert swift_mode == capability.mode, (provider, model, swift_mode, capability.mode)

    def test_mode_sets_are_known_models(self):
        entries = _swift_entries()
        glm_models = {model for (provider, model) in entries if provider == "glm"}
        for constant in ("glmForcedThinkingModels", "glmBinaryModels"):
            assert _swift_string_set(constant) <= glm_models
