"""Wire-level v2 adapter tests against an offline httpx MockTransport.

These capture the final outgoing HTTP request — URL, body, headers — for
each profile/capability combination and assert the guard's zero-HTTP
behavior on silent mutation. No real network access happens.
"""

from __future__ import annotations

import json

import httpx
import pytest

import bipara_worker.models as models
from bipara_worker.assets import load_assets
from bipara_worker.errors import WorkerError
from bipara_worker.models import make_langchain_operation
from bipara_worker.protocol import parse_request

from conftest import (
    GLM_CODING,
    GLM_STANDARD,
    OPENAI_STANDARD,
    SYNTHETIC_KEY,
    T01_UNIT_ID,
    translate_request_t01,
)


def v2_request(provider: str, model: str, profile: str, effort: str, base_url: str, op: str = "translate"):
    env = translate_request_t01()
    env["op"] = op
    env["prompt_version"] = "translation.v1" if op == "translate" else "alignment.v1"
    if op == "align":
        env["input"] = {
            "reading_text": "I can can fruit.",
            "counterpart_text": "我会把水果装罐。",
            "selection": {"before": "I can ", "text": "can", "after": " fruit."},
        }
    env["config"] = {
        "provider": provider,
        "model": model,
        "profile": profile,
        "base_url": base_url,
        "effort": effort,
    }
    return parse_request(env)


class Captured:
    def __init__(self) -> None:
        self.calls: list[tuple[str, str, dict]] = []
        self.reply = json.dumps(
            {"translations": [{"unit_id": T01_UNIT_ID, "text": "Li Ming has not confirmed Friday's meeting."}]},
            ensure_ascii=False,
        )

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.calls.append((str(request.url), request.headers.get("authorization", ""), json.loads(request.content)))
        return httpx.Response(
            200,
            json={
                "id": "synthetic",
                "object": "chat.completion",
                "created": 0,
                "model": "synthetic-model",
                "choices": [
                    {"index": 0, "message": {"role": "assistant", "content": self.reply}, "finish_reason": "stop"}
                ],
                "usage": {"prompt_tokens": 5, "completion_tokens": 7},
            },
        )

    @property
    def url(self) -> str:
        return self.calls[0][0]

    @property
    def body(self) -> dict:
        return self.calls[0][2]


@pytest.fixture
def captured() -> Captured:
    return Captured()


async def run_operation(captured: Captured, request):
    client = httpx.AsyncClient(transport=httpx.MockTransport(captured.handler), trust_env=False)
    try:
        operation, _aclose = make_langchain_operation(load_assets(), http_async_client=client)
        return await operation(request)
    finally:
        await client.aclose()


def system_prompt():
    return load_assets().prompts["translation.v1"]


def payload_text():
    return json.dumps(translate_request_t01()["input"], ensure_ascii=False, separators=(",", ":"))


@pytest.mark.asyncio
async def test_openai_v2_reasoning_low(captured):
    request = v2_request("openai", "gpt-6-luna", "openai-json-schema-v2", "low", OPENAI_STANDARD)
    await run_operation(captured, request)
    assert len(captured.calls) == 1
    assert captured.url == "https://api.openai.com/v1/chat/completions"
    body = captured.body
    assert body["model"] == "gpt-6-luna"
    assert body["reasoning_effort"] == "low"
    assert body["max_completion_tokens"] == 16384
    assert "max_tokens" not in body
    assert "temperature" not in body  # v2 reasoning entries omit sampling, including Auto
    assert body["response_format"]["type"] == "json_schema"
    assert body["response_format"]["json_schema"]["strict"] is True
    assert "tools" not in body and "tool_choice" not in body
    assert body.get("stream") in (None, False)
    assert [(m["role"], m["content"]) for m in body["messages"]] == [
        ("system", system_prompt()),
        ("user", payload_text()),
    ]
    assert captured.calls[0][1] == f"Bearer {SYNTHETIC_KEY}"


