"""Offline capability/model tests: legacy rejection, capability mapping,
error normalization, and pure parsing/usage helpers. No HTTP is
attempted; the LangChain model is never constructed on the rejection
paths."""

from __future__ import annotations

import pytest

from bipara_worker.errors import WorkerError
from bipara_worker.models import (
    OPENAI_BASE_URL,
    GLM_BASE_URL,
    GLM_CODING_PLAN_BASE_URL,
    _normalize_provider_error,
    _parse_model_content,
    _returned_model,
    _token_usage,
    check_capability,
    efforts_for,
    output_caps,
)
from bipara_worker.protocol import AlignInput, AlignSelection, Config, TranslateInput, TranslateUnit


def config(provider: str, model: str, profile: str, effort: str = "auto", base_url: str | None = None) -> Config:
    return Config(
        provider=provider,
        model=model,
        profile=profile,
        effort=effort,
        base_url=base_url or (OPENAI_BASE_URL if provider == "openai" else GLM_BASE_URL),
    )


class TestLegacyModelRejection:
    def test_known_legacy_ids_rejected(self):
        for model in ("gpt-4", "gpt-4-turbo", "gpt-4-0613", "gpt-3.5-turbo", "gpt-3"):
            with pytest.raises(WorkerError) as exc:
                check_capability(config("openai", model, "openai-json-schema-v1"))
            assert exc.value.code == "unsupported_capability"

    def test_current_ids_not_rejected(self):
        for model in ("gpt-4.1-mini-2025-04-14", "gpt-4o", "gpt-4o-mini", "gpt-6-luna"):
            check_capability(config("openai", model, "openai-json-schema-v2"))  # must not raise

    def test_glm_provider_never_rejected(self):
        check_capability(config("glm", "glm-4.7-flash", "glm-json-v1", effort="off"))  # must not raise


class TestCapabilityTable:
    """Capability entries checked 2026-11-05 against provider docs."""

    def test_initial_entries(self):
        assert efforts_for("openai", "gpt-4.1-mini-2025-04-14") == ("auto",)
        assert efforts_for("openai", "gpt-6-luna") == (
            "auto", "off", "low", "medium", "high", "xhigh", "max",
        )
        assert efforts_for("glm", "glm-4.7-flash") == ("auto", "off", "on")
        assert efforts_for("glm", "glm-5.3") == ("auto", "low", "high", "max")
        assert efforts_for("glm", "glm-5.3-flash") == ("auto", "low", "high", "max")

    def test_full_official_entries(self):
        # OpenAI: no Off where the model rejects disabling reasoning; no
        # Max where the model tops out at xhigh.
        assert efforts_for("openai", "gpt-6-astra") == ("auto", "low", "medium", "high", "xhigh", "max")
        assert efforts_for("openai", "gpt-6.1-sol") == ("auto", "low", "medium", "high", "xhigh", "max")
        assert efforts_for("openai", "gpt-6.1-terra") == (
            "auto", "off", "low", "medium", "high", "xhigh", "max",
        )
        for model in ("gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"):
            assert efforts_for("openai", model) == (
                "auto", "off", "low", "medium", "high", "xhigh", "max",
            )
        for model in ("gpt-5.5", "gpt-5.4", "gpt-5.2"):
            assert efforts_for("openai", model) == (
                "auto", "off", "low", "medium", "high", "xhigh",
            )
        # GLM: the 5.3 series cannot disable thinking; GLM-5.2 can and also
        # accepts minimal; older models are binary-thinking only.
        for model in ("glm-5.3-flashx", "glm-5.3-flashx-legal"):
            assert efforts_for("glm", model) == ("auto", "low", "high", "max")
        assert efforts_for("glm", "glm-5.2") == (
            "auto", "off", "minimal", "low", "medium", "high", "xhigh", "max",
        )
        for model in ("glm-5.1", "glm-5", "glm-5-turbo", "glm-4.7", "glm-4.7-flashx"):
            assert efforts_for("glm", model) == ("auto", "off", "on")

    def test_unknown_models_allow_auto_only(self):
        assert efforts_for("openai", "totally-unknown") == ("auto",)
        assert efforts_for("glm", "glm-9") == ("auto",)

    def test_v2_unsupported_effort_rejected_before_model_call(self):
        # GLM-5.3 cannot disable thinking and offers no Minimal/Medium/Extra
        # high/On.
        for effort in ("off", "on", "minimal", "medium", "xhigh"):
            with pytest.raises(WorkerError) as exc:
                check_capability(config("glm", "glm-5.3", "glm-json-v2", effort=effort))
            assert exc.value.code == "unsupported_capability"
        # GLM-4.7-Flash offers binary thinking, never a graded effort.
        for effort in ("minimal", "low", "medium", "high", "xhigh", "max"):
            with pytest.raises(WorkerError) as exc:
                check_capability(config("glm", "glm-4.7-flash", "glm-json-v2", effort=effort))
            assert exc.value.code == "unsupported_capability"
        # OpenAI entries without a disable path reject Off; entries capped at
        # xhigh reject Max.
        with pytest.raises(WorkerError) as exc:
            check_capability(config("openai", "gpt-6-astra", "openai-json-schema-v2", effort="off"))
        assert exc.value.code == "unsupported_capability"
        with pytest.raises(WorkerError) as exc:
            check_capability(config("openai", "gpt-5.5", "openai-json-schema-v2", effort="max"))
        assert exc.value.code == "unsupported_capability"
        # Nonreasoning OpenAI entry: Auto only.
        with pytest.raises(WorkerError) as exc:
            check_capability(config("openai", "gpt-4.1-mini-2025-04-14", "openai-json-schema-v2", effort="low"))
        assert exc.value.code == "unsupported_capability"
        # Unknown model with an explicit effort requires a capability entry.
        with pytest.raises(WorkerError) as exc:
            check_capability(config("openai", "totally-unknown", "openai-json-schema-v2", effort="low"))
        assert exc.value.code == "unsupported_capability"

    def test_v2_supported_effort_allowed(self):
        check_capability(config("openai", "gpt-6-luna", "openai-json-schema-v2", effort="off"))
        check_capability(config("openai", "gpt-6-luna", "openai-json-schema-v2", effort="max"))
        check_capability(config("openai", "gpt-6-astra", "openai-json-schema-v2", effort="max"))
        check_capability(config("glm", "glm-5.3-flash", "glm-json-v2", effort="low"))
        check_capability(config("glm", "glm-4.7-flash", "glm-json-v2", effort="on"))
        check_capability(config("glm", "glm-5.2", "glm-json-v2", effort="off"))
        check_capability(config("glm", "glm-5.2", "glm-json-v2", effort="minimal"))
        check_capability(config("glm", "glm-5.2", "glm-json-v2", effort="xhigh"))
        check_capability(config("openai", "totally-unknown", "openai-json-schema-v2", effort="auto"))


