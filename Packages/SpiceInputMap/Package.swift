// swift-tools-version:5.9
import PackageDescription

// Pure-Swift keyboard scancode mapping with a dependency-free check runner
// (`swift run inputcheck`), kept independent of CocoaSpice so it builds and is
// verifiable without the native SPICE stack.
let package = Package(
    name: "SpiceInputMap",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "SpiceInputMap", targets: ["SpiceInputMap"]),
        .executable(name: "inputcheck", targets: ["inputcheck"]),
    ],
    targets: [
        .target(name: "SpiceInputMap"),
        .executableTarget(name: "inputcheck", dependencies: ["SpiceInputMap"]),
    ]
)
