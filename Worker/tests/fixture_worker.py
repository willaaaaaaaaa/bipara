"""Test-only worker entry point.

Injects the fixture model factory into the real protocol loop. Used by
offline tests and the packaged fixture build; never shipped in the release
bundle.
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # Worker/
sys.path.insert(0, str(Path(__file__).resolve().parent))  # Worker/tests/

from bipara_worker.assets import AssetError, load_assets, load_cases  # noqa: E402
from bipara_worker.runtime import DEFAULT_INVOCATION_TIMEOUT, serve  # noqa: E402
from fixture_model import make_fixture_operation  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="Bipara fixture worker (test only)")
    parser.add_argument("--delay", type=float, default=0.0, help="per-operation delay seconds")
    parser.add_argument(
        "--delay-translate", type=float, default=None, help="override delay for translate ops"
    )
    parser.add_argument(
        "--delay-align", type=float, default=None, help="override delay for align ops"
    )
    parser.add_argument("--fail", type=str, default=None, help="fail every operation with this code")
    parser.add_argument(
        "--invocation-timeout",
        type=float,
        default=DEFAULT_INVOCATION_TIMEOUT,
        help="override the per-operation deadline (tests only)",
    )
    args = parser.parse_args()
    try:
        assets = load_assets()
        cases = load_cases()
    except AssetError:
        return 1
    operation, aclose = make_fixture_operation(
        cases,
        delay_seconds=args.delay,
        delay_translate=args.delay_translate,
        delay_align=args.delay_align,
        fail_code=args.fail,
    )
    return asyncio.run(
        serve(operation, invocation_timeout=args.invocation_timeout, on_shutdown=aclose)
    )


if __name__ == "__main__":
    raise SystemExit(main())
