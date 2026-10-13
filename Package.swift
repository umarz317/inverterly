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
        // Renders heroes and the panel to PNG so the design can be checked without opening the menu bar.
        .executableTarget(name: "HeroLab", dependencies: ["InverterCore", "InverterUI"]),
        // Prints one live reading and the size of today's curve. Read-only, no secrets in the output.
        .executableTarget(name: "InverterProbe", dependencies: ["InverterCore"]),
        // Renders the demo video frame by frame from the app's own views (see Tools/demo-video).
        .executableTarget(name: "DemoVideo", dependencies: ["InverterCore", "InverterUI"]),
        .testTarget(name: "InverterCoreTests", dependencies: ["InverterCore"]),
    ],
    swiftLanguageModes: [.v5]
)
