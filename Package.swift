// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Multiharness",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MultiharnessCore",
            targets: ["MultiharnessCore"]
        ),
        .executable(
            name: "Multiharness",
            targets: ["Multiharness"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MultiharnessCore",
            dependencies: [],
            path: "Sources/MultiharnessCore"
        ),
        .executableTarget(
            name: "Multiharness",
            dependencies: ["MultiharnessCore"],
            path: "Sources/Multiharness"
        ),
        .testTarget(
            name: "MultiharnessCoreTests",
            dependencies: ["MultiharnessCore"],
            path: "Tests/MultiharnessCoreTests"
        ),
    ]
)
