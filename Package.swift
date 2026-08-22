// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Touchstone",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "Touchstone", targets: ["Touchstone"]),
        .library(name: "TouchstoneTesting", targets: ["TouchstoneTesting"]),
        .library(name: "TouchstoneFoundationModels", targets: ["TouchstoneFoundationModels"])
    ],
    targets: [
        // Core. No platform SDK dependencies on purpose: this must build and
        // test anywhere, including Linux CI.
        .target(name: "Touchstone"),

        // Deterministic doubles for tests.
        .target(name: "TouchstoneTesting", dependencies: ["Touchstone"]),

        // On-device backend. Availability-gated inside.
        .target(name: "TouchstoneFoundationModels", dependencies: ["Touchstone"]),

        .testTarget(
            name: "TouchstoneTests",
            dependencies: ["Touchstone", "TouchstoneTesting"]
        )
    ]
)
