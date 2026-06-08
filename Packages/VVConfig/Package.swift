// swift-tools-version:5.9
import PackageDescription

// Note: tests use a tiny dependency-free runner (the `vvcheck` executable) instead
// of XCTest, because XCTest/swift-testing are unavailable with Command Line Tools
// (they ship only with full Xcode). Run them with: `swift run vvcheck`.
let package = Package(
    name: "VVConfig",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "VVConfig", targets: ["VVConfig"]),
        .executable(name: "vvcheck", targets: ["vvcheck"]),
    ],
    targets: [
        .target(name: "VVConfig"),
        .executableTarget(name: "vvcheck", dependencies: ["VVConfig"]),
    ]
)