@pytest.mark.asyncio
async def test_openai_v2_reasoning_off_maps_to_none(captured):
    request = v2_request("openai", "gpt-6-luna", "openai-json-schema-v2", "off", OPENAI_STANDARD)
    await run_operation(captured, request)
    body = captured.body
    assert body["reasoning_effort"] == "none"
    assert body["max_completion_tokens"] == 8192  # explicit Off keeps the plain cap
    assert "temperature" not in body


@pytest.mark.asyncio
async def test_openai_v2_nonreasoning_keeps_temperature(captured):
    request = v2_request("openai", "gpt-4.1-mini-2025-04-14", "openai-json-schema-v2", "auto", OPENAI_STANDARD)
    await run_operation(captured, request)
    body = captured.body
    assert body["temperature"] == 0.2
    assert "reasoning_effort" not in body
    assert body["max_completion_tokens"] == 8192


@pytest.mark.asyncio
@pytest.mark.parametrize("effort", ["medium", "high", "xhigh", "max"])
async def test_openai_v2_reasoning_effort_matrix(captured, effort: str):
    request = v2_request("openai", "gpt-6-luna", "openai-json-schema-v2", effort, OPENAI_STANDARD)
    await run_operation(captured, request)
    body = captured.body
    assert body["reasoning_effort"] == effort
    assert body["max_completion_tokens"] == 16384


@pytest.mark.asyncio
async def test_openai_v1_legacy_sampling(captured):
    request = v2_request("openai", "gpt-4.1-mini-2025-04-14", "openai-json-schema-v1", "auto", OPENAI_STANDARD)
    await run_operation(captured, request)
    body = captured.body
    assert body["temperature"] == 0.2
    assert body["max_completion_tokens"] == 4096
    assert "reasoning_effort" not in body


@pytest.mark.asyncio
async def test_openai_v2_unknown_model_auto(captured):
    request = v2_request("openai", "custom-internal-model", "openai-json-schema-v2", "auto", "https://gateway.example.com/openai/v1/")
    await run_operation(captured, request)
    assert captured.url == "https://gateway.example.com/openai/v1/chat/completions"
    body = captured.body
    assert "temperature" not in body
    assert "reasoning_effort" not in body
    assert body["max_completion_tokens"] == 16384


@pytest.mark.asyncio
async def test_v2_percent_encoded_path_segments_preserved(captured):
    request = v2_request("openai", "gpt-6-luna", "openai-json-schema-v2", "low", "https://gateway.example.com/team%2Fname/v1/")
    await run_operation(captured, request)
    assert len(captured.calls) == 1
    assert captured.url == "https://gateway.example.com/team%2Fname/v1/chat/completions"


@pytest.mark.asyncio
async def test_glm_v2_binary_thinking(captured):
    request = v2_request("glm", "glm-4.7-flash", "glm-json-v2", "off", GLM_STANDARD)
    await run_operation(captured, request)
    assert captured.url == "https://open.bigmodel.cn/api/paas/v4/chat/completions"
    body = captured.body
    assert body["temperature"] == 0.2
    assert body["max_tokens"] == 8192
    assert "max_completion_tokens" not in body
    assert body["thinking"] == {"type": "disabled"}
    assert "reasoning_effort" not in body
    assert body["response_format"] == {"type": "json_object"}


@pytest.mark.asyncio
async def test_glm_v2_binary_thinking_on_uses_reasoning_caps(captured):
    request = v2_request("glm", "glm-4.7-flash", "glm-json-v2", "on", GLM_STANDARD)
    await run_operation(captured, request)
    body = captured.body
    assert body["thinking"] == {"type": "enabled"}
    assert body["max_tokens"] == 16384
    assert "reasoning_effort" not in body


@pytest.mark.asyncio
async def test_glm_v2_graded_effort(captured):
    request = v2_request("glm", "glm-5.3-flash", "glm-json-v2", "low", GLM_STANDARD)
    await run_operation(captured, request)
    body = captured.body
    assert body["thinking"] == {"type": "enabled"}
    assert body["reasoning_effort"] == "low"
    assert body["max_tokens"] == 16384
    assert "temperature" not in body  # GLM-5.3 entries omit sampling parameters


