// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Inverterly",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Inverterly", targets: ["Inverterly"]),
        .library(name: "InverterCore", targets: ["InverterCore"]),
    ],
    targets: [
        // Cloud client, parsing and the data model. No UI.
        .target(name: "InverterCore"),
        // The status item, panel views and the animated heroes.
        .target(name: "InverterUI", dependencies: ["InverterCore"]),
        .executableTarget(name: "Inverterly", dependencies: ["InverterCore", "InverterUI"]),
        // Prints one live reading and the size of today's curve. Read-only, no secrets in the output.
        .executableTarget(name: "InverterProbe", dependencies: ["InverterCore"]),
        .testTarget(name: "InverterCoreTests", dependencies: ["InverterCore"]),
        .testTarget(name: "InverterUITests", dependencies: ["InverterCore", "InverterUI"]),
    ],
    swiftLanguageModes: [.v5]
)
