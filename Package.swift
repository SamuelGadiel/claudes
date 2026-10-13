// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "claudes",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "ClaudeSCore",
            path: "Sources/ClaudeSCore"
        ),
        .executableTarget(
            name: "cs",
            dependencies: ["ClaudeSCore"],
            path: "Sources/cs"
        ),
        .executableTarget(
            name: "ClaudeSApp",
            dependencies: ["ClaudeSCore"],
            path: "Sources/ClaudeSApp",
            resources: [.process("Resources")]
        ),
    ]
)
