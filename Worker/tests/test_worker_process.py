"""Process-level tests: the real protocol loop over actual pipes.

These tests launch the fixture worker entry (the real runtime with a
fixture model factory) as a child process. No network access occurs.
"""

from __future__ import annotations

import json
import time
import uuid

import pytest

from conftest import (
    A01_REQUEST_ID,
    B_ID,
    T01_REQUEST_ID,
    T01_UNIT_ID,
    WorkerClient,
    align_request_a01,
    translate_request_t01,
)


def handshake(client: WorkerClient) -> dict:
    client.send({"v": 2, "type": "hello"})
    ready = client.recv()
    assert ready["type"] == "ready"
    assert ready["v"] == 2
    assert ready["max_inflight"] == 4
    assert ready["prompt_versions"] == ["translation.v1", "translation.v2", "translation.markdown.v1", "alignment.v1"]
    assert isinstance(ready["worker_version"], str) and ready["worker_version"]
    return ready


class TestHandshake:
    def test_hello_ready(self, dev_fixture_worker):
        client = dev_fixture_worker()
        try:
            ready = handshake(client)
            assert ready["worker_version"] == "0.1.0"
            client.assert_no_frame()
        finally:
            client.shutdown()

    def test_first_frame_not_hello_is_fatal(self, dev_fixture_worker):
        client = dev_fixture_worker()
        try:
            client.send({"v": 2, "type": "shutdown"})
            fatal = client.recv()
            assert fatal == {"v": 2, "type": "fatal", "code": "incompatible_protocol"}
            assert client.wait() != 0
        finally:
            client.shutdown()

    def test_wrong_protocol_version_is_fatal(self, dev_fixture_worker):
        client = dev_fixture_worker()
        try:
            client.send({"v": 1, "type": "hello"})
            fatal = client.recv()
            assert fatal["code"] == "incompatible_protocol"
            assert client.wait() != 0
        finally:
            client.shutdown()

    def test_duplicate_hello_is_fatal(self, dev_fixture_worker):
        client = dev_fixture_worker()
        try:
            handshake(client)
            client.send({"v": 2, "type": "hello"})
            fatal = client.recv()
            assert fatal == {"v": 2, "type": "fatal", "code": "invalid_frame"}
            assert client.wait() != 0
        finally:
            client.shutdown()

    def test_eof_before_hello_emits_stopped(self, dev_fixture_worker):
        client = dev_fixture_worker()
        try:
            client.close_stdin()
            # Q1: EOF before hello is a normal EOF — exactly one stopped
            # acknowledgement, no ready, no fatal, normal exit.
            stopped = client.recv(timeout=5.0)
            assert stopped == {"v": 2, "type": "stopped"}
            assert client.wait(timeout=5.0) == 0
            client.assert_no_frame(0.2)
        finally:
            client.shutdown()


