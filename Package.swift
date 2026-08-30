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
        .library(name: "TouchstoneFoundationModels", targets: ["TouchstoneFoundationModels"]),
        .library(name: "TouchstoneOpenAICompatible", targets: ["TouchstoneOpenAICompatible"])
    ],
    targets: [
        // Core. No platform SDK dependencies on purpose: this must build and
        // test anywhere, including Linux CI.
        .target(name: "Touchstone"),

        // Deterministic doubles for tests.
        .target(name: "TouchstoneTesting", dependencies: ["Touchstone"]),

        // On-device backend. Availability-gated inside.
        .target(name: "TouchstoneFoundationModels", dependencies: ["Touchstone"]),

        // Any server speaking the OpenAI chat-completions dialect: OpenAI
        // itself, Ollama, LM Studio, llama.cpp's server, Groq. One base URL
        // apart. Everything except the URLSession call is pure and tested.
        .target(name: "TouchstoneOpenAICompatible", dependencies: ["Touchstone"]),

        .testTarget(
            name: "TouchstoneTests",
            dependencies: ["Touchstone", "TouchstoneTesting", "TouchstoneOpenAICompatible"]
        )
    ]
)
