// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexUsageOverlay",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CodexUsageOverlay", targets: ["CodexUsageOverlay"])
    ],
    targets: [
        .executableTarget(name: "CodexUsageOverlay")
    ]
)
