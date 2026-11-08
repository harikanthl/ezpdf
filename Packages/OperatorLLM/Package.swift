// swift-tools-version: 6.2
import PackageDescription

// OperatorLLM, vendored from ezRecord (and before that, Operator; both our own code).
// Provider clients (Anthropic Messages, OpenAI-compatible, on-device Foundation Models), the
// tool-calling agent loop, and the Keychain store for API keys. System frameworks only.
let package = Package(
    name: "OperatorLLM",
    platforms: [.macOS(.v26)],
    products: [.library(name: "OperatorLLM", targets: ["OperatorLLM"])],
    dependencies: [],
    targets: [
        .target(name: "OperatorLLM", swiftSettings: [.defaultIsolation(nil)]),
        .testTarget(name: "OperatorLLMTests", dependencies: ["OperatorLLM"]),
    ]
)
