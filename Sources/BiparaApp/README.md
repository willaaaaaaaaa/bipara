# Native Application Area

Native macOS application. Product build: the checked-in `Bipara.xcodeproj` (shared scheme `Bipara`), which compiles this directory including the `@main` entry and the staged `Resources/Assets.xcassets` (AppIcon from the selected C master, CorrespondenceBackground color set).

For offline self-testing without full Xcode, the package also builds this directory as the `BiparaAppKit` library target (excluding `BiparaApp.swift` and `Resources/`), so `swift test` runs `BiparaAppTests` against the real state layer: workspace/tabs, settings draft persistence, Keychain (isolated service), atomic document file service, and the `TranslationCoordinator` driving the real `PythonModelGateway`. Native TextKit regressions also run through the package. Runtime/visual evidence comes from the Xcode-built native fixture app; see the [current native report](../../docs/validation.md) for actual checks and remaining limits.

Build and run with `script/build_and_run.sh` (embeds the packaged worker under `Contents/Helpers` and launches the fresh app); it requires full Xcode.
