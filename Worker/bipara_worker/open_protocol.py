"""Open protocol adapter. Catalogs never gate user-selected models or effort.

Keep the final HTTP shape explicit instead of allowing an SDK to infer a
different API from a model name. LangChain still owns the model invocation.
"""

from __future__ import annotations

import json
import math
import re
from typing import Any

import httpx

from .errors import WorkerError
from .protocol import Request, RequestError, _parse_base_url, decode_json_strict

PROTECTED = {
    "model", "input", "messages", "system", "instructions", "tools", "tool_choice", "stream",
    "text", "response_format", "output_format", "previous_response_id", "conversation",
    "background", "store", "include", "service_tier", "max_output_tokens", "max_tokens",
}
RESERVED_HEADERS = {
    "host", "content-length", "transfer-encoding", "connection", "content-type",
    "authorization", "x-api-key", "anthropic-version",
}


def header_name(value: Any) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9-]{1,128}", value) is not None


def validate_headers(raw: Any) -> dict[str, str]:
    if not isinstance(raw, dict) or len(raw) > 32:
        raise RequestError("invalid headers")
    if len({key.lower() for key in raw}) != len(raw):
        raise RequestError("duplicate headers")
    for key, value in raw.items():
        if not header_name(key) or key.lower() in RESERVED_HEADERS or not isinstance(value, str):
            raise RequestError("invalid header")
        if any(not 32 <= ord(c) <= 126 for c in value):
            raise RequestError("invalid header value")
    if len(json.dumps(raw).encode()) > 4096:
        raise RequestError("headers too large")
    return raw


def validate_options(raw: Any, provider: str) -> dict[str, Any]:
    required = {"authentication", "headerName", "apiVersion", "outputMode", "translationTokens", "alignmentTokens", "extraBodyJSON"}
    if not isinstance(raw, dict) or not required <= raw.keys() or raw.keys() - required - {"endpointURL", "temperature"}:
        raise RequestError("invalid options")
    if raw["authentication"] not in ("bearer", "apiKey", "custom", "none") or not header_name(raw["headerName"]):
        raise RequestError("invalid authentication")
    if raw["authentication"] == "custom" and raw["headerName"].lower() in RESERVED_HEADERS - {"authorization", "x-api-key"}:
        raise RequestError("reserved authentication header")
    if not isinstance(raw["apiVersion"], str) or len(raw["apiVersion"]) > 128 or any(not 32 <= ord(c) <= 126 for c in raw["apiVersion"]):
        raise RequestError("invalid API version")
    for key in ("translationTokens", "alignmentTokens"):
        if type(raw[key]) is not int or not 1 <= raw[key] <= 1_048_576:
            raise RequestError("invalid token limit")
    temp = raw.get("temperature")
    if temp is not None and (type(temp) not in (int, float) or not math.isfinite(temp) or not 0 <= temp <= 2):
        raise RequestError("invalid temperature")
    if raw["outputMode"] not in ("promptJSON", "jsonObject", "jsonSchema") or (provider == "anthropic" and raw["outputMode"] == "jsonObject"):
        raise RequestError("invalid output mode")
    if "endpointURL" in raw:
        _parse_base_url(raw["endpointURL"], operation_url=True)
    text = raw["extraBodyJSON"]
    if not isinstance(text, str):
        raise RequestError("invalid additional parameters")
    try:
        if len(text.encode()) > 16384:
            raise ValueError("additional parameters too large")
        body = decode_json_strict(text)
    except Exception as exc:
        raise RequestError("invalid additional JSON") from exc
    if not isinstance(body, dict) or PROTECTED.intersection(body):
        raise RequestError("additional parameters replace task fields")
    if isinstance(body.get("output_config"), dict) and "format" in body["output_config"]:
        raise RequestError("additional parameters replace output schema")
    for key in ("reasoning", "thinking", "output_config"):
        if key in body and not isinstance(body[key], dict):
            raise RequestError("reasoning parameters must be objects")
    return raw


def request_body(request: Request, schema: dict, messages: list[Any]) -> dict:
    cfg, opts = request.config, request.config.options
    assert opts is not None
    if len(messages) != 2 or [m.type for m in messages] != ["system", "human"]:
        raise WorkerError("invalid_request")
    cap = opts["translationTokens" if request.op == "translate" else "alignmentTokens"]
    body: dict[str, Any] = {"model": cfg.model, "stream": False}
    if cfg.provider == "openai":
        body.update(input=[{"role": "system", "content": messages[0].content},
                           {"role": "user", "content": messages[1].content}],
                    max_output_tokens=cap, store=False,
                    reasoning={"effort": "none" if cfg.effort == "off" else cfg.effort})
    else:
        body.update(system=messages[0].content, messages=[{"role": "user", "content": messages[1].content}], max_tokens=cap)
        body["thinking"] = {"type": "disabled" if cfg.effort == "off" else "adaptive"}
        if cfg.effort != "off":
            body["output_config"] = {"effort": cfg.effort}
    if opts.get("temperature") is not None:
        body["temperature"] = opts["temperature"]
    # One explicit override layer. The editor shows its precedence.
    extra = decode_json_strict(opts["extraBodyJSON"])
    for key, value in extra.items():
        if isinstance(value, dict) and isinstance(body.get(key), dict):
            body[key] = {**body[key], **value}
        else:
            body[key] = value
    mode = opts["outputMode"]
    if cfg.provider == "openai" and mode != "promptJSON":
        fmt = {"type": "json_object"} if mode == "jsonObject" else {"type": "json_schema", "name": schema["title"], "strict": True, "schema": schema}
        body["text"] = {"format": fmt}
    elif cfg.provider == "anthropic" and mode == "jsonSchema":
        body.setdefault("output_config", {})["format"] = {"type": "json_schema", "schema": schema}
    return body


