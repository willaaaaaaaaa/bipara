"""Deterministic in-process serve() tests for cancellation semantics.

Interleavings are synchronized with asyncio Events, never sleeps: the
tests below prove a control frame was *processed* while a request's
cleanup was still pending by observing a frame that only the processing
of that control frame can produce (a hanging second request's cancelled
terminal, or a fresh request's result) before releasing the cleanup
barrier. Teardown always releases barriers, closes stdin, and reaps the
server task so a failing assertion cannot leave hanging tasks or pipes.
"""

from __future__ import annotations

import asyncio
import json
import os
import queue
import threading

import pytest

from bipara_worker.runtime import serve

A_ID = "11111111-1111-4111-8111-111111111111"
B_ID = "22222222-2222-4222-8222-222222222222"
C_ID = "33333333-3333-4333-8333-333333333333"
D_ID = "44444444-4444-4444-8444-444444444444"
UNIT_ID = "55555555-5555-4555-8555-555555555555"

HELLO = {"v": 2, "type": "hello"}
CANCEL_A = {"v": 2, "type": "cancel", "id": A_ID}
SHUTDOWN = {"v": 2, "type": "shutdown"}


def translate_request(request_id: str, unit_text: str = "Hello there.") -> dict:
    return {
        "v": 2, "type": "request", "id": request_id, "op": "translate",
        "config": {"provider": "openai", "model": "gpt-4.1-mini-2025-04-14",
                   "profile": "openai-json-schema-v1",
                   "base_url": "https://api.openai.com/v1/", "effort": "auto"},
        "credentials": {"api_key": "SYNTHETIC_TEST_CREDENTIAL"},
        "prompt_version": "translation.v1",
        "input": {
            "source_language": "en", "target_language": "zh",
            "context_before": "", "context_after": "",
            "units": [{"unit_id": UNIT_ID, "kind": "sentence", "text": unit_text}],
        },
    }


def meta_for(request_id: str) -> dict:
    return {
        "provider": "openai", "requested_model": "gpt-4.1-mini-2025-04-14",
        "requested_effort": "auto", "returned_model": None,
        "prompt_version": "translation.v1",
        "input_tokens": None, "output_tokens": None,
    }


class PipeWorker:
    """Frame client over the serve() test pipe fds."""

    def __init__(self) -> None:
        self.stdin_read, self.stdin_write = os.pipe()
        self.stdout_read, self.stdout_write = os.pipe()
        self.frames: queue.Queue[dict | None] = queue.Queue()
        self.pending: list[dict] = []
        self._open = True
        self._thread = threading.Thread(target=self._drain, daemon=True)
        self._thread.start()

    def _drain(self) -> None:
        while True:
            chunk = os.read(self.stdout_read, 65536)
            if not chunk:
                self.frames.put(None)
                return
            for line in chunk.split(b"\n"):
                if line:
                    self.frames.put(json.loads(line))

    def send(self, *envelopes: dict) -> None:
        blob = b"".join((json.dumps(e, separators=(",", ":")) + "\n").encode() for e in envelopes)
        os.write(self.stdin_write, blob)

    def send_raw(self, data: bytes) -> None:
        os.write(self.stdin_write, data)

    async def recv(self, timeout: float = 5.0) -> dict:
        # Blocking queue access runs off the event loop so serve() keeps
        # running while the test waits for a frame.
        frame = await asyncio.to_thread(self.frames.get, True, timeout)
        assert frame is not None, "worker stdout closed unexpectedly"
        return frame

    async def recv_terminal(self, request_id: str, timeout: float = 5.0) -> dict:
        """Next terminal frame for the request, skipping unrelated frames."""
        for index, frame in enumerate(self.pending):
            if frame.get("id") == request_id and frame.get("type") in ("result", "error", "cancelled"):
                return self.pending.pop(index)
        while True:
            frame = await self.recv(timeout)
            if frame.get("id") == request_id and frame.get("type") in ("result", "error", "cancelled"):
                return frame
            self.pending.append(frame)

    async def expect_silence(self, timeout: float = 0.25) -> None:
        try:
            frame = await asyncio.to_thread(self.frames.get, True, timeout)
        except queue.Empty:
            return
        assert frame is not None, "worker stdout closed unexpectedly"
        raise AssertionError(f"unexpected frame during silence window: {frame}")

    def close_stdin(self) -> None:
        if self._open:
            self._open = False
            os.close(self.stdin_write)

    def dispose(self) -> None:
        self.close_stdin()
        for fd in (self.stdout_read, self.stdout_write, self.stdin_read):
            try:
                os.close(fd)
            except OSError:
                pass


