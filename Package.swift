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
        .library(name: "ToooT_Core",    targets: ["ToooT_Core"]),
        .library(name: "ToooT_UI",      targets: ["ToooT_UI"]),
        .library(name: "ToooT_Plugins", targets: ["ToooT_Plugins"]),
        .library(name: "ToooT_VST3",    targets: ["ToooT_VST3"]),
        .library(name: "ToooT_CLAP",    targets: ["ToooT_CLAP"]),
        .library(name: "ToooT_IO",      targets: ["ToooT_IO"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "ToooT_Core",
                swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "ToooT_IO", dependencies: ["ToooT_Core"],
                swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        // VST3 bridge — Obj-C++ shim that links directly against the Steinberg VST3 SDK.
        // JUCE removed: its GPL/commercial dual-license is incompatible with MIT, and we
        // don't need JUCE's cross-platform abstractions on macOS-native code. Vendor the
        // Steinberg SDK under Sources/ToooT_VST3/VST3_SDK/ and define TOOOT_VST3_SDK_AVAILABLE=1
        // to activate real hosting.
        .target(name: "ToooT_VST3",
                dependencies: [],
                publicHeadersPath: "include",
                cxxSettings: [.headerSearchPath("VST3_SDK")]),
        // CLAP C-side: minimal BSD-3-Clause CLAP ABI header + a small dlopen loader.
        // SPM forbids mixed C + Swift in one target, so the Swift wrapper lives next door.
        .target(name: "ToooT_CLAP_C",
                dependencies: [],
                publicHeadersPath: "include",
                cSettings: [.headerSearchPath("include")]),
        // CLAP Swift wrapper — depends on ToooT_CLAP_C.
        .target(name: "ToooT_CLAP",
                dependencies: ["ToooT_CLAP_C"],
                swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "ToooT_Plugins",
                dependencies: ["ToooT_Core", "ToooT_VST3"],
                swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .target(name: "ToooT_UI",
                dependencies: ["ToooT_Core", "ToooT_IO", "ToooT_Plugins", "ToooT_CLAP"],
                swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .executableTarget(name: "ProjectToooTApp",
                          dependencies: ["ToooT_UI"],
                          swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .executableTarget(name: "UATRunner",
                          dependencies: ["ToooT_Core", "ToooT_IO", "ToooT_UI", "ToooT_Plugins", "ToooT_CLAP"],
                          swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .executableTarget(name: "FuzzRunner",
                          dependencies: ["ToooT_Core", "ToooT_IO"],
                          swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .executableTarget(name: "StressRunner",
                          dependencies: ["ToooT_Core", "ToooT_IO"],
                          swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "ToooT_CoreTests",
                    dependencies: ["ToooT_Core", "ToooT_IO", "ToooT_UI", "ToooT_Plugins"],
                    swiftSettings: [.enableExperimentalFeature("StrictConcurrency")])
    ]
)
