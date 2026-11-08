"""Unit tests for the strict wire codec and request validation."""

from __future__ import annotations

import json
from typing import Any

import pytest

from bipara_worker.protocol import (
    MAX_INPUT_JSON_BYTES,
    FatalError,
    RequestError,
    check_cancel_frame,
    check_envelope_header,
    decode_frame,
    encode_frame,
    input_json_size,
    is_canonical_uuid,
    parse_request,
)

from conftest import SYNTHETIC_KEY, align_request_a01, translate_request_t01


class TestDecodeFrame:
    def test_valid_frame(self):
        env = decode_frame(b'{"v":2,"type":"hello"}\n')
        assert env == {"v": 2, "type": "hello"}

    def test_oversized_frame_is_fatal(self):
        line = b'{"type":"hello"} ' + b"x" * (1024 * 1024) + b"\n"
        with pytest.raises(FatalError) as exc:
            decode_frame(line)
        assert exc.value.code == "invalid_frame"

    def test_invalid_utf8_is_fatal(self):
        with pytest.raises(FatalError):
            decode_frame(b'{"type":"hello"}\xff\xfe\n')

    def test_corrupt_json_is_fatal(self):
        with pytest.raises(FatalError):
            decode_frame(b'{"type":"hello"\n')

    def test_empty_line_is_fatal(self):
        with pytest.raises(FatalError):
            decode_frame(b"\n")

    def test_two_objects_on_one_line_is_fatal(self):
        with pytest.raises(FatalError):
            decode_frame(b'{"type":"hello"}{"v":1}\n')

    def test_duplicate_keys_are_fatal(self):
        with pytest.raises(FatalError):
            decode_frame(b'{"v":2,"v":2,"type":"hello"}\n')

    def test_duplicate_escaped_alias_keys_are_fatal(self):
        # "type" and "\u0074ype" decode to the same key.
        with pytest.raises(FatalError):
            decode_frame(b'{"v":2,"type":"hello","\\u0074ype":"hello"}\n')

    def test_same_key_in_distinct_objects_is_valid(self):
        env = decode_frame(b'{"v":2,"type":"request","config":{"a":1},"input":{"a":2}}\n')
        assert env["config"]["a"] == 1 and env["input"]["a"] == 2

    def test_non_finite_numbers_are_fatal(self):
        with pytest.raises(FatalError):
            decode_frame(b'{"v":2,"type":"hello","x":NaN}\n')
        with pytest.raises(FatalError):
            decode_frame(b'{"v":2,"type":"hello","x":Infinity}\n')

    def test_exponent_overflow_to_infinity_is_fatal(self):
        # A legal numeric token that overflows to inf is non-finite too,
        # including inside ignored/forward-compatible envelope fields.
        with pytest.raises(FatalError) as exc:
            decode_frame(b'{"v":2,"type":"hello","metadata":1e999}\n')
        assert exc.value.code == "invalid_frame"
        with pytest.raises(FatalError):
            decode_frame(b'{"v":2,"type":"cancel","id":"x","nested":{"deep":[-1e999]}}\n')
        # Finite exponents still parse.
        assert decode_frame(b'{"v":2,"type":"hello","x":1e10}\n')["x"] == 1e10

    def test_unpaired_surrogate_request_text_is_invalid_request(self):
        env = translate_request_t01()
        env["input"]["units"][0]["text"] = "\ud800"
        with pytest.raises(RequestError):
            parse_request(env)

    def test_unpaired_surrogate_in_other_request_fields(self):
        surrogate_cases = [
            ("model", "\ud800model"),
            ("key", "\ud800"),
        ]
        env = translate_request_t01()
        env["config"]["model"] = "\ud800model"
        with pytest.raises(RequestError):
            parse_request(env)
        env = translate_request_t01()
        env["credentials"]["api_key"] = "\ud800"
        with pytest.raises(RequestError):
            parse_request(env)

    def test_input_json_size_rejects_surrogates(self):
        from bipara_worker.protocol import input_json_size

        with pytest.raises(RequestError):
            input_json_size({"x": "\ud800"})

    def test_escaped_newline_inside_string_is_data(self):
        env = decode_frame('{"v":2,"type":"hello","x":"a\\nb"}\n'.encode())
        assert env["x"] == "a\nb"


