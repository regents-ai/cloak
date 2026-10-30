// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "cloak-host",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "cloak-host")
    ]
)