async def reap(server: asyncio.Task, timeout: float = 10.0) -> int | None:
    """Bounded reap that cancels a stuck server instead of hanging."""
    try:
        return await asyncio.wait_for(server, timeout)
    except (asyncio.TimeoutError, asyncio.CancelledError):
        server.cancel()
        with_suppression = await asyncio.gather(server, return_exceptions=True)
        return None


class Draining:
    """Event-synchronized operation with interrupt-detecting async cleanup.

    The first cancellation starts cleanup on a test-held barrier; a SECOND
    CancelledError during cleanup would abort it and is recorded in
    ``cleanup_interrupted`` — the flag the R1 regressions assert stays
    False.
    """

    def __init__(self) -> None:
        self.started = asyncio.Event()
        self.cleanup_started = asyncio.Event()
        self.cleanup_release = asyncio.Event()
        self.ran = False
        self.cleanup_done = False
        self.cleanup_interrupted = False

    async def operation(self, request):
        self.ran = True
        self.started.set()
        try:
            await asyncio.Event().wait()  # hang until cancelled
        except asyncio.CancelledError:
            self.cleanup_started.set()
            try:
                await self.cleanup_release.wait()  # bounded, test-controlled
            except asyncio.CancelledError:
                self.cleanup_interrupted = True
                raise
            self.cleanup_done = True
            raise

    def release(self) -> None:
        self.cleanup_release.set()


class Hanging:
    """Operation that simply hangs until cancelled (no cleanup phase)."""

    def __init__(self) -> None:
        self.started = asyncio.Event()
        self.ran = False

    async def operation(self, request):
        self.ran = True
        self.started.set()
        await asyncio.Event().wait()


class QuickResult:
    def __init__(self) -> None:
        self.calls: list[str] = []

    async def operation(self, request):
        self.calls.append(request.id)
        return {"translations": [{"unit_id": UNIT_ID, "text": "你好。"}]}, meta_for(request.id)


async def start_server(worker: PipeWorker, operation) -> asyncio.Task:
    return asyncio.create_task(
        serve(operation, stdin_fileno=worker.stdin_read, stdout_fileno=worker.stdout_write)
    )


