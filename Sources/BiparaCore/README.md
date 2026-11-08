# Shared Document Logic Area

Platform-independent Swift package (`BiparaCore`): document revisions and identities, strict UTF-16 range handling, paragraph/unit planning, deterministic paragraph assembly, correspondence resolution/validation, the document JSON codec, the shared strict-JSON preflight, and the `ModelGateway` seam types (typed requests/results/errors for the two model operations).

Run the tests with `swift test --filter BiparaCoreTests` from the repository root (no GUI, worker, credentials, or network). The worker adapter implementing `ModelGateway` lives in `BiparaWorker` (`Sources/BiparaWorker`); framework integration contracts live in the [native/state design](../../docs/design/technical-design.md), [model workflow](../../docs/design/model-workflow.md), and [document format](../../docs/design/document-format.md).
