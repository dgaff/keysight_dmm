// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeysightDMM",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "DMMKit", targets: ["DMMKit"]),
        .executable(name: "dmmprobe", targets: ["dmmprobe"]),
    ],
    targets: [
        // Instrument layer: transport, SCPI codec, units, discovery, simulator. No UI imports.
        .target(name: "DMMKit", resources: [.process("Resources")]),
        // Command-line probe used for bench tests and undocumented-command hunting.
        .executableTarget(name: "dmmprobe", dependencies: ["DMMKit"]),
        // The macOS app. Bundle it with scripts/make_app.sh.
        .executableTarget(name: "KeysightDMMApp", dependencies: ["DMMKit"]),
        .testTarget(name: "DMMKitTests", dependencies: ["DMMKit"]),
    ]
)
