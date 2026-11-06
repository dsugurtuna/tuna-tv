// swift-tools-version:5.10
// TunaCore: everything in Tuna TV that is not UI. Foundation-only, so it builds and is unit-tested
// on Linux (Docker swift:6.2) as well as macOS. Swift 5 language mode on purpose.
import PackageDescription

let package = Package(
    name: "TunaCore",
    platforms: [.macOS("15.0")],
    products: [
        .library(name: "TunaCore", targets: ["TunaCore"]),
    ],
    targets: [
        .target(
            name: "TunaCore",
            path: "Sources/TunaCore"
        ),
        .testTarget(
            name: "TunaCoreTests",
            dependencies: ["TunaCore"],
            path: "Tests/TunaCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