@pytest.mark.asyncio
async def test_cancelled_terminal_waits_for_async_cleanup():
    """S4: the cancelled terminal is emitted only after the operation's
    asynchronous cancellation cleanup fully drains, and a replacement
    request sent after that terminal is admitted (never busy)."""
    worker = PipeWorker()
    a = Draining()
    b = Hanging()

    async def operation(request):
        if request.id == A_ID:
            return await a.operation(request)
        if request.id == B_ID:
            return await b.operation(request)
        return {"translations": [{"unit_id": UNIT_ID, "text": "替换。"}]}, meta_for(request.id)

    server = await start_server(worker, operation)
    try:
        worker.send(HELLO)
        assert (await worker.recv())["type"] == "ready"
        worker.send(translate_request(A_ID))
        await a.started.wait()
        worker.send(translate_request(B_ID))
        await b.started.wait()

        worker.send(CANCEL_A)
        await a.cleanup_started.wait()  # A is in async cleanup; task not done
        await worker.expect_silence()  # no cancelled terminal before physical drain
        assert a.cleanup_done is False

        a.release()  # drain completes now
        cancelled = await worker.recv_terminal(A_ID)
        assert cancelled == {"v": 2, "type": "cancelled", "id": A_ID}
        assert a.cleanup_done is True  # terminal strictly after drain

        # Replacement admitted after the terminal: the freed slot is visible.
        worker.send(translate_request(C_ID))
        result = await worker.recv_terminal(C_ID)
        assert result["type"] == "result"
        assert result["data"]["translations"][0]["text"] == "替换。"

        worker.send(SHUTDOWN)
        # Shutdown cancels the still-hanging B first, then emits stopped.
        assert (await worker.recv_terminal(B_ID))["type"] == "cancelled"
        assert (await worker.recv())["type"] == "stopped"
        assert await reap(server) == 0
        # Exactly one terminal for A across the whole run.
        await worker.expect_silence()
        assert worker.frames.empty()
    finally:
        a.release()
        worker.dispose()
        await reap(server)


@pytest.mark.asyncio
async def test_repeated_explicit_cancel_does_not_interrupt_cleanup():
    """R1: a second explicit cancel arriving while A's cleanup is still
    draining must be a no-op, not a second CancelledError into cleanup.

    Determinism: after the second cancel frame, a fresh request D is sent
    in the same write; its result proves the server processed BOTH frames
    while A's cleanup was still pending (D runs in the free second slot).
    """
    worker = PipeWorker()
    a = Draining()
    quick = QuickResult()

    async def operation(request):
        if request.id == A_ID:
            return await a.operation(request)
        return await quick.operation(request)

    server = await start_server(worker, operation)
    try:
        worker.send(HELLO)
        assert (await worker.recv())["type"] == "ready"
        worker.send(translate_request(A_ID))
        await a.started.wait()
        assert a.cleanup_started.is_set() is False

        worker.send(CANCEL_A)
        await a.cleanup_started.wait()  # first cancel is draining
        # Second cancel + fresh request D, processed in order while the
        # cleanup barrier is still closed.
        worker.send(CANCEL_A, translate_request(D_ID))
        d_result = await worker.recv_terminal(D_ID)
        assert d_result["type"] == "result"  # both frames processed
        assert a.cleanup_done is False and a.cleanup_interrupted is False

        a.release()
        cancelled = await worker.recv_terminal(A_ID)
        assert cancelled == {"v": 2, "type": "cancelled", "id": A_ID}
        assert a.cleanup_interrupted is False  # R1: cleanup was never aborted
        assert a.cleanup_done is True

        worker.send(SHUTDOWN)
        assert (await worker.recv())["type"] == "stopped"
        assert await reap(server) == 0
        await worker.expect_silence()
    finally:
        a.release()
        worker.dispose()
        await reap(server)


@pytest.mark.asyncio
async def test_shutdown_while_cleanup_pending_does_not_interrupt():
    """R1: exit-path cancellation must not abort a draining cleanup.

    Determinism: with hanging B active, the shutdown frame's processing
    provably begins while A's cleanup is pending — cancelling B emits
    cancelled(B), which only the exit path can produce — before A's
    barrier is released.
    """
    worker = PipeWorker()
    a = Draining()
    b = Hanging()

    async def operation(request):
        if request.id == A_ID:
            return await a.operation(request)
        return await b.operation(request)

    server = await start_server(worker, operation)
    try:
        worker.send(HELLO)
        assert (await worker.recv())["type"] == "ready"
        worker.send(translate_request(A_ID), translate_request(B_ID))
        await a.started.wait()
        await b.started.wait()
        worker.send(CANCEL_A)
        await a.cleanup_started.wait()

        worker.send(SHUTDOWN)
        # Proof the exit path ran while A's cleanup was still pending.
        assert (await worker.recv_terminal(B_ID))["type"] == "cancelled"
        assert a.cleanup_done is False and a.cleanup_interrupted is False

        a.release()
        cancelled = await worker.recv_terminal(A_ID)
        assert cancelled["type"] == "cancelled"
        assert a.cleanup_interrupted is False  # R1: exit cancel was idempotent
        assert a.cleanup_done is True
        assert (await worker.recv())["type"] == "stopped"
        assert await reap(server) == 0
    finally:
        a.release()
        worker.dispose()
        await reap(server)