class TestEncodeFrame:
    def test_compact_and_lf_terminated(self):
        data = encode_frame({"v": 2, "type": "stopped"})
        assert data == b'{"v":2,"type":"stopped"}\n'

    def test_unicode_unescaped(self):
        data = encode_frame({"v": 2, "type": "x", "t": "窗"})
        assert "窗".encode("utf-8") in data and b"\\u" not in data

    def test_round_trip(self):
        env = {"v": 2, "type": "hello", "extra": {"n": 1.5, "s": "é"}}
        assert decode_frame(encode_frame(env)) == env


class TestEnvelopeHeader:
    def test_hello_ok(self):
        assert check_envelope_header({"v": 2, "type": "hello"}) == "hello"

    def test_protocol_one_frame_is_incompatible(self):
        # Protocol 2 rejects a protocol-1 peer before any credential.
        with pytest.raises(FatalError) as exc:
            check_envelope_header({"v": 1, "type": "hello"})
        assert exc.value.code == "incompatible_protocol"

    def test_missing_or_non_int_version_is_invalid(self):
        for bad in ({"type": "hello"}, {"v": "1", "type": "hello"}, {"v": True, "type": "hello"}, {"v": 1.0, "type": "hello"}):
            with pytest.raises(FatalError) as exc:
                check_envelope_header(bad)
            assert exc.value.code == "invalid_frame"

    def test_unknown_kind_is_invalid(self):
        with pytest.raises(FatalError):
            check_envelope_header({"v": 2, "type": "progress"})

    def test_extra_envelope_fields_ignored(self):
        assert check_envelope_header({"v": 2, "type": "shutdown", "meta": {"x": 1}}) == "shutdown"

    def test_non_object_is_invalid(self):
        with pytest.raises(FatalError):
            check_envelope_header([1, 2])

    def test_cancel_requires_string_id(self):
        assert check_cancel_frame({"v": 2, "type": "cancel", "id": "x"}) == "x"
        with pytest.raises(FatalError):
            check_cancel_frame({"v": 2, "type": "cancel", "id": 7})


class TestUUIDCheck:
    def test_canonical_accepted(self):
        assert is_canonical_uuid("11111111-1111-4111-8111-111111111111")

    def test_non_canonical_rejected(self):
        assert not is_canonical_uuid("11111111-1111-4111-8111-111111111111X")
        assert not is_canonical_uuid("111111111111411181111111111111111")
        assert not is_canonical_uuid("not-a-uuid")
        assert not is_canonical_uuid(123)
        assert not is_canonical_uuid(None)