@pytest.mark.asyncio
async def test_glm_v2_graded_auto_omits_effort(captured):
    request = v2_request("glm", "glm-5.3", "glm-json-v2", "auto", GLM_STANDARD)
    await run_operation(captured, request)
    body = captured.body
    assert body["thinking"] == {"type": "enabled"}
    assert "reasoning_effort" not in body
    assert "temperature" not in body


@pytest.mark.asyncio
@pytest.mark.parametrize("effort", ["high", "max"])
async def test_glm_v2_graded_effort_matrix(captured, effort: str):
    request = v2_request("glm", "glm-5.3-flash", "glm-json-v2", effort, GLM_STANDARD)
    await run_operation(captured, request)
    body = captured.body
    assert body["thinking"] == {"type": "enabled"}
    assert body["reasoning_effort"] == effort
    assert body["max_tokens"] == 16384
    assert "temperature" not in body


@pytest.mark.asyncio
async def test_openai_v2_known_graded_auto(captured):
    request = v2_request("openai", "gpt-6-luna", "openai-json-schema-v2", "auto", OPENAI_STANDARD)
    await run_operation(captured, request)
    body = captured.body
    assert "reasoning_effort" not in body
    assert "temperature" not in body
    assert body["max_completion_tokens"] == 16384


@pytest.mark.asyncio
async def test_glm_v2_binary_auto_keeps_temperature_without_thinking(captured):
    request = v2_request("glm", "glm-4.7-flash", "glm-json-v2", "auto", GLM_STANDARD)
    await run_operation(captured, request)
    body = captured.body
    assert body["temperature"] == 0.2
    assert "thinking" not in body
    assert "reasoning_effort" not in body
    assert body["max_tokens"] == 16384


@pytest.mark.asyncio
async def test_glm_52_off_disables_thinking(captured):
    request = v2_request("glm", "glm-5.2", "glm-json-v2", "off", GLM_STANDARD)
    await run_operation(captured, request)
    body = captured.body
    assert body["thinking"] == {"type": "disabled"}
    assert "reasoning_effort" not in body
    assert body["max_tokens"] == 8192
    assert "temperature" not in body


@pytest.mark.asyncio
async def test_glm_52_minimal_sends_verbatim(captured):
    request = v2_request("glm", "glm-5.2", "glm-json-v2", "minimal", GLM_STANDARD)
    await run_operation(captured, request)
    body = captured.body
    assert body["thinking"] == {"type": "enabled"}
    assert body["reasoning_effort"] == "minimal"
    assert body["max_tokens"] == 16384


@pytest.mark.asyncio
async def test_glm_52_auto_omits_thinking_controls(captured):
    request = v2_request("glm", "glm-5.2", "glm-json-v2", "auto", GLM_STANDARD)
    await run_operation(captured, request)
    body = captured.body
    assert "thinking" not in body
    assert "reasoning_effort" not in body
    assert body["max_tokens"] == 16384


@pytest.mark.asyncio
async def test_openai_astra_sends_low_without_off(captured):
    request = v2_request("openai", "gpt-6-astra", "openai-json-schema-v2", "low", OPENAI_STANDARD)
    await run_operation(captured, request)
    assert captured.body["reasoning_effort"] == "low"
    # Off is rejected before HTTP for entries without a disable path.
    request = v2_request("openai", "gpt-6-astra", "openai-json-schema-v2", "off", OPENAI_STANDARD)
    with pytest.raises(WorkerError) as exc:
        await run_operation(captured, request)
    assert exc.value.code == "unsupported_capability"


@pytest.mark.asyncio
async def test_openai_55_caps_at_xhigh(captured):
    request = v2_request("openai", "gpt-5.5", "openai-json-schema-v2", "xhigh", OPENAI_STANDARD)
    await run_operation(captured, request)
    assert captured.body["reasoning_effort"] == "xhigh"
    request = v2_request("openai", "gpt-5.5", "openai-json-schema-v2", "max", OPENAI_STANDARD)
    with pytest.raises(WorkerError) as exc:
        await run_operation(captured, request)
    assert exc.value.code == "unsupported_capability"