class TestOutputCaps:
    """Reasoning-inclusive output caps per the configuration design."""

    def test_plain_caps(self):
        # v2 plain/nonreasoning/Off uses the doubled plain caps; both legacy
        # profiles keep their original 4096/1024.
        assert output_caps(config("openai", "gpt-4.1-mini-2025-04-14", "openai-json-schema-v2"), "translate") == (8192, 2048)
        assert output_caps(config("openai", "gpt-6-luna", "openai-json-schema-v2", effort="off"), "translate") == (8192, 2048)
        assert output_caps(config("glm", "glm-5.2", "glm-json-v2", effort="off"), "translate") == (8192, 2048)
        assert output_caps(config("deepseek", "deepseek-flash", "deepseek-json-v2", effort="off",
                                  base_url="https://api.deepseek.com/"), "align") == (8192, 2048)
        assert output_caps(config("deepseek", "deepseek-v4-pro", "deepseek-json-v2", effort="off",
                                  base_url="https://api.deepseek.com/"), "translate") == (8192, 2048)
        assert output_caps(config("openai", "gpt-4.1-mini-2025-04-14", "openai-json-schema-v1"), "align") == (4096, 1024)
        assert output_caps(config("glm", "glm-4.7-flash", "glm-json-v1", effort="off"), "translate") == (4096, 1024)

    def test_reasoning_caps(self):
        # Enabled, graded, Auto reasoning, and unknown v2 entries.
        assert output_caps(config("openai", "gpt-6-luna", "openai-json-schema-v2", effort="low"), "translate") == (16384, 4096)
        assert output_caps(config("openai", "gpt-6-luna", "openai-json-schema-v2", effort="auto"), "align") == (16384, 4096)
        assert output_caps(config("glm", "glm-4.7-flash", "glm-json-v2", effort="on"), "translate") == (16384, 4096)
        assert output_caps(config("glm", "glm-4.7-flash", "glm-json-v2", effort="auto"), "translate") == (16384, 4096)
        assert output_caps(config("glm", "glm-5.3", "glm-json-v2", effort="auto"), "translate") == (16384, 4096)
        assert output_caps(config("glm", "glm-5.3-flash", "glm-json-v2", effort="high"), "align") == (16384, 4096)
        assert output_caps(config("glm", "glm-5.2", "glm-json-v2", effort="low"), "translate") == (16384, 4096)
        assert output_caps(config("glm", "glm-5.2", "glm-json-v2", effort="auto"), "translate") == (16384, 4096)
        assert output_caps(config("kimi", "kimi-k3.1-pro", "kimi-json-v2",
                                  base_url="https://api.moonshot.cn/v1/"), "translate") == (16384, 4096)
        assert output_caps(config("kimi", "kimi-k3.1-pro-highspeed", "kimi-json-v2", effort="low",
                                  base_url="https://api.moonshot.cn/v1/"), "align") == (16384, 4096)
        assert output_caps(config("deepseek", "deepseek-flash", "deepseek-json-v2", effort="low",
                                  base_url="https://api.deepseek.com/"), "translate") == (16384, 4096)
        assert output_caps(config("deepseek", "deepseek-v4-pro", "deepseek-json-v2",
                                  base_url="https://api.deepseek.com/"), "align") == (16384, 4096)
        assert output_caps(config("openai", "totally-unknown", "openai-json-schema-v2"), "translate") == (16384, 4096)
        assert output_caps(config("glm", "glm-9", "glm-json-v2"), "translate") == (16384, 4096)


