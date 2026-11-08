// swift-tools-version: 6.2
import PackageDescription

// EzPDFCore holds every ezpdf feature as a plain operation. The app UI, App Intents
// (Shortcuts) and the MCP server all call the same functions, so agents get every
// feature the UI has.
let package = Package(
    name: "EzPDFCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "EzPDFCore", targets: ["EzPDFCore"]),
        .executable(name: "ezpdf-cli", targets: ["ezpdf-cli"]),
    ],
    dependencies: [.package(path: "../OperatorLLM")],
    targets: [
        .target(
            name: "EzPDFCore",
            resources: [.copy("Resources/Readability.js"), .copy("Resources/reader.css"), .copy("Resources/Readability-LICENSE.md")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ezpdf-cli",
            dependencies: ["EzPDFCore", .product(name: "OperatorLLM", package: "OperatorLLM")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EzPDFCoreTests",
            dependencies: ["EzPDFCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