class TestParseTranslateRequest:
    def test_valid(self):
        req = parse_request(translate_request_t01())
        assert req.id == "11111111-1111-4111-8111-111111111111"
        assert req.op == "translate"
        assert req.config.provider == "openai"
        assert req.config.profile == "openai-json-schema-v1"
        assert req.prompt_version == "translation.v1"
        assert req.input.units[0].text == "李明没有确认周五的会议。"

    def test_same_languages_rejected(self):
        env = translate_request_t01()
        env["input"]["source_language"] = "en"
        with pytest.raises(RequestError):
            parse_request(env)

    def test_unknown_language_rejected(self):
        env = translate_request_t01()
        env["input"]["source_language"] = "fr"
        with pytest.raises(RequestError):
            parse_request(env)

    def test_wrong_prompt_version_rejected(self):
        env = translate_request_t01()
        env["prompt_version"] = "alignment.v1"
        with pytest.raises(RequestError):
            parse_request(env)

    def test_profile_provider_mismatch_rejected(self):
        env = translate_request_t01()
        env["config"]["profile"] = "glm-json-v1"
        with pytest.raises(RequestError):
            parse_request(env)

    def test_empty_api_key_rejected(self):
        env = translate_request_t01()
        env["credentials"]["api_key"] = ""
        with pytest.raises(RequestError):
            parse_request(env)

    def test_extra_unit_field_rejected(self):
        env = translate_request_t01()
        env["input"]["units"][0]["note"] = "x"
        with pytest.raises(RequestError):
            parse_request(env)

    def test_duplicate_unit_ids_rejected(self):
        env = translate_request_t01()
        env["input"]["units"].append(dict(env["input"]["units"][0]))
        with pytest.raises(RequestError):
            parse_request(env)

    def test_untrimmed_unit_text_rejected(self):
        env = translate_request_t01()
        env["input"]["units"][0]["text"] = " padded "
        with pytest.raises(RequestError):
            parse_request(env)

    def test_empty_unit_text_rejected(self):
        env = translate_request_t01()
        env["input"]["units"][0]["text"] = ""
        with pytest.raises(RequestError):
            parse_request(env)

    def test_65_units_rejected(self):
        env = translate_request_t01()
        env["input"]["units"] = [
            {"unit_id": f"22222222-2222-4222-8222-{i:012d}", "kind": "sentence", "text": "词。"}
            for i in range(65)
        ]
        with pytest.raises(RequestError):
            parse_request(env)

    def test_batch_over_8192_bytes_rejected(self):
        env = translate_request_t01()
        long_text = "很长的句子。" * 1400  # ~9800 bytes
        env["input"]["units"][0]["text"] = long_text
        with pytest.raises(RequestError):
            parse_request(env)

    def test_context_over_512_bytes_rejected(self):
        env = translate_request_t01()
        env["input"]["context_before"] = "x" * 513
        with pytest.raises(RequestError):
            parse_request(env)

    def test_model_id_over_256_bytes_rejected(self):
        env = translate_request_t01()
        env["config"]["model"] = "m" * 257
        with pytest.raises(RequestError):
            parse_request(env)


class TestConfigEnvelopeRules:
    """Envelope-level config validation the protocol contract requires:
    unknown config fields, the canonical effort vocabulary, and legacy
    profile URL/effort exactness (protocol v2)."""

    def test_config_extra_field_rejected(self):
        env = translate_request_t01()
        env["config"]["temperature"] = 0.2
        with pytest.raises(RequestError):
            parse_request(env)

    def test_noncanonical_effort_rejected(self):
        env = translate_request_t01()
        env["config"]["effort"] = "ultra"
        with pytest.raises(RequestError):
            parse_request(env)

    def test_legacy_openai_profile_wrong_effort_rejected(self):
        env = translate_request_t01()
        env["config"]["effort"] = "low"
        with pytest.raises(RequestError):
            parse_request(env)

    def test_legacy_openai_profile_wrong_url_rejected(self):
        env = translate_request_t01()
        env["config"]["base_url"] = "https://gateway.example.com/v1/"
        with pytest.raises(RequestError):
            parse_request(env)

    def test_legacy_glm_profile_wrong_effort_rejected(self):
        env = align_request_a01()
        env["config"]["effort"] = "low"
        with pytest.raises(RequestError):
            parse_request(env)

    def test_legacy_glm_profile_wrong_url_rejected(self):
        env = align_request_a01()
        env["config"]["base_url"] = "https://open.bigmodel.cn/api/coding/paas/v4/"
        with pytest.raises(RequestError):
            parse_request(env)


