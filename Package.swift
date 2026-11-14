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
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0"),
        .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.9.0"),
    ],
    targets: [
        .target(
            name: "BiparaCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ],
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
            resources: [.process("Localization"), .copy("ThirdPartyLicenses")]
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
