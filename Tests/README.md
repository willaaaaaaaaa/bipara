# Validation Area

Acceptance is initiated by the maintainer before merge, following the [trigger rules](../docs/testing.md#acceptance-triggers). The commands below are execution instructions for a requested round, not automatic post-edit tasks. Routine changes use narrowly scoped self-checks; required Git hooks and hosted CI remain active.

The Swift package uses Swift Testing for Core, real child-process gateway, application-state, and native TextKit regressions. `swift test --build-system swiftbuild --no-parallel` runs all package tests; build the worker bundles first because the gateway and coordinator integration tests launch packaged executables. Use full Xcode 26.6 or newer for the documented check workflow. `script/check.sh` orders the frozen worker environment/build, Swift tests, Python tests, and native Debug build.

Select [Swift Build](https://github.com/swiftlang/swift-build#with-swiftpm) explicitly so Swift 6.3 and newer toolchains use the same package build system. Swift 6.3 otherwise defaults to the legacy native build system, which has a reported [cross-module async allocation crash](https://github.com/swiftlang/swift/issues/86204) matching the hosted test failure. This selection preserves every suite and assertion; native UI and installer acceptance remain separate.

Run package test cases serially to isolate shared AppKit state and prevent unrelated CPU-heavy main-actor fixtures from consuming another test's deadline. Concurrency tests still create and coordinate concurrent tasks within each case; their assertions and timeouts remain unchanged.

Python tests live in `Worker/tests`. The default `pytest -m "not live"` path needs no credentials or model requests. It distinguishes packaged helper execution, development-interpreter subprocesses, and deterministic in-process lifecycle tests.

Native XCTest UI tests live in `Tests/BiparaUITests/BiparaUITests.swift`; their separate `BiparaUITestHost` product uses an in-memory credential store and a deterministic gateway. Fixture flags and providers never enter the production app. Launches isolate previous saved window state, and fixture windows use the primary display. Run serially with full Xcode and a foreground desktop session. Interactive UI tests are intentionally separate from the default offline check.

The checked-in `Bipara` scheme includes the `BiparaUITests` test target and `BiparaUITests` class. From the repository root, after worker packaging, run the [app functional suite](../docs/testing.md#app-functional-acceptance) on the existing desktop. The selectors below exclude the platform audit and the slider case that requires global Keyboard navigation:

```sh
mkdir -p .local/validation
UI_EVIDENCE="$(mktemp -d "$PWD/.local/validation/ui-XXXXXX")"
xcodebuild -project Bipara.xcodeproj -scheme Bipara \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$UI_EVIDENCE/derived-data" \
  -resultBundlePath "$UI_EVIDENCE/ui.xcresult" \
  -parallel-testing-enabled NO \
  -only-testing:BiparaUITests/BiparaUITests \
  -skip-testing:BiparaUITests/BiparaUITests/testAccessibilityAuditOfReadingAndSettings \
  -skip-testing:BiparaUITests/BiparaUITests/testReadingSizeAccessibilityTracksChanges \
  DEBUG_INFORMATION_FORMAT=dwarf-with-dsym test
```

Use a fresh result-bundle path on subsequent runs. For the layout/settings smoke case, replace the selector with `-only-testing:BiparaUITests/BiparaUITests/testInputTranslationBothLayoutsAndSettings`. The command launches the native fixture host and needs a foreground desktop with UI automation access and any macOS permissions required by the checkout location. Keep dSYMs available for XCTest failure reporting. See [current validation](../docs/validation.md) for actual runs, source/environment provenance and remaining acceptance limits.

Use app controls and app shortcuts for interactive product checks. Record any unavailable desktop prerequisite as a blocked check. Keep global system settings out of the functional workflow.

`Config/BiparaDebug.xcconfig` optionally includes `Config/BiparaDebug.local.xcconfig`. If present, it affects both the Debug build and these documented Debug UI commands; source alone does not reproduce those local settings.

The native test host can construct five documents above 100 KiB each and measure 30 interactions after a start-file barrier. The benchmark observes actual native owner/layout/selection acknowledgement and drawing; it is not a hardware input latency measurement. Screenshots use XCTest window attachments. Inspect images for permission prompts, occlusion and the intended screen before accepting them as visual evidence. Passing functional assertions do not qualify screenshots or accessibility audits while a system dialog obstructs the app.

Start from the [acceptance criteria](../docs/requirements.md#acceptance-evidence-for-the-first-working-version), [test plan](../docs/testing.md), [canonical prompt corpus](../prompts/cases.json), and [worker protocol](../docs/design/worker-protocol.md). Concise outcomes live in `docs/validation.md`; raw results belong in `.local/validation/`. Real API checks are opt-in, synthetic, bounded, and labeled separately.

The [model configuration contract](../docs/design/model-settings.md) defines `SET-03`–`SET-06`, `MODEL-05`, `IPC-06`, `DOC-04` and `PRIV-03`. Current [acceptance limits](../docs/validation.md#remaining-gates) distinguish native functional runs from complete accessibility and distribution qualification. Live-provider and packaged clean-machine acceptance remain separate gates.

Custom model editor regressions include `testCustomModelEditorFieldsAndProtocols`, `testChineseDarkModelEditorLayout` and `testLegacyEditorRequiresExplicitEffortAndCancelPreservesEntry`, together with the existing model CRUD, effort and credential-draft cases. They cover blank manual-entry fields in the six-field order, unchanged protocol/effort choices, absence of preset/vendor/catalog/Advanced controls, and saved custom values. The fixture uses fresh Responses configurations by default; `--legacy-models` creates a saved old-profile record for explicit-conversion testing. Apply/Cancel remain outside the scroll region.
