"""Async worker runtime: handshake, request registry, cancellation, exit.

The loop owns the terminal-event guard. Frame emission goes through a
single FIFO pump so a terminal event is queued exactly once and can never
be interrupted by a cancellation race. Model operations are injected as an
async callable; the runtime never imports a provider stack itself.
"""

from __future__ import annotations

import asyncio
import os
import sys
from collections import deque
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Awaitable, Callable

from . import WORKER_VERSION, protocol
from .errors import WorkerError
from .protocol import (
    FatalError,
    MAX_FRAME_BYTES,
    MAX_INFLIGHT,
    Request,
    RequestError,
    check_cancel_frame,
    check_envelope_header,
    decode_frame,
    encode_frame,
)

Operation = Callable[[Request], Awaitable[tuple[dict[str, Any], dict[str, Any]]]]
ShutdownCleanup = Callable[[], Awaitable[None]]
DEFAULT_INVOCATION_TIMEOUT = 120.0  # seconds, contract constant

READ_CHUNK_BYTES = 65536


class _AsyncLineReader:
    """Event-driven line reader over a raw file descriptor."""

    def __init__(self, fileno: int) -> None:
        self._fileno = fileno
        self._loop = asyncio.get_running_loop()
        self._buffer = bytearray()
        self._lines: deque[bytes] = deque()
        self._eof = False
        self._error: BaseException | None = None
        self._waiter: asyncio.Future[None] | None = None
        self._loop.add_reader(fileno, self._on_readable)

    def _on_readable(self) -> None:
        try:
            chunk = os.read(self._fileno, READ_CHUNK_BYTES)
        except OSError:
            self._error = FatalError("worker_failed")
            self._detach()
            self._wake()
            return
        if not chunk:
            self._eof = True
            self._detach()
            self._wake()
            return
        self._buffer.extend(chunk)
        while True:
            newline = self._buffer.find(b"\n")
            if newline < 0:
                break
            line = bytes(self._buffer[: newline + 1])
            del self._buffer[: newline + 1]
            self._lines.append(line)
        if len(self._buffer) > MAX_FRAME_BYTES:
            self._error = FatalError("invalid_frame")
            self._detach()
        self._wake()

    def _detach(self) -> None:
        try:
            self._loop.remove_reader(self._fileno)
        except (ValueError, RuntimeError):  # pragma: no cover - loop already closed
            pass

    def _wake(self) -> None:
        if self._waiter is not None and not self._waiter.done():
            self._waiter.set_result(None)

    async def readline(self) -> bytes | None:
        """Next complete LF-terminated line, or None at EOF."""

        while not self._lines and not self._eof and self._error is None:
            self._waiter = self._loop.create_future()
            try:
                await self._waiter
            finally:
                self._waiter = None
        if self._error is not None:
            raise self._error
        if self._lines:
            return self._lines.popleft()
        return None

    def close(self) -> None:
        self._detach()


class _FramePump:
    """Single FIFO writer; every frame is one compact line, flushed fully."""

    def __init__(self, fileno: int) -> None:
        self._fileno = fileno
        self._queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="bipara-writer")
        self._task: asyncio.Task[None] | None = None

    def start(self) -> None:
        self._task = asyncio.get_running_loop().create_task(self._run())

    def emit(self, envelope: dict[str, Any]) -> None:
        self._queue.put_nowait(envelope)

    async def _run(self) -> None:
        loop = asyncio.get_running_loop()
        while True:
            envelope = await self._queue.get()
            try:
                data = encode_frame(envelope)
                await loop.run_in_executor(self._executor, self._write_all, data)
            except Exception:
                # The parent is gone or the pipe is unwritable; stop writing.
                pass
            finally:
                self._queue.task_done()

    def _write_all(self, data: bytes) -> None:
        view = memoryview(data)
        while view:
            written = os.write(self._fileno, view)
            view = view[written:]

    async def drain(self) -> None:
        await self._queue.join()

    def stop(self) -> None:
        if self._task is not None:
            self._task.cancel()
        self._executor.shutdown(wait=False)


def _disarm_timeout(context: "asyncio.Timeout") -> None:
    """Disarm a still-armed invocation deadline.

    The deadline's own timer cancels its task directly, bypassing
    ``_request_cancel``; once a first cancellation has started the drain,
    that timer must never fire into it. ``reschedule(None)`` cancels the
    pending timer handle. An already-expired or exited context cannot be
    rescheduled and needs no disarm: its cancellation was the first cause,
    and the ``cancelling()`` check keeps later protocol events out of the
    drain it started.
    """

    if context.expired():
        return
    try:
        context.reschedule(None)
    except RuntimeError:
        # The context is no longer active (exiting or already fired);
        # its timer handle is gone. Nothing to disarm.
        pass