@pytest.mark.asyncio
async def test_glm_v1_legacy(captured):
    request = v2_request("glm", "glm-4.7-flash", "glm-json-v1", "off", GLM_STANDARD)
    await run_operation(captured, request)
    body = captured.body
    assert body["temperature"] == 0.2
    assert body["max_tokens"] == 4096
    assert body["thinking"] == {"type": "disabled"}


@pytest.mark.asyncio
async def test_glm_coding_plan_routes_distinct_path(captured):
    """Standard and Coding Plan URLs keep their distinct paths and keys;
    registration does not fall back between endpoints."""
    request = v2_request("glm", "glm-5.3-flash", "glm-json-v2", "low", GLM_CODING)
    await run_operation(captured, request)
    assert len(captured.calls) == 1
    assert captured.url == "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions"
    assert captured.body["thinking"] == {"type": "enabled"}


@pytest.mark.asyncio
async def test_unsupported_effort_fails_before_http(captured):
    request = v2_request("glm", "glm-5.3", "glm-json-v2", "off", GLM_STANDARD)
    with pytest.raises(WorkerError) as exc:
        await run_operation(captured, request)
    assert exc.value.code == "unsupported_capability"
    assert captured.calls == []  # zero HTTP


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("provider", "model", "profile", "base_url"),
    [
        ("openai", "gpt-4.1-mini-2025-04-14", "openai-json-schema-v2", OPENAI_STANDARD),
        ("glm", "glm-4.7-flash", "glm-json-v2", GLM_STANDARD),
    ],
    ids=["openai-nonreasoning-low", "glm-binary-thinking-low"],
)
async def test_unsupported_low_effort_fails_before_http(captured, provider: str, model: str, profile: str, base_url: str):
    request = v2_request(provider, model, profile, "low", base_url)
    with pytest.raises(WorkerError) as exc:
        await run_operation(captured, request)
    assert exc.value.code == "unsupported_capability"
    assert captured.calls == []


@pytest.mark.asyncio
async def test_silent_adapter_mutation_is_unsupported_capability(captured, monkeypatch):
    """A payload the profile guard sees as mutated (dropped temperature)
    fails before any HTTP call, preserved through SDK wrapping."""
    from langchain_openai import ChatOpenAI

    original = ChatOpenAI._get_request_payload

    def mutated(self, input_, *, stop=None, **kwargs):
        payload = original(self, input_, stop=stop, **kwargs)
        payload.pop("temperature", None)
        return payload

    monkeypatch.setattr(ChatOpenAI, "_get_request_payload", mutated)
    request = v2_request("glm", "glm-4.7-flash", "glm-json-v1", "off", GLM_STANDARD)
    with pytest.raises(WorkerError) as exc:
        await run_operation(captured, request)
    assert exc.value.code == "unsupported_capability"
    assert captured.calls == []


@pytest.mark.asyncio
async def test_guard_rejects_added_tools(captured, monkeypatch):
    from langchain_openai import ChatOpenAI

    original = ChatOpenAI._get_request_payload

    def mutated(self, input_, *, stop=None, **kwargs):
        payload = original(self, input_, stop=stop, **kwargs)
        payload["tools"] = [{"type": "function"}]
        return payload

    monkeypatch.setattr(ChatOpenAI, "_get_request_payload", mutated)
    request = v2_request("openai", "gpt-6-luna", "openai-json-schema-v2", "low", OPENAI_STANDARD)
    with pytest.raises(WorkerError) as exc:
        await run_operation(captured, request)
    assert exc.value.code == "unsupported_capability"
    assert captured.calls == []


