// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexPad",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CodexPadCore", targets: ["CodexPadCore"])
    ],
    targets: [
        .target(
            name: "CodexPadCore",
            path: ".",
            exclude: ["Tests", "UITests", "UITestSupport", "docs", "README.md", "CodexPad.xcodeproj", "CodexPad/Views",
                      "CodexPad/Resources", "CodexPad/App/CodexPadApp.swift", "CodexPad/App/AppState.swift"],
            sources: ["Sources/CodexPadCore", "CodexPad/Services", "CodexPad/App/AppSettings.swift"]
        ),
        .testTarget(name: "CodexPadCoreTests", dependencies: ["CodexPadCore"])
    ]
)