def _request_cancel(task: "asyncio.Task[None]", deadline: "asyncio.Timeout | None") -> None:
    """Cancel a request task exactly once, disarming its invocation timer.

    A second ``cancel()`` while the task is already executing asynchronous
    cancellation cleanup would deliver another CancelledError into that
    cleanup and abort it. ``Task.cancelling()`` counts cancel requests not
    yet completed (the task body re-raises instead of un-cancelling), so a
    pending or draining first cancellation is left alone — whether that
    first cancellation came from the protocol or from the deadline's own
    timer. When the protocol wins first, a still-armed deadline timer is
    disarmed so it cannot inject a second cancellation into the drain.
    """

    if task.done() or task.cancelling() > 0:
        return
    if deadline is not None:
        _disarm_timeout(deadline)
    task.cancel()


def _validated_meta(meta: Any, request: Request) -> dict[str, Any]:
    required = {
        "provider",
        "requested_model",
        "requested_effort",
        "returned_model",
        "prompt_version",
        "input_tokens",
        "output_tokens",
    }
    if not isinstance(meta, dict) or set(meta.keys()) != required:
        raise ValueError("operation returned a malformed meta object")
    if meta["provider"] != request.config.provider:
        raise ValueError("meta provider does not match the request config")
    if meta["requested_model"] != request.config.model:
        raise ValueError("meta requested_model does not match the request config")
    if meta["requested_effort"] != request.config.effort:
        raise ValueError("meta requested_effort does not match the request config")
    if meta["prompt_version"] != request.prompt_version:
        raise ValueError("meta prompt_version does not match the request")
    returned_model = meta["returned_model"]
    if returned_model is not None and (not isinstance(returned_model, str) or not returned_model):
        raise ValueError("meta returned_model must be null or a nonempty string")
    for field in ("input_tokens", "output_tokens"):
        tokens = meta[field]
        if tokens is not None and (
            not isinstance(tokens, int) or isinstance(tokens, bool) or tokens < 0
        ):
            raise ValueError(f"meta {field} must be null or a nonnegative integer")
    return meta


