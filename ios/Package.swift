// swift-tools-version: 6.0
// The sync engine's pure rules, tested on the Mac with `swift test` (no
// simulator). The app compiles the same files directly from CanWeGo/SyncCore.
import PackageDescription

let package = Package(
    name: "SyncCore",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SyncCore", path: "CanWeGo/SyncCore"),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore"], path: "SyncCoreTests"),
    ]
)