class TestParseAlignRequest:
    def test_valid(self):
        req = parse_request(align_request_a01())
        assert req.op == "align"
        assert req.input.selection.text == "can"

    def test_selection_mismatch_rejected(self):
        env = align_request_a01()
        env["input"]["selection"]["after"] = " fruits."
        with pytest.raises(RequestError):
            parse_request(env)

    def test_empty_selection_rejected(self):
        env = align_request_a01()
        env["input"]["selection"]["text"] = ""
        env["input"]["selection"]["before"] = "I can can fruit."
        env["input"]["selection"]["after"] = ""
        with pytest.raises(RequestError):
            parse_request(env)


def test_synthetic_credential_marker_present():
    # The examples deliberately carry a synthetic credential, never a key format.
    assert SYNTHETIC_KEY.startswith("SYNTHETIC_")
    env = translate_request_t01()
    assert json.dumps(env).count(SYNTHETIC_KEY) == 1


class TestContractBoundaries:
    """Just below / at / above each byte cap."""

    def test_maximal_legal_input_stays_under_32kib(self):
        """The 32 KiB serialized-input cap is defensive: the per-field caps
        (8192 batch bytes, 64 units, 2x512 context) bound any legal request
        well below it. Pin that relationship."""

        env = translate_request_t01()
        env["input"]["context_before"] = "x" * 512
        env["input"]["context_after"] = "x" * 512
        env["input"]["units"] = [
            {"unit_id": f"22222222-2222-4222-8222-{i:012d}", "kind": "sentence", "text": "词" * 32}
            for i in range(64)
        ]
        assert parse_request(env) is not None
        assert input_json_size(env["input"]) <= MAX_INPUT_JSON_BYTES

    def test_align_texts_over_8kib_rejected(self):
        env = align_request_a01()
        env["input"]["reading_text"] = "a" * 4096
        env["input"]["counterpart_text"] = "b" * 4097
        with pytest.raises(RequestError):
            parse_request(env)

    def test_align_texts_at_8kib_accepted(self):
        env = align_request_a01()
        env["input"]["reading_text"] = "a" * 4095
        env["input"]["counterpart_text"] = "b" * 4097
        env["input"]["selection"] = {"before": "a" * 100, "text": "a", "after": "a" * 3994}
        assert parse_request(env) is not None

    def test_selection_over_512_bytes_rejected(self):
        env = align_request_a01()
        env["input"]["selection"] = {
            "before": "", "text": "c" * 513, "after": "",
        }
        env["input"]["reading_text"] = "c" * 513
        env["input"]["counterpart_text"] = "x"
        with pytest.raises(RequestError):
            parse_request(env)

    def test_api_key_over_4096_bytes_rejected(self):
        env = translate_request_t01()
        env["credentials"]["api_key"] = "k" * 4097
        with pytest.raises(RequestError):
            parse_request(env)

    def test_api_key_at_4096_bytes_accepted(self):
        env = translate_request_t01()
        env["credentials"]["api_key"] = "k" * 4096
        assert parse_request(env) is not None

    def test_unit_text_with_cr_rejected(self):
        env = translate_request_t01()
        env["input"]["units"][0]["text"] = "line\rbreak"
        with pytest.raises(RequestError):
            parse_request(env)

    def test_unit_text_with_lf_rejected(self):
        env = translate_request_t01()
        env["input"]["units"][0]["text"] = "line\nbreak"
        with pytest.raises(RequestError):
            parse_request(env)


