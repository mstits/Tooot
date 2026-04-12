// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProjectToooT",
    platforms: [
        .macOS(.v15),   // Atomic<T> (Synchronization) requires macOS 15; 2026 release targets macOS 16
        .iOS(.v18),
        .visionOS(.v2)
    ],
    products: [
        .executable(name: "ProjectToooTApp", targets: ["ProjectToooTApp"]),
        .library(name: "ToooT_Core", targets: ["ToooT_Core"]),
        .library(name: "ToooT_UI", targets: ["ToooT_UI"]),
        .library(name: "ToooT_Plugins", targets: ["ToooT_Plugins"]),
        .library(name: "ToooT_IO", targets: ["ToooT_IO"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "ToooT_Core", swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "ToooT_IO", dependencies: ["ToooT_Core"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "ToooT_Plugins", dependencies: ["ToooT_Core"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "ToooT_UI", dependencies: ["ToooT_Core", "ToooT_IO", "ToooT_Plugins"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .executableTarget(name: "ProjectToooTApp", dependencies: ["ToooT_UI"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .executableTarget(name: "UATRunner", dependencies: ["ToooT_Core", "ToooT_IO", "ToooT_UI", "ToooT_Plugins"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "ToooT_CoreTests", dependencies: ["ToooT_Core", "ToooT_IO", "ToooT_UI"], swiftSettings: [.enableExperimentalFeature("StrictConcurrency")])
    ]
)
