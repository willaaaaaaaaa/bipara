"""Deterministic in-process tests crossing the invocation deadline.

The deadline is injected short (0.4 s) through serve()'s test-only
``invocation_timeout`` — the production constant stays 120 s. Ordering is
established by Events (cleanup_started proves the drain began before the
deadline crossing; a hanging request's cancelled terminal proves exit
processing began while the barrier was closed). The wall-clock sleeps
only advance time past the original deadline — a deadline that no longer
exists as a frame source in the repaired runtime — and the silence window
asserts nothing leaked. Teardown releases barriers and reaps the server
so failures cannot hang.
"""

from __future__ import annotations

import asyncio

import pytest

from bipara_worker.runtime import serve

from test_serve_async import (
    A_ID,
    B_ID,
    C_ID,
    HELLO,
    SHUTDOWN,
    CANCEL_A,
    Draining,
    Hanging,
    QuickResult,
    PipeWorker,
    reap,
    translate_request,
)

DEADLINE = 0.4  # seconds; injected, never the production 120
CROSS_MARGIN = 0.15  # sleep past the deadline by this much


async def _cross_deadline(deadline_at: float) -> None:
    """Advance real time past the injected deadline (ordering already
    established by Events; this only crosses the wall clock)."""

    remaining = deadline_at + CROSS_MARGIN - asyncio.get_running_loop().time()
    if remaining > 0:
        await asyncio.sleep(remaining)


@pytest.mark.asyncio
async def test_deadline_does_not_interrupt_pending_cleanup_while_serving():
    """Explicit cancel starts the drain; the still-armed invocation timer
    must never fire into that drain. The worker keeps serving afterwards."""
    worker = PipeWorker()
    a = Draining()
    quick = QuickResult()

    async def operation(request):
        if request.id == A_ID:
            return await a.operation(request)
        return await quick.operation(request)

    server = asyncio.create_task(serve(
        operation, invocation_timeout=DEADLINE,
        stdin_fileno=worker.stdin_read, stdout_fileno=worker.stdout_write,
    ))
    try:
        worker.send(HELLO)
        assert (await worker.recv())["type"] == "ready"
        deadline_at = asyncio.get_running_loop().time() + DEADLINE

        worker.send(translate_request(A_ID))
        await a.started.wait()
        worker.send(CANCEL_A)
        await a.cleanup_started.wait()  # drain began before the deadline crossing
        assert a.cleanup_done is False

        await _cross_deadline(deadline_at)
        await worker.expect_silence()  # no premature terminal from the timer
        assert a.cleanup_interrupted is False

        a.release()
        cancelled = await worker.recv_terminal(A_ID)
        assert cancelled == {"v": 2, "type": "cancelled", "id": A_ID}
        assert a.cleanup_done is True
        assert a.cleanup_interrupted is False

        # Another request remains usable after the arbitration.
        worker.send(translate_request(C_ID))
        assert (await worker.recv_terminal(C_ID))["type"] == "result"

        worker.send(SHUTDOWN)
        assert (await worker.recv())["type"] == "stopped"
        assert await reap(server) == 0
    finally:
        a.release()
        worker.dispose()
        await reap(server)


@pytest.mark.asyncio
async def test_deadline_does_not_interrupt_pending_cleanup_before_shutdown():
    worker = PipeWorker()
    a = Draining()
    b = Hanging()

    async def operation(request):
        if request.id == A_ID:
            return await a.operation(request)
        return await b.operation(request)

    server = asyncio.create_task(serve(
        operation, invocation_timeout=DEADLINE,
        stdin_fileno=worker.stdin_read, stdout_fileno=worker.stdout_write,
    ))
    try:
        worker.send(HELLO)
        assert (await worker.recv())["type"] == "ready"
        deadline_at = asyncio.get_running_loop().time() + DEADLINE

        worker.send(translate_request(A_ID), translate_request(B_ID))
        await a.started.wait()
        await b.started.wait()
        worker.send(CANCEL_A)
        await a.cleanup_started.wait()

        worker.send(SHUTDOWN)
        # cancelled(B) proves exit processing began while A's barrier was closed.
        assert (await worker.recv_terminal(B_ID))["type"] == "cancelled"

        await _cross_deadline(deadline_at)
        assert a.cleanup_interrupted is False

        a.release()
        assert (await worker.recv_terminal(A_ID))["type"] == "cancelled"
        assert a.cleanup_done is True and a.cleanup_interrupted is False
        assert (await worker.recv())["type"] == "stopped"
        assert await reap(server) == 0
    finally:
        a.release()
        worker.dispose()
        await reap(server)


@pytest.mark.asyncio
async def test_deadline_does_not_interrupt_pending_cleanup_before_eof():
    worker = PipeWorker()
    a = Draining()
    b = Hanging()

    async def operation(request):
        if request.id == A_ID:
            return await a.operation(request)
        return await b.operation(request)

    server = asyncio.create_task(serve(
        operation, invocation_timeout=DEADLINE,
        stdin_fileno=worker.stdin_read, stdout_fileno=worker.stdout_write,
    ))
    try:
        worker.send(HELLO)
        assert (await worker.recv())["type"] == "ready"
        deadline_at = asyncio.get_running_loop().time() + DEADLINE

        worker.send(translate_request(A_ID), translate_request(B_ID))
        await a.started.wait()
        await b.started.wait()
        worker.send(CANCEL_A)
        await a.cleanup_started.wait()

        worker.close_stdin()
        assert (await worker.recv_terminal(B_ID))["type"] == "cancelled"

        await _cross_deadline(deadline_at)
        assert a.cleanup_interrupted is False

        a.release()
        assert (await worker.recv_terminal(A_ID))["type"] == "cancelled"
        assert a.cleanup_done is True and a.cleanup_interrupted is False
        assert (await worker.recv())["type"] == "stopped"  # Q1: EOF path
        assert await reap(server) == 0
    finally:
        a.release()
        worker.dispose()
        await reap(server)


