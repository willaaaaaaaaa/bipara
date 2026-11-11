// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Bipara",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "BiparaCore", targets: ["BiparaCore"]),
        .library(name: "BiparaWorker", targets: ["BiparaWorker"]),
        .library(name: "BiparaAppKit", targets: ["BiparaAppKit"]),
    ],
    targets: [
        .target(
            name: "BiparaCore",
            path: "Sources/BiparaCore",
            exclude: ["README.md"]
        ),
        // Foundation-only child-process adapter for the bundled Python
        // worker (worker-protocol.md). The app links this product.
        .target(
            name: "BiparaWorker",
            dependencies: ["BiparaCore"],
            path: "Sources/BiparaWorker"
        ),
        // App-layer logic compiled and unit-tested through the package
        // while the product build stays with the checked-in Xcode project.
        // The @main entry file is compiled only by the Xcode app target.
        .target(
            name: "BiparaAppKit",
            dependencies: ["BiparaCore", "BiparaWorker"],
            path: "Sources/BiparaApp",
            exclude: ["BiparaApp.swift", "README.md", "Resources"],
            resources: [.process("Localization")]
        ),
        .testTarget(
            name: "BiparaCoreTests",
            dependencies: ["BiparaCore"],
            path: "Tests/BiparaCoreTests"
        ),
        .testTarget(
            name: "BiparaWorkerTests",
            dependencies: ["BiparaWorker", "BiparaCore"],
            path: "Tests/BiparaWorkerTests"
        ),
        .testTarget(
            name: "BiparaAppTests",
            dependencies: ["BiparaAppKit", "BiparaCore", "BiparaWorker"],
            path: "Tests/BiparaAppTests"
        ),
    ]
)