@pytest.mark.asyncio
async def test_eof_while_cleanup_pending_drains_then_stopped():
    """R1 + Q1: EOF exit has the same normal-cleanup semantics as shutdown —
    draining cleanup is not interrupted, and stopped follows it."""
    worker = PipeWorker()
    a = Draining()
    b = Hanging()

    async def operation(request):
        if request.id == A_ID:
            return await a.operation(request)
        return await b.operation(request)

    server = await start_server(worker, operation)
    try:
        worker.send(HELLO)
        assert (await worker.recv())["type"] == "ready"
        worker.send(translate_request(A_ID), translate_request(B_ID))
        await a.started.wait()
        await b.started.wait()
        worker.send(CANCEL_A)
        await a.cleanup_started.wait()

        worker.close_stdin()  # EOF
        assert (await worker.recv_terminal(B_ID))["type"] == "cancelled"
        assert a.cleanup_done is False and a.cleanup_interrupted is False

        a.release()
        cancelled = await worker.recv_terminal(A_ID)
        assert cancelled["type"] == "cancelled"
        assert a.cleanup_interrupted is False
        assert a.cleanup_done is True
        assert (await worker.recv())["type"] == "stopped"  # Q1
        assert await reap(server) == 0
    finally:
        a.release()
        worker.dispose()
        await reap(server)


@pytest.mark.asyncio
async def test_fatal_cleanup_does_not_interrupt_pending_cleanup():
    """R1: the fatal exit path also cancels idempotently, keeps fatal (no
    normal stopped), and exits nonzero."""
    worker = PipeWorker()
    a = Draining()
    b = Hanging()

    async def operation(request):
        if request.id == A_ID:
            return await a.operation(request)
        return await b.operation(request)

    server = await start_server(worker, operation)
    try:
        worker.send(HELLO)
        assert (await worker.recv())["type"] == "ready"
        worker.send(translate_request(A_ID), translate_request(B_ID))
        await a.started.wait()
        await b.started.wait()
        worker.send(CANCEL_A)
        await a.cleanup_started.wait()

        worker.send_raw(b'{"v":2,"type":\n')  # corrupt LF-terminated frame → fatal
        assert (await worker.recv_terminal(B_ID))["type"] == "cancelled"
        assert a.cleanup_done is False and a.cleanup_interrupted is False

        a.release()
        cancelled = await worker.recv_terminal(A_ID)
        assert cancelled["type"] == "cancelled"
        assert a.cleanup_interrupted is False
        assert a.cleanup_done is True
        fatal = await worker.recv()
        assert fatal == {"v": 2, "type": "fatal", "code": "invalid_frame"}
        await worker.expect_silence()  # no stopped after fatal
        assert await reap(server) == 1
    finally:
        a.release()
        worker.dispose()
        await reap(server)


@pytest.mark.asyncio
async def test_cancel_before_first_step_emits_exactly_once():
    """Request+cancel delivered back-to-back: the task never runs, yet
    exactly one cancelled terminal is emitted (from the done callback)."""
    worker = PipeWorker()
    op = QuickResult()

    server = await start_server(worker, op.operation)
    try:
        worker.send(HELLO)
        assert (await worker.recv())["type"] == "ready"
        worker.send(translate_request(A_ID), CANCEL_A)
        cancelled = await worker.recv_terminal(A_ID)
        assert cancelled == {"v": 2, "type": "cancelled", "id": A_ID}
        assert op.calls == []  # the operation body never executed
        await worker.expect_silence()

        worker.send(SHUTDOWN)
        assert (await worker.recv())["type"] == "stopped"
        assert await reap(server) == 0
    finally:
        worker.dispose()
        await reap(server)


