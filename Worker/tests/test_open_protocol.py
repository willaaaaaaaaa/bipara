"""Capture actual Requests/Responses for arbitrary models without network access."""

import asyncio
import json

import httpx
import pytest

from bipara_worker.assets import load_assets
from bipara_worker.errors import WorkerError
from bipara_worker.models import make_langchain_operation
from bipara_worker.protocol import RequestError, parse_request
from conftest import SYNTHETIC_KEY, T01_UNIT_ID, translate_request_t01


def envelope(provider="openai", effort="low", **options):
    env = translate_request_t01()
    env["config"] = {
        "provider": provider, "profile": "openai-responses-v3" if provider == "openai" else "anthropic-messages-v3",
        "model": "unknown-model-2027", "base_url": "https://gateway.example.com/api/coding/v3/" if provider == "openai" else "https://gateway.example.com/api/coding/",
        "effort": effort, "options": {
            "authentication": "bearer" if provider == "openai" else "apiKey", "headerName": "X-API-Key",
            "apiVersion": "2023-06-01", "outputMode": "promptJSON", "translationTokens": 12345,
            "alignmentTokens": 2345, "extraBodyJSON": "{}", **options,
        },
    }
    env["credentials"]["headers"] = {"X-Tenant": "synthetic-tenant"}
    return env


