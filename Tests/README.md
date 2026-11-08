# Validation Area

The Swift package uses Swift Testing for Core, real child-process gateway, application-state, and native TextKit regressions. `swift test` runs all package tests; build the worker bundles first because the gateway and coordinator integration tests launch packaged executables. `script/check.sh` orders the frozen worker environment/build, Swift tests, Python tests, and native Debug build.

Python tests live in `Worker/tests`. The default `pytest -m "not live"` path needs no credentials or model requests. It distinguishes packaged helper execution, development-interpreter subprocesses, and deterministic in-process lifecycle tests.

Native XCTest UI tests live in `Tests/BiparaUITests/BiparaUITests.swift`; their separate `BiparaUITestHost` product uses an in-memory credential store and a deterministic gateway. Fixture flags and providers never enter the production app. Launches isolate previous saved window state, and fixture windows use the primary display. Run serially with full Xcode and a foreground desktop session. Interactive UI tests are intentionally separate from the default offline check.

The checked-in `Bipara` scheme includes the `BiparaUITests` test target and `BiparaUITests` class. From the repository root, after worker packaging, the serial reproduction command uses a fresh evidence directory:

```sh
mkdir -p .local/validation
UI_EVIDENCE="$(mktemp -d "$PWD/.local/validation/ui-XXXXXX")"
xcodebuild -project Bipara.xcodeproj -scheme Bipara \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$UI_EVIDENCE/derived-data" \
  -resultBundlePath "$UI_EVIDENCE/ui.xcresult" \
  -parallel-testing-enabled NO \
  -only-testing:BiparaUITests/BiparaUITests test
```

Use a fresh result-bundle path on subsequent runs. For the existing layout/settings smoke case, replace the selector with `-only-testing:BiparaUITests/BiparaUITests/testInputTranslationBothLayoutsAndSettings`. **NOT RUN in the current validation.** The command launches the native fixture host and needs a foreground desktop with UI automation access; screen recording is a separate prerequisite for visual evidence. See [current validation](../docs/validation.md) for source/environment provenance, successful native offline component checks and remaining acceptance limits.

`Config/BiparaDebug.xcconfig` optionally includes `Config/BiparaDebug.local.xcconfig`. If present, it affects both the Debug build and these documented Debug UI commands; source alone does not reproduce those local settings.

The native test host can construct five documents above 100 KiB each and measure 30 interactions after a start-file barrier. The benchmark observes actual native owner/layout/selection acknowledgement and drawing; it is not a hardware input latency measurement. Screen-capture permission is reported explicitly; unavailable captures do not turn functional assertions into visual evidence.

Start from the [acceptance criteria](../docs/requirements.md#acceptance-evidence-for-the-first-working-version), [test plan](../docs/testing.md), [canonical prompt corpus](../prompts/cases.json), and [worker protocol](../docs/design/worker-protocol.md). Concise outcomes live in `docs/validation.md`; raw results belong in `.local/validation/`. Real API checks are opt-in, synthetic, bounded, and labeled separately.

The [model configuration follow-up](../docs/design/model-settings.md) defines `SET-03`–`SET-06`, `MODEL-05`, `IPC-06`, `DOC-04` and `PRIV-03`. Current [acceptance limits](../docs/validation.md#remaining-gates) distinguish earlier interaction evidence from this offline baseline; the settings/menu UI subset was not rerun. Live-provider, packaged clean-machine and broad native acceptance remain separate gates.
