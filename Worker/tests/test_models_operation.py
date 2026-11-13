"""Operation-level tests for make_langchain_operation with an injected
fake model.

These execute the REAL operation function — legacy rejection, canonical
prompt/message composition, ainvoke dispatch, finish-reason handling,
strict parsing, validation, and metadata extraction — with no HTTP. The
translation path asserts the result of the isinstance(TranslateInput)
branch, so removing the models.TranslateInput import fails these tests.
"""

from __future__ import annotations

import json

import pytest

import bipara_worker.models as models
from bipara_worker.assets import load_assets, load_cases
from bipara_worker.errors import WorkerError
from bipara_worker.models import make_langchain_operation
from bipara_worker.protocol import parse_request

from conftest import align_request_a01, translate_request_markdown, translate_request_t01


class FakeMessage:
    def __init__(self, content, finish_reason=None, usage=None, model_name=None):
        self.content = content
        self.response_metadata = {}
        if finish_reason is not None:
            self.response_metadata["finish_reason"] = finish_reason
        if model_name is not None:
            self.response_metadata["model_name"] = model_name
        self.usage_metadata = usage


class FakeModel:
    """Records composed messages; replies with a scripted AIMessage."""

    def __init__(self, reply=None, error=None):
        self.reply = reply
        self.error = error
        self.calls = []

    async def ainvoke(self, messages):
        self.calls.append(messages)
        if self.error is not None:
            raise self.error
        return self.reply


class AuthenticationError(Exception):
    pass


def make_operation(monkeypatch, fake: FakeModel):
    monkeypatch.setattr(models, "_build_model", lambda *args, **kwargs: models.BuiltModel(fake))
    assets = load_assets()
    operation, aclose = make_langchain_operation(assets)
    return operation


@pytest.mark.asyncio
@pytest.mark.parametrize("prompt_version", ["translation.v1", "translation.v2"])
async def test_translate_operation_executes_real_branch(monkeypatch, prompt_version):
    fake = FakeModel(reply=FakeMessage(
        content=json.dumps(
            {"translations": [{"unit_id": "22222222-2222-4222-8222-222222222222",
                               "text": "Li Ming has not confirmed Friday's meeting."}]},
            ensure_ascii=False,
        ),
        usage={"input_tokens": 12, "output_tokens": 9},
        model_name="gpt-4.1-mini-2025-04-14",
    ))
    operation = make_operation(monkeypatch, fake)
    envelope = translate_request_t01()
    envelope["prompt_version"] = prompt_version
    request = parse_request(envelope)
    data, meta = await operation(request)

    # isinstance(TranslateInput) branch: this assertion fails with a
    # NameError/worker_failed if the models.TranslateInput import is
    # removed again.
    assert data == {"translations": [
        {"unit_id": "22222222-2222-4222-8222-222222222222",
         "text": "Li Ming has not confirmed Friday's meeting."}
    ]}
    assert meta["provider"] == "openai"
    assert meta["requested_model"] == "gpt-4.1-mini-2025-04-14"
    assert meta["returned_model"] == "gpt-4.1-mini-2025-04-14"
    assert meta["prompt_version"] == prompt_version
    assert meta["input_tokens"] == 12 and meta["output_tokens"] == 9

    # Message composition contract: exactly two messages, canonical system
    # asset verbatim, user message is the compact ensure_ascii=False JSON.
    from langchain_core.messages import HumanMessage, SystemMessage

    assert len(fake.calls) == 1
    system, human = fake.calls[0]
    assert isinstance(system, SystemMessage)
    assert isinstance(human, HumanMessage)
    assert system.content == load_assets().prompts[prompt_version]
    assert human.content == json.dumps(
        translate_request_t01()["input"], ensure_ascii=False, separators=(",", ":")
    )


