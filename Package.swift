// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CPUSentinel",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything that decides: sampling, detection, policy, safety, killing. No UI.
        .target(name: "SentinelCore"),
        // The menu bar app. Thin: it renders SentinelCore's state and forwards clicks.
        .executableTarget(name: "CPUSentinel", dependencies: ["SentinelCore"]),
        .testTarget(name: "SentinelCoreTests", dependencies: ["SentinelCore"]),
    ]
)