@pytest.mark.asyncio
async def test_deadline_does_not_interrupt_pending_cleanup_before_fatal():
    worker = PipeWorker()
    a = Draining()
    b = Hanging()

    async def operation(request):
        if request.id == A_ID:
            return await a.operation(request)
        return await b.operation(request)

    server = asyncio.create_task(serve(
        operation, invocation_timeout=DEADLINE,
        stdin_fileno=worker.stdin_read, stdout_fileno=worker.stdout_write,
    ))
    try:
        worker.send(HELLO)
        assert (await worker.recv())["type"] == "ready"
        deadline_at = asyncio.get_running_loop().time() + DEADLINE

        worker.send(translate_request(A_ID), translate_request(B_ID))
        await a.started.wait()
        await b.started.wait()
        worker.send(CANCEL_A)
        await a.cleanup_started.wait()

        worker.send_raw(b'{"v":2,"type":\n')  # corrupt frame -> fatal
        assert (await worker.recv_terminal(B_ID))["type"] == "cancelled"

        await _cross_deadline(deadline_at)
        assert a.cleanup_interrupted is False

        a.release()
        assert (await worker.recv_terminal(A_ID))["type"] == "cancelled"
        assert a.cleanup_done is True and a.cleanup_interrupted is False
        fatal = await worker.recv()
        assert fatal == {"v": 2, "type": "fatal", "code": "invalid_frame"}
        await worker.expect_silence()  # no stopped after fatal
        assert await reap(server) == 1
    finally:
        a.release()
        worker.dispose()
        await reap(server)


@pytest.mark.asyncio
async def test_ordinary_timeout_without_earlier_cancel():
    """An uncancelled invocation still times out with a per-request timeout
    error and the worker keeps serving."""
    worker = PipeWorker()
    hanging = Hanging()
    quick = QuickResult()

    async def operation(request):
        if request.id == A_ID:
            return await hanging.operation(request)
        return await quick.operation(request)

    server = asyncio.create_task(serve(
        operation, invocation_timeout=DEADLINE,
        stdin_fileno=worker.stdin_read, stdout_fileno=worker.stdout_write,
    ))
    try:
        worker.send(HELLO)
        assert (await worker.recv())["type"] == "ready"
        worker.send(translate_request(A_ID))
        await hanging.started.wait()
        terminal = await worker.recv_terminal(A_ID)
        assert terminal["type"] == "error"
        assert terminal["code"] == "timeout"

        # The worker remains healthy for the next request.
        worker.send(translate_request(C_ID))
        assert (await worker.recv_terminal(C_ID))["type"] == "result"

        worker.send(SHUTDOWN)
        assert (await worker.recv())["type"] == "stopped"
        assert await reap(server) == 0
    finally:
        worker.dispose()
        await reap(server)


@pytest.mark.asyncio
async def test_timeout_first_then_explicit_cancel_keeps_timeout_semantics():
    """When the deadline's own timer wins first, a later protocol cancel
    must not interrupt its cleanup, and the terminal keeps timeout
    semantics (not cancelled)."""
    worker = PipeWorker()
    a = Draining()
    quick = QuickResult()

    async def operation(request):
        if request.id == A_ID:
            return await a.operation(request)
        return await quick.operation(request)

    server = asyncio.create_task(serve(
        operation, invocation_timeout=DEADLINE,
        stdin_fileno=worker.stdin_read, stdout_fileno=worker.stdout_write,
    ))
    try:
        worker.send(HELLO)
        assert (await worker.recv())["type"] == "ready"
        worker.send(translate_request(A_ID))
        await a.started.wait()

        # No protocol cancel: let the deadline's timer deliver the first
        # cancellation into the operation (cleanup_started proves it).
        await a.cleanup_started.wait()
        assert a.cleanup_done is False

        # Causal barrier for the later cancel: CANCEL_A and a fresh quick
        # request arrive in ONE write; the reader processes frames in
        # order, so C_ID's result proves CANCEL_A was handled while A's
        # cleanup barrier was still closed — no fixed wait involved.
        worker.send(CANCEL_A, translate_request(C_ID))
        assert (await worker.recv_terminal(C_ID))["type"] == "result"
        assert a.cleanup_done is False
        assert a.cleanup_interrupted is False
        await worker.expect_silence()  # no premature terminal for A

        a.release()
        terminal = await worker.recv_terminal(A_ID)
        assert terminal["type"] == "error"
        assert terminal["code"] == "timeout"  # timeout semantics retained
        assert a.cleanup_done is True
        assert a.cleanup_interrupted is False

        # Another request remains usable.
        worker.send(translate_request(B_ID))
        assert (await worker.recv_terminal(B_ID))["type"] == "result"

        worker.send(SHUTDOWN)
        assert (await worker.recv())["type"] == "stopped"
        assert await reap(server) == 0
    finally:
        a.release()
        worker.dispose()
        await reap(server)