class TestBaseURLValidation:
    """The wire-side canonical Base URL rules, exercised through parse_request."""

    @staticmethod
    def _envelope(base_url: Any) -> dict[str, Any]:
        env = translate_request_t01()
        env["config"]["profile"] = "openai-json-schema-v2"
        env["config"]["base_url"] = base_url
        return env

    @pytest.mark.parametrize(
        "base_url",
        [
            "https://api.openai.com/v1/",
            "https://open.bigmodel.cn/api/paas/v4/",
            "https://gateway.example.com:8443/team%2Fname/v1/",
            "https://gateway.example.com/a%20b/v1/",
        ],
    )
    def test_valid_base_url_accepted(self, base_url: str):
        request = parse_request(self._envelope(base_url))
        assert request.config.base_url == base_url

    @pytest.mark.parametrize(
        "base_url",
        [
            "http://api.openai.com/v1/",
            "https:///v1/",
            "https://user:pw@api.openai.com/v1/",
            "https://api.openai.com/v1/?x=1",
            "https://api.openai.com/v1/#f",
            "https://api.openai.com/v1/ path",
            "https://api.openai.com/v1/\tpath",
            "https://api.openai.com:abc/v1/",
            "https://api.openai.com/v1/chat/completions",
            "https://open.bigmodel.cn/api/paas/v4/responses",
            "https://gateway.example.com/api/messages",
        ],
        ids=[
            "non-https-scheme",
            "missing-host",
            "userinfo",
            "query",
            "fragment",
            "literal-space",
            "literal-tab",
            "invalid-port",
            "chat-completions-suffix",
            "responses-suffix",
            "messages-suffix",
        ],
    )
    def test_rejected_base_url(self, base_url: str):
        with pytest.raises(RequestError):
            parse_request(self._envelope(base_url))

    def test_empty_base_url_rejected(self):
        with pytest.raises(RequestError):
            parse_request(self._envelope(""))

    def test_base_url_over_2048_bytes_rejected(self):
        base_url = "https://example.com/" + "a" * 2029  # 2049 bytes
        with pytest.raises(RequestError):
            parse_request(self._envelope(base_url))

    def test_rejects_malformed_percent_encoding(self):
        # Agrees with the Swift raw-string rule: a bare/truncated % or a
        # percent-encoded host is rejected, never silently retyped.
        for bad in (
            "https://h.com/a%zz/",
            "https://h.com/a%2/",
            "https://h.com/a%",
            "https://exa%2Fmple.com/v1/",
        ):
            env = translate_request_t01()
            env["config"]["profile"] = "openai-json-schema-v2"
            env["config"]["base_url"] = bad
            with pytest.raises(RequestError):
                parse_request(env)

    def test_operation_suffix_trailing_slashes_rejected(self):
        # Mirrors the Swift rule: permitted trailing-slash normalization
        # must not bypass operation-suffix rejection.
        for suffix in ("/chat/completions", "/responses", "/messages"):
            for trailing in ("", "/", "//", "///"):
                env = translate_request_t01()
                env["config"]["profile"] = "openai-json-schema-v2"
                env["config"]["base_url"] = f"https://api.example.com/v1{suffix}{trailing}"
                with pytest.raises(RequestError):
                    parse_request(env)

    def test_empty_and_nonempty_query_fragment_rejected(self):
        for bad in (
            "https://api.example.com/v1/?",
            "https://api.example.com/v1/#",
            "https://api.example.com/v1/?x=1",
            "https://api.example.com/v1/#f",
            "https://api.example.com/v1/?#",
        ):
            env = translate_request_t01()
            env["config"]["profile"] = "openai-json-schema-v2"
            env["config"]["base_url"] = bad
            with pytest.raises(RequestError):
                parse_request(env)

    def test_port_range_validation_matches_swift(self):
        rejected = (
            "https://api.example.com:65536/v1/",
            "https://api.example.com:0/v1/",
            "https://api.example.com:abc/v1/",
        )
        accepted = (
            "https://api.example.com:65535/v1/",
            "https://api.example.com:8443/v1/",
        )
        for bad in rejected:
            env = translate_request_t01()
            env["config"]["profile"] = "openai-json-schema-v2"
            env["config"]["base_url"] = bad
            with pytest.raises(RequestError):
                parse_request(env)
        for good in accepted:
            env = translate_request_t01()
            env["config"]["profile"] = "openai-json-schema-v2"
            env["config"]["base_url"] = good
            assert parse_request(env) is not None

    def test_non_string_base_url_rejected(self):
        with pytest.raises(RequestError):
            parse_request(self._envelope(5))
