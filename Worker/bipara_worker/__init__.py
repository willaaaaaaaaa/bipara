"""Bipara bundled Python worker.

One local child process performing single model operations over pipes.
See docs/design/worker-protocol.md for the transport contract and
docs/design/model-workflow.md for model behavior.
"""

WORKER_VERSION = "0.1.0"