def reply(provider, op="translate"):
    text = json.dumps({"translations": [{"unit_id": T01_UNIT_ID, "text": "A synthetic translation."}]} if op == "translate" else {"status": "matched", "matches": [{"quote": "装罐", "occurrence": 1}], "reason": "none"})
    common = {"model": "returned-synthetic", "usage": {"input_tokens": 7, "output_tokens": 9}}
    if provider == "openai":
        return {**common, "status": "completed", "output": [{"type": "reasoning", "summary": []}, {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": text}]}]}
    return {**common, "type": "message", "role": "assistant", "stop_reason": "end_turn", "content": [{"type": "thinking", "thinking": "ignored synthetic reasoning"}, {"type": "text", "text": text}]}


async def invoke(env, response=None, status=200, seen=None):
    def handle(request):
        if seen is not None:
            seen.append((str(request.url), dict(request.headers), json.loads(request.content)))
        return httpx.Response(status, json=response if response is not None else reply(env["config"]["provider"], env["op"]), headers={"Retry-After": "2"})
    async with httpx.AsyncClient(transport=httpx.MockTransport(handle), trust_env=False) as client:
        operation, _ = make_langchain_operation(load_assets(), client)
        return await operation(parse_request(env))


@pytest.mark.asyncio
@pytest.mark.parametrize("provider", ["openai", "anthropic"])
@pytest.mark.parametrize("effort", ["off", "low", "medium", "high"])
@pytest.mark.parametrize("op", ["translate", "align"])
async def test_unknown_model_all_efforts_actual_request(provider, effort, op):
    env = envelope(provider, effort)
    if op == "align":
        env.update(op="align", prompt_version="alignment.v1", input={"reading_text": "I can can fruit.", "counterpart_text": "我会把水果装罐。", "selection": {"before": "I can ", "text": "can", "after": " fruit."}})
    seen = []
    result, meta = await invoke(env, seen=seen)
    assert len(seen) == 1
    url, headers, body = seen[0]
    assert body["model"] == "unknown-model-2027" and meta["requested_effort"] == effort
    assert meta["input_tokens"] == 7 and meta["output_tokens"] == 9
    assert headers["x-tenant"] == "synthetic-tenant"
    assert body["stream"] is False and "temperature" not in body
    assert not {"tools", "tool_choice"}.intersection(body)
    prompt = load_assets().prompts[env["prompt_version"]]
    if provider == "openai":
        assert url == "https://gateway.example.com/api/coding/v3/responses"
        assert body["reasoning"] == {"effort": "none" if effort == "off" else effort}
        assert body["max_output_tokens"] == (12345 if op == "translate" else 2345)
        assert body["input"][0] == {"role": "system", "content": prompt}
        assert json.loads(body["input"][1]["content"]) == env["input"]
        assert headers["authorization"] == f"Bearer {SYNTHETIC_KEY}" and body["store"] is False
    else:
        assert url == "https://gateway.example.com/api/coding/v1/messages"
        assert body["thinking"] == {"type": "disabled" if effort == "off" else "adaptive"}
        assert body.get("output_config") == (None if effort == "off" else {"effort": effort})
        assert body["max_tokens"] == (12345 if op == "translate" else 2345)
        assert body["system"] == prompt and json.loads(body["messages"][0]["content"]) == env["input"]
        assert headers["x-api-key"] == SYNTHETIC_KEY and headers["anthropic-version"] == "2023-06-01"


@pytest.mark.asyncio
@pytest.mark.parametrize("provider,mode", [("openai", "jsonObject"), ("openai", "jsonSchema"), ("anthropic", "jsonSchema")])
async def test_output_modes_and_full_endpoint(provider, mode):
    env = envelope(provider, outputMode=mode, endpointURL="https://alternate.example.com/custom/invoke", temperature=0)
    seen = []
    await invoke(env, seen=seen)
    url, _, body = seen[0]
    assert url == "https://alternate.example.com/custom/invoke" and body["temperature"] == 0
    fmt = body["text"]["format"] if provider == "openai" else body["output_config"]["format"]
    assert fmt["type"] == ("json_object" if mode == "jsonObject" else "json_schema")
    if mode == "jsonSchema":
        assert fmt["schema"] == load_assets().schemas[env["prompt_version"]]


@pytest.mark.asyncio
async def test_explicit_parameter_override_and_no_auth():
    seen = []
    env = envelope("anthropic", authentication="none", extraBodyJSON='{"thinking":{"type":"enabled","budget_tokens":2048}}')
    env["credentials"]["api_key"] = ""
    await invoke(env, seen=seen)
    assert "authorization" not in seen[0][1] and "x-api-key" not in seen[0][1]
    assert seen[0][2]["thinking"] == {"type": "enabled", "budget_tokens": 2048}


@pytest.mark.parametrize("change", [
    {"extraBodyJSON": '{"model":"different"}'}, {"extraBodyJSON": '{"messages":[]}'},
    {"extraBodyJSON": '{"output_config":{"format":{}}}'}, {"extraBodyJSON": '{"a":1,"a":2}'},
    {"extraBodyJSON": '{"temperature":NaN}'}, {"extraBodyJSON": '[]'},
    {"extraBodyJSON": '{"output_config":null}'}, {"extraBodyJSON": '{"reasoning":false}'},
    {"extraBodyJSON": '\ud800'}, {"apiVersion": "非ASCII"},
    {"translationTokens": True}, {"alignmentTokens": 0}, {"temperature": float("inf")},
    {"endpointURL": "http://example.com/request"}, {"authentication": "custom", "headerName": "Host"},
    {"apiVersion": "version\r\nX-Injected: secret"},
])
def test_invalid_options_rejected_before_dispatch(change):
    with pytest.raises(RequestError):
        parse_request(envelope(**change))


@pytest.mark.parametrize("headers", [{"Authorization": "secret"}, {"X-Tenant": "one", "x-tenant": "two"}, {"X-Tenant": "value\r\nInjected: true"}])
def test_secret_header_validation(headers):
    env = envelope()
    env["credentials"]["headers"] = headers
    with pytest.raises(RequestError):
        parse_request(env)


@pytest.mark.asyncio
@pytest.mark.parametrize("status,code", [(400, "unsupported_capability"), (401, "authentication"), (404, "model_unavailable"), (429, "rate_limited"), (500, "network"), (302, "network")])
async def test_errors_never_retry_or_leak_payload(status, code):
    seen = []
    with pytest.raises(WorkerError) as exc:
        await invoke(envelope(), response={"error": {"message": "SECRET_PROVIDER_TEXT"}}, status=status, seen=seen)
    assert len(seen) == 1 and exc.value.code == code
    assert "SECRET" not in str(exc.value)
    if status == 429:
        assert exc.value.retry_after_ms == 2000


@pytest.mark.asyncio
@pytest.mark.parametrize("provider", ["openai", "anthropic"])
async def test_malformed_translation_keeps_local_validation(provider):
    raw = reply(provider)
    block = raw["output"][-1]["content"][0] if provider == "openai" else raw["content"][-1]
    block["text"] = '{"translations":[]}'
    with pytest.raises(WorkerError, match="invalid_output"):
        await invoke(envelope(provider), response=raw)


@pytest.mark.asyncio
async def test_cancellation_propagates_without_retry():
    called = asyncio.Event()
    async def handle(request):
        called.set()
        await asyncio.Event().wait()
    async with httpx.AsyncClient(transport=httpx.MockTransport(handle)) as client:
        operation, _ = make_langchain_operation(load_assets(), client)
        task = asyncio.create_task(operation(parse_request(envelope())))
        await asyncio.wait_for(called.wait(), 2)
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task


@pytest.mark.parametrize("key", ["key\r\nInjected: true", "非ASCII"])
def test_authentication_value_is_validated_before_http(key):
    env = envelope()
    env["credentials"]["api_key"] = key
    with pytest.raises(RequestError):
        parse_request(env)


@pytest.mark.asyncio
@pytest.mark.parametrize("raw,code", [
    ({"status": "incomplete", "incomplete_details": None}, "refused"),
    ({"status": "incomplete", "incomplete_details": {"reason": "max_output_tokens"}}, "output_limit"),
    ({"status": "completed", "output": [None]}, "invalid_output"),
    ({"status": "completed", "output": [{"type": "function_call"}]}, "invalid_output"),
])
async def test_response_shape_and_truncation(raw, code):
    with pytest.raises(WorkerError) as exc:
        await invoke(envelope(), response=raw)
    assert exc.value.code == code