@pytest.mark.asyncio
async def test_align_uses_frozen_endpoint_and_effort(captured):
    captured.reply = json.dumps(
        {"status": "matched", "matches": [{"quote": "装罐", "occurrence": 1}], "reason": "none"},
        ensure_ascii=False,
    )
    request = v2_request("glm", "glm-5.3-flash", "glm-json-v2", "low", GLM_CODING, op="align")
    data, meta = await run_operation(captured, request)
    assert captured.url == "https://open.bigmodel.cn/api/coding/paas/v4/chat/completions"
    assert meta["requested_effort"] == "low"
    assert data["status"] == "matched"


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "provider,model,profile,base_url,token_field,efforts",
    [
        ("kimi", model, "kimi-json-v2", "https://api.moonshot.cn/v1/", "max_completion_tokens",
         ("auto", "low", "high", "max"))
        for model in ("kimi-k3.1-pro", "kimi-k3.1-pro-highspeed", "kimi-k3")
    ] + [
        ("deepseek", model, "deepseek-json-v2", "https://api.deepseek.com/", "max_tokens",
         ("auto", "off", "low", "high", "max"))
        for model in ("deepseek-flash", "deepseek-v4-pro")
    ],
)
async def test_vendor_v2_final_body(provider, model, profile, base_url, token_field, efforts):
    for effort in efforts:
        captured = Captured()
        await run_operation(captured, v2_request(provider, model, profile, effort, base_url))
        assert len(captured.calls) == 1
        assert captured.calls[0][1] == f"Bearer {SYNTHETIC_KEY}"
        assert captured.url == base_url + "chat/completions"
        body = captured.body
        assert body["model"] == model
        assert body["response_format"] == {"type": "json_object"}
        assert body[token_field] == (8192 if effort == "off" else 16384)
        assert {"max_tokens", "max_completion_tokens"} & body.keys() == {token_field}
        assert body.get("reasoning_effort") == (None if effort in ("auto", "off") else effort)
        assert "temperature" not in body
        if provider == "deepseek" and effort != "auto":
            assert body["thinking"] == {"type": "disabled" if effort == "off" else "enabled"}
        else:
            assert "thinking" not in body


@pytest.mark.asyncio
@pytest.mark.parametrize(
    "provider,model,base_url,token_field,cases",
    [
        ("kimi", "kimi-k3.1-pro", "https://api.moonshot.cn/v1/", "max_completion_tokens",
         [("auto", 4096, None), ("high", 4096, None)]),
        ("deepseek", "deepseek-flash", "https://api.deepseek.com/", "max_tokens",
         [("off", 2048, {"type": "disabled"}), ("low", 4096, {"type": "enabled"}), ("auto", 4096, None)]),
    ],
)
async def test_vendor_v2_align_final_body(provider, model, base_url, token_field, cases):
    # Alignment uses the same capability mapping with the alignment-side
    # caps: explicit Off keeps the plain cap; graded/Auto use the reasoning
    # cap. Kimi has no Off and never sends thinking.
    for effort, expected_cap, thinking in cases:
        captured = Captured()
        captured.reply = json.dumps(
            {"status": "matched", "matches": [{"quote": "装罐", "occurrence": 1}], "reason": "none"},
            ensure_ascii=False,
        )
        await run_operation(captured, v2_request(provider, model, f"{provider}-json-v2", effort, base_url, op="align"))
        assert len(captured.calls) == 1
        assert captured.calls[0][1] == f"Bearer {SYNTHETIC_KEY}"
        assert captured.url == base_url + "chat/completions"
        body = captured.body
        assert body[token_field] == expected_cap
        assert {"max_tokens", "max_completion_tokens"} & body.keys() == {token_field}
        assert body.get("reasoning_effort") == (None if effort in ("auto", "off") else effort)
        assert "temperature" not in body
        if thinking is None:
            assert "thinking" not in body
        else:
            assert body["thinking"] == thinking


@pytest.mark.asyncio
async def test_gpt_6_sol_accepts_explicit_off(captured):
    request = v2_request("openai", "gpt-6-sol", "openai-json-schema-v2", "off", OPENAI_STANDARD)
    await run_operation(captured, request)
    assert captured.body["reasoning_effort"] == "none"
    assert captured.body["response_format"]["type"] == "json_schema"
