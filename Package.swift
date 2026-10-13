// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InverterBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "InverterBar", targets: ["InverterBar"]),
        .library(name: "InverterCore", targets: ["InverterCore"]),
    ],
    targets: [
        // Cloud client, parsing and the data model. No UI.
        .target(name: "InverterCore"),
        // Panel views and the animated heroes, shared by the app and the render lab.
        .target(name: "InverterUI", dependencies: ["InverterCore"]),
        .executableTarget(name: "InverterBar", dependencies: ["InverterCore", "InverterUI"]),
        // Prints one live reading and the size of today's curve. Read-only, no secrets in the output.
        .executableTarget(name: "InverterProbe", dependencies: ["InverterCore"]),
        .testTarget(name: "InverterCoreTests", dependencies: ["InverterCore"]),
    ],
    swiftLanguageModes: [.v5]
)