@pytest.mark.asyncio
async def test_cancel_after_completion_has_no_second_terminal():
    """Completion race: cancel arriving after the result wins nothing."""
    worker = PipeWorker()
    op = QuickResult()

    server = await start_server(worker, op.operation)
    try:
        worker.send(HELLO)
        assert (await worker.recv())["type"] == "ready"
        worker.send(translate_request(A_ID))
        result = await worker.recv_terminal(A_ID)
        assert result["type"] == "result"

        worker.send(CANCEL_A)
        await worker.expect_silence()  # no duplicate terminal for an already-terminal ID

        worker.send(translate_request(B_ID))
        assert (await worker.recv_terminal(B_ID))["type"] == "result"
        worker.send(SHUTDOWN)
        assert (await worker.recv())["type"] == "stopped"
        assert await reap(server) == 0
    finally:
        worker.dispose()
        await reap(server)


@pytest.mark.asyncio
@pytest.mark.parametrize(
    ("status", "provider_code", "response_code", "validation_reason", "error_code"),
    [
        (401, "1001", "1001", None, "authentication"),
        (429, "1309", "1309", None, "rate_limited"),
        (400, "SYNTHETIC_TEST_CREDENTIAL", None, None, "invalid_request"),
        (400, "source_canary_sentence", None, None, "invalid_request"),
        (200, None, None, "invalid_json", "invalid_output"),
        (200, None, None, "translation_shape", "invalid_output"),
        (200, None, None, "unit_mismatch", "invalid_output"),
    ],
)
async def test_safe_diagnostics_reach_terminal_frame(
    status, provider_code, response_code, validation_reason, error_code, capfd, caplog
):
    import httpx
    from bipara_worker.assets import load_assets
    from bipara_worker.models import make_langchain_operation

    source = "source_canary_sentence"
    secret = "SYNTHETIC_TEST_CREDENTIAL"
    calls = 0

    def response(request):
        nonlocal calls
        calls += 1
        if status != 200:
            return httpx.Response(
                status, json={"error": {"code": provider_code, "message": f"{source} {secret}"}}
            )
        content = {
            "invalid_json": f"{source} {secret}",
            "translation_shape": json.dumps({"unexpected": f"{source} {secret}"}),
            "unit_mismatch": json.dumps({"translations": [{"unit_id": source, "text": secret}]}),
        }[validation_reason]
        return httpx.Response(200, json={
            "id": "synthetic",
            "model": "glm-5.3-flash",
            "choices": [{
                "index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop",
            }],
        })

    worker = PipeWorker()
    async with httpx.AsyncClient(transport=httpx.MockTransport(response), trust_env=False) as http:
        operation, _ = make_langchain_operation(load_assets(), http)
        server = await start_server(worker, operation)
        try:
            frame = translate_request(A_ID, source)
            frame["config"] = {
                "provider": "glm", "model": "glm-5.3-flash", "profile": "glm-json-v2",
                "base_url": "https://open.bigmodel.cn/api/coding/paas/v4/", "effort": "low",
            }
            worker.send(HELLO, frame)
            terminal = await worker.recv_terminal(A_ID)
            output = capfd.readouterr()
            for diagnostic in (json.dumps(terminal), output.out, output.err, caplog.text):
                assert secret not in diagnostic
                assert source not in diagnostic
            assert calls == 1
            assert terminal["type"] == "error"
            assert terminal["code"] == error_code
            assert terminal.get("http_status") == (status if status != 200 else None)
            assert terminal.get("provider_code") == response_code
            assert terminal.get("validation_reason") == validation_reason
        finally:
            worker.send(SHUTDOWN)
            await reap(server)
            worker.dispose()