@pytest.mark.asyncio
@pytest.mark.parametrize("invalid_text", [None, "甲\n乙\n丙"])
async def test_markdown_operation_uses_versioned_prompt_and_source_line_bound(monkeypatch, invalid_text):
    envelope = translate_request_markdown()
    case = next(case for case in load_cases()["cases"] if case["id"] == "M01-inline-order-and-hard-break")
    output = {"translations": [{
        "unit_id": envelope["input"]["units"][0]["unit_id"],
        "text": invalid_text or case["sample_output"]["translations"][0]["text"],
    }]}
    fake = FakeModel(reply=FakeMessage(content=json.dumps(output, ensure_ascii=False)))
    operation = make_operation(monkeypatch, fake)
    if invalid_text is None:
        data, meta = await operation(parse_request(envelope))
        assert data == output
        assert meta["prompt_version"] == "translation.markdown.v1"
    else:
        with pytest.raises(WorkerError) as exc:
            await operation(parse_request(envelope))
        assert exc.value.code == "invalid_output"
    system, human = fake.calls[0]
    assert system.content == load_assets().prompts["translation.markdown.v1"]
    assert json.loads(human.content) == envelope["input"]
    assert len(fake.calls) == 1


@pytest.mark.asyncio
async def test_align_operation_executes_real_branch(monkeypatch):
    fake = FakeModel(reply=FakeMessage(
        content=json.dumps(
            {"status": "matched", "matches": [{"quote": "装罐", "occurrence": 1}], "reason": "none"},
            ensure_ascii=False,
        ),
    ))
    operation = make_operation(monkeypatch, fake)
    request = parse_request(align_request_a01())
    data, meta = await operation(request)
    assert data["status"] == "matched"
    assert meta["prompt_version"] == "alignment.v1"
    assert meta["input_tokens"] is None and meta["output_tokens"] is None
    # Alignment uses the canonical alignment system asset.
    from langchain_core.messages import SystemMessage

    system = fake.calls[0][0]
    assert isinstance(system, SystemMessage)
    assert system.content == load_assets().prompts["alignment.v1"]


@pytest.mark.asyncio
async def test_legacy_model_rejected_before_model_call(monkeypatch):
    fake = FakeModel(reply=FakeMessage(content="{}"))
    operation = make_operation(monkeypatch, fake)
    env = translate_request_t01()
    env["config"]["model"] = "gpt-4-turbo"
    request = parse_request(env)
    with pytest.raises(WorkerError) as exc:
        await operation(request)
    assert exc.value.code == "unsupported_capability"
    assert fake.calls == []  # zero model invocations


@pytest.mark.asyncio
async def test_length_finish_reason_maps_to_output_limit(monkeypatch):
    fake = FakeModel(reply=FakeMessage(content='{"translations":[]}', finish_reason="length"))
    operation = make_operation(monkeypatch, fake)
    with pytest.raises(WorkerError) as exc:
        await operation(parse_request(translate_request_t01()))
    assert exc.value.code == "output_limit"


@pytest.mark.asyncio
async def test_content_filter_maps_to_refused(monkeypatch):
    fake = FakeModel(reply=FakeMessage(content="{}", finish_reason="content_filter"))
    operation = make_operation(monkeypatch, fake)
    with pytest.raises(WorkerError) as exc:
        await operation(parse_request(translate_request_t01()))
    assert exc.value.code == "refused"


@pytest.mark.asyncio
async def test_invalid_model_content_is_invalid_output(monkeypatch):
    fake = FakeModel(reply=FakeMessage(content="not json at all"))
    operation = make_operation(monkeypatch, fake)
    with pytest.raises(WorkerError) as exc:
        await operation(parse_request(translate_request_t01()))
    assert exc.value.code == "invalid_output"


@pytest.mark.asyncio
async def test_wrong_unit_ids_rejected_by_real_validation(monkeypatch):
    fake = FakeModel(reply=FakeMessage(content=json.dumps(
        {"translations": [{"unit_id": "99999999-9999-4999-8999-999999999999", "text": "x"}]}
    )))
    operation = make_operation(monkeypatch, fake)
    with pytest.raises(WorkerError) as exc:
        await operation(parse_request(translate_request_t01()))
    assert exc.value.code == "invalid_output"


@pytest.mark.asyncio
async def test_provider_error_normalized(monkeypatch):
    fake = FakeModel(error=AuthenticationError("bad key"))
    operation = make_operation(monkeypatch, fake)
    with pytest.raises(WorkerError) as exc:
        await operation(parse_request(translate_request_t01()))
    assert exc.value.code == "authentication"
