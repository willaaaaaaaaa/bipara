"""Release worker entry point.

Loads and verifies the packaged prompt assets, then serves the pipe
protocol with the LangChain model operation. Fixture injection exists only
in the test entry point under Worker/tests and is not reachable here.
"""

from __future__ import annotations

import asyncio
import sys

from . import WORKER_VERSION
from .assets import AssetError, load_assets
from .models import build_shared_http_client, make_langchain_operation
from .protocol import PROTOCOL_VERSION, FatalError, encode_frame
from .runtime import serve


def _emit_fatal_direct(code: str) -> None:
    try:
        sys.stdout.buffer.write(
            encode_frame({"v": PROTOCOL_VERSION, "type": "fatal", "code": code})
        )
        sys.stdout.buffer.flush()
    except OSError:
        pass


def main() -> int:
    try:
        assets = load_assets()
    except AssetError:
        _emit_fatal_direct("missing_asset")
        return 1
    http_client = build_shared_http_client()
    operation, aclose = make_langchain_operation(assets, http_async_client=http_client)
    try:
        return asyncio.run(serve(operation, on_shutdown=aclose))
    except FatalError as exc:  # pragma: no cover - serve handles its own fatals
        _emit_fatal_direct(exc.code)
        return 1
    except BaseException:
        _emit_fatal_direct("worker_failed")
        raise


if __name__ == "__main__":
    raise SystemExit(main())