def response_text(raw: Any, provider: str) -> tuple[str, dict, dict | None]:
    if not isinstance(raw, dict):
        raise WorkerError("invalid_output")
    if provider == "openai":
        if raw.get("status") == "incomplete":
            details = raw.get("incomplete_details")
            reason = details.get("reason") if isinstance(details, dict) else None
            raise WorkerError("output_limit" if reason == "max_output_tokens" else "refused")
        if raw.get("status") != "completed" or not isinstance(raw.get("output"), list):
            raise WorkerError("invalid_output")
        blocks = []
        for item in raw["output"]:
            if not isinstance(item, dict):
                raise WorkerError("invalid_output")
            if item.get("type") == "reasoning":
                continue
            if item.get("type") != "message" or item.get("role") != "assistant" or not isinstance(item.get("content"), list):
                raise WorkerError("invalid_output")
            blocks.extend(item["content"])
        text_type = "output_text"
    else:
        if raw.get("stop_reason") == "max_tokens":
            raise WorkerError("output_limit")
        if raw.get("stop_reason") == "refusal":
            raise WorkerError("refused")
        if raw.get("type") != "message" or raw.get("role") != "assistant" or raw.get("stop_reason") != "end_turn":
            raise WorkerError("invalid_output")
        blocks = raw.get("content")
        text_type = "text"
    if not isinstance(blocks, list):
        raise WorkerError("invalid_output")
    text = []
    for block in blocks:
        if not isinstance(block, dict):
            raise WorkerError("invalid_output")
        if block.get("type") in ("thinking", "redacted_thinking"):
            continue
        if block.get("type") == "refusal":
            raise WorkerError("refused")
        if block.get("type") != text_type or not isinstance(block.get("text"), str):
            raise WorkerError("invalid_output")
        text.append(block["text"])
    usage = raw.get("usage", {})
    tokens = {k: usage.get(k) for k in ("input_tokens", "output_tokens")} if isinstance(usage, dict) else {}
    clean = all(type(tokens.get(k)) is int and tokens[k] >= 0 for k in ("input_tokens", "output_tokens"))
    if clean:
        tokens["total_tokens"] = tokens["input_tokens"] + tokens["output_tokens"]
    return "".join(text), {"model_name": raw.get("model")}, tokens if clean else None


def build_model(request: Request, schema: dict, client: httpx.AsyncClient | None):
    from langchain_core.language_models.chat_models import BaseChatModel
    from langchain_core.messages import AIMessage
    from langchain_core.outputs import ChatGeneration, ChatResult

    class ProtocolModel(BaseChatModel):
        @property
        def _llm_type(self) -> str:
            return "bipara-open-protocol"

        def _generate(self, messages, stop=None, run_manager=None, **kwargs):
            raise NotImplementedError("asynchronous invocation only")

        async def _agenerate(self, messages, stop=None, run_manager=None, **kwargs):
            opts = request.config.options
            assert opts is not None
            body = request_body(request, schema, messages)
            path = "responses" if request.config.provider == "openai" else "v1/messages"
            url = opts.get("endpointURL") or request.config.base_url + path
            headers = {"content-type": "application/json", **request.secret_headers}
            auth = opts["authentication"]
            if auth == "bearer":
                headers["authorization"] = "Bearer " + request.api_key
            elif auth in ("apiKey", "custom"):
                headers["x-api-key" if auth == "apiKey" else opts["headerName"]] = request.api_key
            if request.config.provider == "anthropic":
                headers["anthropic-version"] = opts["apiVersion"]
            async def send(http: httpx.AsyncClient):
                try:
                    async with http.stream("POST", url, json=body, headers=headers, follow_redirects=False) as response:
                        if response.status_code >= 300:
                            from .models import _retry_after_ms
                            code = {400: "unsupported_capability", 401: "authentication", 403: "authentication", 402: "quota_exceeded", 404: "model_unavailable", 413: "context_limit", 422: "unsupported_capability", 429: "rate_limited"}.get(response.status_code, "network")
                            error = httpx.HTTPStatusError("provider request failed", request=response.request, response=response)
                            raise WorkerError(code, _retry_after_ms(error) if code == "rate_limited" else None, http_status=response.status_code)
                        data = bytearray()
                        async for chunk in response.aiter_bytes():
                            data.extend(chunk)
                            if len(data) > 2 * 1024 * 1024:
                                raise WorkerError("output_limit")
                    try:
                        raw = decode_json_strict(data.decode("utf-8"))
                    except Exception as exc:
                        raise WorkerError("invalid_output") from exc
                    content, meta, usage = response_text(raw, request.config.provider)
                    return ChatResult(generations=[ChatGeneration(message=AIMessage(content=content, response_metadata=meta, usage_metadata=usage))])
                except httpx.TimeoutException as exc:
                    raise WorkerError("timeout") from exc
                except httpx.HTTPError as exc:
                    raise WorkerError("network") from exc
            if client is not None:
                return await send(client)
            async with httpx.AsyncClient(trust_env=False, follow_redirects=False, timeout=httpx.Timeout(120, connect=10)) as http:
                return await send(http)

    return ProtocolModel()
