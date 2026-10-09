// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "claude-switcher",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "ClaudeSwitcherCore",
            path: "Sources/ClaudeSwitcherCore"
        ),
        .executableTarget(
            name: "cs",
            dependencies: ["ClaudeSwitcherCore"],
            path: "Sources/cs"
        ),
        .executableTarget(
            name: "ClaudeSwitcherApp",
            dependencies: ["ClaudeSwitcherCore"],
            path: "Sources/ClaudeSwitcherApp"
        ),
    ]
)
