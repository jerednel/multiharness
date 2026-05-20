// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Multiharness",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "MultiharnessClient",
            targets: ["MultiharnessClient"]
        ),
        .library(
            name: "MultiharnessCore",
            targets: ["MultiharnessCore"]
        ),
        .executable(
            name: "Multiharness",
            targets: ["Multiharness"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        // PTY + xterm-compatible terminal emulator for the embedded
        // floating terminal overlay. macOS-only — the iOS companion
        // doesn't use it, so the dep is wired to the executable target
        // rather than MultiharnessClient.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0"),
    ],
    targets: [
        // Portable code that ships in BOTH the macOS app and the iOS companion:
        // models, ConversationTurn, ControlClient (URLSessionWebSocketTask), Keychain wrapper.
        .target(
            name: "MultiharnessClient",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/MultiharnessClient"
        ),
        // macOS-only: persistence (SQLite), worktree (git subprocess),
        // sidecar lifecycle, bookmarks, RemoteAccess (Bonjour register).
        .target(
            name: "MultiharnessCore",
            dependencies: ["MultiharnessClient"],
            path: "Sources/MultiharnessCore"
        ),
        .executableTarget(
            name: "Multiharness",
            dependencies: [
                "MultiharnessCore",
                "MultiharnessClient",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/Multiharness",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MultiharnessCoreTests",
            dependencies: ["MultiharnessCore", "MultiharnessClient"],
            path: "Tests/MultiharnessCoreTests"
        ),
    ]
)