class FakeProviderError(Exception):
    pass


class TestErrorNormalization:
    def test_mapping(self):
        class AuthenticationError(FakeProviderError): pass
        class RateLimitError(FakeProviderError): pass
        class NotFoundError(FakeProviderError): pass
        class APIConnectionError(FakeProviderError): pass
        class APITimeoutError(FakeProviderError): pass
        class LengthFinishReasonError(FakeProviderError): pass
        class ContentFilterFinishReasonError(FakeProviderError): pass
        expectations = [
            (AuthenticationError, "authentication"),
            (RateLimitError, "rate_limited"),
            (NotFoundError, "model_unavailable"),
            (APIConnectionError, "network"),
            (APITimeoutError, "timeout"),
            (LengthFinishReasonError, "output_limit"),
            (ContentFilterFinishReasonError, "refused"),
        ]
        for cls, code in expectations:
            normalized = _normalize_provider_error(cls("x"))
            assert normalized.code == code

    def test_rate_limit_retry_after_parsed_and_bounded(self):
        class RateLimitError(FakeProviderError): pass
        exc = RateLimitError("slow down")
        exc.retry_after = 2.5
        normalized = _normalize_provider_error(exc)
        assert normalized.code == "rate_limited"
        assert normalized.retry_after_ms == 2500
        exc.retry_after = "999999"
        assert _normalize_provider_error(exc).retry_after_ms == 3_600_000
        exc.retry_after = None
        assert _normalize_provider_error(exc).retry_after_ms is None

    @pytest.mark.parametrize(("header", "expected"), [
        ("12", 12000), ("0", 0), ("999999", 3_600_000),
        ("Fri, 06 Nov 2026 00:00:30 GMT", 30000),
        ("Thu, 05 Nov 2026 23:59:30 GMT", 0), ("invalid", None),
    ])
    def test_sdk_rate_limit_uses_response_header(self, header, expected, monkeypatch):
        import httpx2
        from openai import RateLimitError

        monkeypatch.setattr("bipara_worker.models.time.time", lambda: 1793923200)
        response = httpx2.Response(429, request=httpx2.Request("POST", "https://example.invalid"),
                                   headers={"Retry-After": header})
        error = RateLimitError("synthetic", response=response, body={"error": {"code": "1302"}})
        normalized = _normalize_provider_error(error)
        assert (normalized.code, normalized.http_status, normalized.provider_code) == ("rate_limited", 429, "1302")
        assert normalized.retry_after_ms == expected

    def test_unknown_exception_becomes_worker_failed(self):
        class TotallyUnknown(FakeProviderError): pass
        assert _normalize_provider_error(TotallyUnknown("x")).code == "worker_failed"


class TestModelContentParsing:
    def test_valid_json_object(self):
        assert _parse_model_content('{"a": 1}') == {"a": 1}

    def test_non_string_content_rejected(self):
        with pytest.raises(WorkerError) as exc:
            _parse_model_content([{"type": "text"}])
        assert exc.value.code == "invalid_output"

    def test_markdown_wrapped_rejected(self):
        with pytest.raises(WorkerError) as exc:
            _parse_model_content('```json\n{"a": 1}\n```')
        assert exc.value.code == "invalid_output"

    def test_empty_and_garbage_rejected(self):
        for content in ("", "not json", '{"a": 1} trailing'):
            with pytest.raises(WorkerError):
                _parse_model_content(content)

    def test_duplicate_keys_rejected(self):
        with pytest.raises(WorkerError):
            _parse_model_content('{"a": 1, "a": 2}')


class TestMetadataExtraction:
    def test_returned_model_from_metadata(self):
        class Message:  # minimal stand-in
            response_metadata = {"model_name": "gpt-4.1-mini-2025-04-14"}
        assert _returned_model(Message()) == "gpt-4.1-mini-2025-04-14"

    def test_returned_model_absent_is_none(self):
        class Message:
            response_metadata = {}
        assert _returned_model(Message()) is None

    class _NoMeta:
        pass

    def test_no_metadata_is_none(self):
        assert _returned_model(self._NoMeta()) is None

    def test_token_usage_clean(self):
        class Message:
            usage_metadata = {"input_tokens": 12, "output_tokens": 3}
        assert _token_usage(Message()) == (12, 3)

    def test_token_usage_unavailable_is_null_never_zero(self):
        for usage in (None, {}, {"input_tokens": "x"}, {"input_tokens": -1}):
            class Message:
                pass
            Message.usage_metadata = usage
            assert _token_usage(Message()) == (None, None)