async def serve(
    operation: Operation,
    *,
    invocation_timeout: float = DEFAULT_INVOCATION_TIMEOUT,
    on_shutdown: ShutdownCleanup | None = None,
    stdin_fileno: int | None = None,
    stdout_fileno: int | None = None,
) -> int:
    """Run the worker until a shutdown frame or stdin EOF. Returns the exit code.

    ``on_shutdown`` is invoked once during exit cleanup (after active tasks
    drain, before the final frames settle) so provider HTTP clients close.
    """

    stdin_fd = sys.stdin.fileno() if stdin_fileno is None else stdin_fileno
    stdout_fd = sys.stdout.fileno() if stdout_fileno is None else stdout_fileno
    reader = _AsyncLineReader(stdin_fd)
    pump = _FramePump(stdout_fd)
    pump.start()
    active: dict[str, asyncio.Task[None]] = {}
    seen_ids: set[str] = set()
    # The terminal-event guard: exactly one terminal frame per accepted
    # request, regardless of whether its task ever started running.
    terminal_emitted: set[str] = set()
    shutdown_requested = False
    saw_eof = False
    fatal: FatalError | None = None
    # Per-request invocation-deadline contexts for cancellation arbitration.
    deadline_ctx: dict[str, asyncio.Timeout] = {}

    def emit_terminal(request_id: str, envelope: dict[str, Any]) -> None:
        if request_id in terminal_emitted:
            return
        terminal_emitted.add(request_id)
        pump.emit(envelope)

    def emit_error(
        request_id: str, code: str, retry_after_ms: int | None, error: WorkerError | None = None
    ) -> None:
        frame = {
            "v": protocol.PROTOCOL_VERSION,
            "type": "error",
            "id": request_id,
            "code": code,
            "retry_after_ms": retry_after_ms,
        }
        if error is not None:
            if error.http_status is not None:
                frame["http_status"] = error.http_status
            if error.provider_code is not None:
                frame["provider_code"] = error.provider_code
            if error.validation_reason is not None:
                frame["validation_reason"] = error.validation_reason.value
        emit_terminal(request_id, frame)

    def emit_cancelled(request_id: str) -> None:
        emit_terminal(
            request_id,
            {"v": protocol.PROTOCOL_VERSION, "type": "cancelled", "id": request_id},
        )

    def spawn_request(request: Request) -> None:
        # One invocation-deadline context per request, kept in a small
        # request-local map so protocol cancellation can disarm a
        # still-armed timer before cancelling the task. The timeout
        # mechanism itself is unchanged asyncio.timeout.
        deadline = asyncio.timeout(invocation_timeout)

        async def run() -> None:
            deadline_ctx[request.id] = deadline
            try:
                try:
                    async with deadline:
                        data, meta = await operation(request)
                    meta = _validated_meta(meta, request)
                    if not isinstance(data, dict):
                        raise ValueError("operation returned non-object data")
                except WorkerError as exc:
                    retry_after = exc.retry_after_ms
                    if retry_after is not None and (
                        not isinstance(retry_after, int)
                        or isinstance(retry_after, bool)
                        or not 0 <= retry_after <= 3_600_000
                    ):
                        retry_after = None
                    code = exc.code if exc.code in protocol.ERROR_CODES else "worker_failed"
                    emit_error(request.id, code, retry_after, exc)
                except TimeoutError:
                    emit_error(request.id, "timeout", None)
                except asyncio.CancelledError:
                    # Re-raise so the task completes in the cancelled state;
                    # the cancelled terminal is emitted from the done callback
                    # after the operation's asynchronous cleanup has fully
                    # drained. Any deadline timer was disarmed when the
                    # protocol cancellation began; if the deadline itself was
                    # the first cause, asyncio.timeout converts to
                    # TimeoutError on exit and the timeout branch above (or
                    # the error branches) applies after cleanup drains.
                    raise
                except Exception:
                    emit_error(request.id, "worker_failed", None)
                else:
                    emit_terminal(
                        request.id,
                        {
                            "v": protocol.PROTOCOL_VERSION,
                            "type": "result",
                            "id": request.id,
                            "data": data,
                            "meta": meta,
                        },
                    )
            finally:
                deadline_ctx.pop(request.id, None)

        task = asyncio.get_running_loop().create_task(run())
        active[request.id] = task

        def _released(finished: asyncio.Task[None]) -> None:
            # The physical concurrency slot is released only when the task
            # has fully completed, and the cancelled terminal is emitted in
            # the same callback — never before asynchronous operation
            # cleanup drains. Result/error terminals were already emitted
            # by the task body after the operation finished; the guard
            # keeps every request exactly one terminal event, including
            # tasks cancelled before their first step (which run no code).
            active.pop(request.id, None)
            if finished.cancelled():
                emit_cancelled(request.id)

        task.add_done_callback(_released)

    try:
        first_line = await reader.readline()
        if first_line is None:
            # Q1: EOF before hello is still a normal EOF — the same normal
            # cleanup and stopped acknowledgement as any other, without
            # ever fabricating ready.
            saw_eof = True
        else:
            env = decode_frame(first_line)
            kind = check_envelope_header(env)
            if kind != "hello":
                raise FatalError("incompatible_protocol")
            pump.emit(
                {
                    "v": protocol.PROTOCOL_VERSION,
                    "type": "ready",
                    "worker_version": WORKER_VERSION,
                    "max_inflight": MAX_INFLIGHT,
                    "prompt_versions": list(protocol.PROMPT_VERSIONS),
                }
            )
            while True:
                line = await reader.readline()
                if line is None:
                    saw_eof = True
                    break
                env = decode_frame(line)
                kind = check_envelope_header(env)
                if kind == "hello":
                    raise FatalError("invalid_frame")
                elif kind == "shutdown":
                    shutdown_requested = True
                    break
                elif kind == "cancel":
                    target = check_cancel_frame(env)
                    task = active.get(target)
                    if task is not None:
                        # The cancelled terminal is emitted by the done
                        # callback once the task (including asynchronous
                        # cancellation cleanup) has fully drained; the slot
                        # stays occupied until then. Repeated cancellation,
                        # from the protocol or the invocation deadline, must
                        # not interrupt an in-progress drain.
                        _request_cancel(task, deadline_ctx.get(target))
                elif kind == "request":
                    request_id = env.get("id")
                    if not protocol.is_canonical_uuid(request_id) or request_id in seen_ids:
                        raise FatalError("invalid_frame")
                    assert isinstance(request_id, str)
                    seen_ids.add(request_id)
                    if len(active) >= MAX_INFLIGHT:
                        emit_error(request_id, "busy", None)
                        continue
                    try:
                        request = protocol.parse_request(env)
                    except RequestError:
                        emit_error(request_id, "invalid_request", None)
                        continue
                    spawn_request(request)
    except FatalError as exc:
        fatal = exc
    finally:
        # Exit cleanup: cancel in-flight tasks, then guarantee one terminal
        # frame per active request even if a task never started running
        # (done callbacks drain `active` during gather, so the ID list is
        # captured first). Cancellation is idempotent: an exit path never
        # re-cancels a task already draining a first cancellation.
        inflight_ids = list(active)
        for request_id in inflight_ids:
            _request_cancel(active[request_id], deadline_ctx.get(request_id))
        if inflight_ids:
            await asyncio.gather(*active.values(), return_exceptions=True)
        for request_id in inflight_ids:
            emit_cancelled(request_id)
        if on_shutdown is not None:
            try:
                await on_shutdown()
            except Exception:  # pragma: no cover - exit path must proceed
                pass
        if fatal is not None:
            pump.emit({"v": protocol.PROTOCOL_VERSION, "type": "fatal", "code": fatal.code})
        try:
            await pump.drain()
        except Exception:  # pragma: no cover - parent already gone
            pass
        # Normal exits acknowledge with exactly one stopped frame: an
        # explicit shutdown or a normal stdin EOF (Q1 decision: EOF has the
        # same effect as shutdown). Fatal exits keep fatal and exit nonzero
        # without a normal stopped event. If the parent is gone and the
        # pipe is unwritable, the write failure is swallowed above and
        # cleanup still completes.
        if fatal is None and (shutdown_requested or saw_eof):
            pump.emit({"v": protocol.PROTOCOL_VERSION, "type": "stopped"})
            try:
                await pump.drain()
            except Exception:  # pragma: no cover
                pass
        pump.stop()
        reader.close()
    return 1 if fatal is not None else 0