class TestFixtureOperations:
    def test_translate_round_trip_from_case_t01(self, dev_fixture_worker):
        client = dev_fixture_worker()
        try:
            handshake(client)
            client.send(translate_request_t01())
            result = client.recv()
            assert result["type"] == "result"
            assert result["id"] == T01_REQUEST_ID
            assert result["data"] == {
                "translations": [
                    {
                        "unit_id": T01_UNIT_ID,
                        "text": "Li Ming has not confirmed Friday's meeting.",
                    }
                ]
            }
            meta = result["meta"]
            assert meta["provider"] == "openai"
            assert meta["requested_model"] == "gpt-4.1-mini-2025-04-14"
            assert meta["returned_model"] is None
            assert meta["prompt_version"] == "translation.v1"
            assert meta["input_tokens"] is None and meta["output_tokens"] is None
            client.assert_no_frame()
        finally:
            client.shutdown()

    def test_align_round_trip_from_case_a01(self, dev_fixture_worker):
        client = dev_fixture_worker()
        try:
            handshake(client)
            client.send(align_request_a01())
            result = client.recv()
            assert result["type"] == "result"
            assert result["id"] == A01_REQUEST_ID
            assert result["data"] == {
                "status": "matched",
                "matches": [{"quote": "装罐", "occurrence": 1}],
                "reason": "none",
            }
            assert result["meta"]["prompt_version"] == "alignment.v1"
        finally:
            client.shutdown()

    def test_unknown_input_uses_deterministic_fallback(self, dev_fixture_worker):
        client = dev_fixture_worker()
        try:
            handshake(client)
            env = translate_request_t01()
            env["id"] = str(uuid.uuid4())
            env["input"]["units"][0]["text"] = "A synthetic transport sentence."
            client.send(env)
            result = client.recv()
            assert result["type"] == "result"
            text = result["data"]["translations"][0]["text"]
            assert text.startswith("[bipara-fixture:")
            assert text.endswith("A synthetic transport sentence.")
        finally:
            client.shutdown()

    def test_invalid_request_gets_typed_error(self, dev_fixture_worker):
        client = dev_fixture_worker()
        try:
            handshake(client)
            env = translate_request_t01()
            env["input"]["source_language"] = "fr"
            client.send(env)
            error = client.recv()
            assert error["type"] == "error"
            assert error["id"] == T01_REQUEST_ID
            assert error["code"] == "invalid_request"
            assert error["retry_after_ms"] is None
        finally:
            client.shutdown()

    def test_worker_error_code_passes_through(self, dev_fixture_worker):
        client = dev_fixture_worker("--fail", "rate_limited")
        try:
            handshake(client)
            client.send(translate_request_t01())
            error = client.recv()
            assert error["type"] == "error"
            assert error["code"] == "rate_limited"
        finally:
            client.shutdown()

    def test_out_of_order_completion(self, dev_fixture_worker):
        """A slow translate and a fast align complete out of order; the
        client correlates strictly by request ID."""

        client = dev_fixture_worker("--delay-translate", "0.8", "--delay-align", "0")
        try:
            handshake(client)
            slow = translate_request_t01()
            fast = align_request_a01()
            client.send(slow)
            client.send(fast)
            first = client.recv(timeout=5.0)
            second = client.recv(timeout=5.0)
            assert first["type"] == "result" and second["type"] == "result"
            # The align (zero delay) must win the race deterministically.
            assert first["id"] == fast["id"], "align should complete before the delayed translate"
            assert second["id"] == slow["id"]
        finally:
            client.shutdown()

    def test_byte_fragmented_utf8_frame_reassembles(self, dev_fixture_worker):
        """A frame written in small chunks, split inside a multi-byte UTF-8
        sequence, decodes as exactly one request (IPC-02 evidence)."""

        client = dev_fixture_worker()
        try:
            handshake(client)
            frame = json.dumps(translate_request_t01(), ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
            # Split inside the first multi-byte character (CJK text).
            split_at = frame.index("\u674e".encode("utf-8")) + 1  # mid-code-point
            assert split_at < len(frame)
            # Deterministic three-way split with a 1-byte overrun into CJK.
            parts = (frame[:split_at], frame[split_at:split_at + 10], frame[split_at + 10:])
            for part in parts:
                client.send_raw(part)
                time.sleep(0.05)
            result = client.recv(timeout=5.0)
            assert result["type"] == "result"
            assert result["id"] == T01_REQUEST_ID
        finally:
            client.shutdown()

    def test_concatenated_frames_in_one_write(self, dev_fixture_worker):
        """Two frames delivered in a single write both decode."""

        client = dev_fixture_worker()
        try:
            handshake(client)
            first = translate_request_t01()
            second = align_request_a01()
            blob = (
                json.dumps(first, ensure_ascii=False, separators=(",", ":")).encode()
                + b"\n"
                + json.dumps(second, ensure_ascii=False, separators=(",", ":")).encode()
                + b"\n"
            )
            client.send_raw(blob)
            ids = {client.recv(timeout=5.0)["id"], client.recv(timeout=5.0)["id"]}
            assert ids == {first["id"], second["id"]}
        finally:
            client.shutdown()


class TestCancellationAndDeadlines:
    def test_cancel_emits_single_cancelled_terminal(self, dev_fixture_worker):
        client = dev_fixture_worker("--delay", "5")
        try:
            handshake(client)
            client.send(translate_request_t01())
            time.sleep(0.3)  # let the request become active
            client.send({"v": 2, "type": "cancel", "id": T01_REQUEST_ID})
            cancelled = client.recv(timeout=3.0)
            assert cancelled == {"v": 2, "type": "cancelled", "id": T01_REQUEST_ID}
            client.assert_no_frame()
        finally:
            client.shutdown()

    def test_cancel_before_task_first_step_still_emits_once(self, dev_fixture_worker):
        """Request+cancel delivered back-to-back in one write: the task can
        be cancelled before its first step (no yield between spawn and
        cancel), and the cancelled terminal must still arrive exactly once
        (regression for the fast-cancel window)."""

        client = dev_fixture_worker("--delay", "1")
        try:
            handshake(client)
            blob = (
                json.dumps(translate_request_t01(), ensure_ascii=False, separators=(",", ":")).encode()
                + b"\n"
                + json.dumps({"v": 2, "type": "cancel", "id": T01_REQUEST_ID}).encode()
                + b"\n"
            )
            client.send_raw(blob)
            assert client.recv(timeout=3.0) == {
                "v": 2, "type": "cancelled", "id": T01_REQUEST_ID,
            }
            client.assert_no_frame()
        finally:
            client.shutdown()

    def test_cancel_after_terminal_is_ignored(self, dev_fixture_worker):
        client = dev_fixture_worker()
        try:
            handshake(client)
            client.send(translate_request_t01())
            assert client.recv()["type"] == "result"
            client.send({"v": 2, "type": "cancel", "id": T01_REQUEST_ID})
            client.assert_no_frame()
        finally:
            client.shutdown()

    def test_fifth_concurrent_request_is_busy(self, dev_fixture_worker):
        client = dev_fixture_worker("--delay", "5")
        try:
            handshake(client)
            for i in range(4):
                env = translate_request_t01()
                env["id"] = str(uuid.uuid4())
                client.send(env)
            fifth = translate_request_t01()
            fifth["id"] = str(uuid.uuid4())
            client.send(fifth)
            busy = client.recv(timeout=3.0)
            assert busy["type"] == "error"
            assert busy["code"] == "busy"
            assert busy["id"] == fifth["id"]
        finally:
            client.shutdown()

    def test_invocation_deadline_returns_timeout(self, dev_fixture_worker):
        client = dev_fixture_worker("--delay", "5", "--invocation-timeout", "0.3")
        try:
            handshake(client)
            client.send(translate_request_t01())
            error = client.recv(timeout=5.0)
            assert error["type"] == "error"
            assert error["code"] == "timeout"
            client.assert_no_frame()
        finally:
            client.shutdown()

    def test_cancelled_request_does_not_block_slot_forever(self, dev_fixture_worker):
        client = dev_fixture_worker("--delay", "2")
        try:
            handshake(client)
            client.send(translate_request_t01())
            time.sleep(0.2)
            client.send({"v": 2, "type": "cancel", "id": T01_REQUEST_ID})
            assert client.recv(timeout=3.0)["type"] == "cancelled"
            # Slot is free again: a new request is admitted and can be served.
            client.send(align_request_a01(str(uuid.uuid4())))
            assert client.recv(timeout=8.0)["type"] == "result"
        finally:
            client.shutdown()


class TestFatalFrames:
    def test_duplicate_request_id_is_fatal(self, dev_fixture_worker):
        client = dev_fixture_worker("--delay", "1")
        try:
            handshake(client)
            client.send(translate_request_t01())
            client.send(translate_request_t01())
            # Exit cleanup cancels the in-flight request before the fatal.
            cancelled = client.recv()
            assert cancelled == {"v": 2, "type": "cancelled", "id": T01_REQUEST_ID}
            fatal = client.recv()
            assert fatal == {"v": 2, "type": "fatal", "code": "invalid_frame"}
            assert client.wait() != 0
        finally:
            client.shutdown()

    def test_oversized_frame_is_fatal(self, dev_fixture_worker):
        client = dev_fixture_worker()
        try:
            handshake(client)
            client.send_raw(b'{"v":2,"type":"hello"}' + b" " * (1024 * 1024) + b"\n")
            fatal = client.recv(timeout=5.0)
            assert fatal["code"] == "invalid_frame"
            assert client.wait() != 0
        finally:
            client.shutdown()

    def test_duplicate_decoded_keys_are_fatal(self, dev_fixture_worker):
        client = dev_fixture_worker()
        try:
            handshake(client)
            client.send_raw(b'{"v":2,"type":"cancel","id":"x","id":"y"}\n')
            fatal = client.recv()
            assert fatal["code"] == "invalid_frame"
        finally:
            client.shutdown()

    def test_corrupt_json_is_fatal(self, dev_fixture_worker):
        client = dev_fixture_worker()
        try:
            handshake(client)
            client.send_raw(b'{"v":2,"type":"cancel"\n')
            fatal = client.recv()
            assert fatal["code"] == "invalid_frame"
            assert client.wait() != 0
        finally:
            client.shutdown()

    def test_surrogate_request_is_invalid_request_and_worker_survives(self, dev_fixture_worker):
        """S9: an escaped lone surrogate in a request body must produce a
        per-request invalid_request error. The worker must keep serving an
        in-flight request and never exit or leak the credential."""

        client = dev_fixture_worker("--delay-translate", "1.2")
        try:
            handshake(client)
            # Keep one real request in flight while the malformed one arrives.
            client.send(align_request_a01(B_ID))
            # Build the frame from a dict holding a real lone surrogate;
            # ensure_ascii escapes it as \ud800 inside valid UTF-8 ASCII.
            malformed_env = translate_request_t01()
            malformed_env["input"]["units"][0]["text"] = "\ud800broken"
            malformed = json.dumps(malformed_env, ensure_ascii=True, separators=(",", ":"))
            assert "\\ud800broken" in malformed
            client.send_raw(malformed.encode("ascii") + b"\n")
            # The zero-delay align result may precede the malformed
            # request's error; match by request ID.
            frames = {}
            for _ in range(2):
                frame = client.recv(timeout=5.0)
                frames[frame["id"]] = frame
            error = frames[T01_REQUEST_ID]
            assert error["type"] == "error"
            assert error["code"] == "invalid_request"
            # The unrelated in-flight request completed normally.
            result = frames[B_ID]
            assert result["type"] == "result"
            # Worker still healthy.
            client.send({"v": 2, "type": "shutdown"})
            assert client.recv() == {"v": 2, "type": "stopped"}
            assert client.wait() == 0
            assert "SYNTHETIC_TEST_CREDENTIAL" not in client.stderr_bytes().decode("utf-8", "replace")
        finally:
            client.shutdown()

    def test_non_object_frame_is_fatal(self, dev_fixture_worker):
        client = dev_fixture_worker()
        try:
            handshake(client)
            client.send_raw(b"[1,2,3]\n")
            fatal = client.recv()
            assert fatal["code"] == "invalid_frame"
        finally:
            client.shutdown()


class TestShutdown:
    def test_shutdown_cancels_active_and_stops(self, dev_fixture_worker):
        client = dev_fixture_worker("--delay", "5")
        try:
            handshake(client)
            client.send(translate_request_t01())
            time.sleep(0.2)
            client.send({"v": 2, "type": "shutdown"})
            first = client.recv(timeout=3.0)
            assert first == {"v": 2, "type": "cancelled", "id": T01_REQUEST_ID}
            stopped = client.recv(timeout=3.0)
            assert stopped == {"v": 2, "type": "stopped"}
            assert client.wait() == 0
            client.assert_no_frame(0.2)
        finally:
            client.shutdown()

    def test_eof_cancels_active_then_stopped(self, dev_fixture_worker):
        client = dev_fixture_worker("--delay", "5")
        try:
            handshake(client)
            client.send(translate_request_t01())
            time.sleep(0.2)
            client.close_stdin()
            # Q1: EOF has the same effect as shutdown — the active request
            # is cancelled, cleanup drains, then exactly one stopped event
            # is emitted before a normal exit.
            cancelled = client.recv(timeout=3.0)
            assert cancelled == {"v": 2, "type": "cancelled", "id": T01_REQUEST_ID}
            stopped = client.recv(timeout=3.0)
            assert stopped == {"v": 2, "type": "stopped"}
            assert client.wait(timeout=5.0) == 0
            client.assert_no_frame(0.2)
        finally:
            client.shutdown()

    def test_no_orphan_after_process_exit(self, dev_fixture_worker):
        client = dev_fixture_worker()
        try:
            handshake(client)
            client.send({"v": 2, "type": "shutdown"})
            assert client.recv() == {"v": 2, "type": "stopped"}
            assert client.wait() == 0
            # The child was reaped by wait(); nothing else may carry our argv.
            assert client.proc.poll() is not None
        finally:
            client.shutdown()
