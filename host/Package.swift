// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "cloak-host",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CloakHost", targets: ["CloakHost"])
    ],
    targets: [
        .target(name: "CloakHost"),
        .executableTarget(name: "cloak-host", dependencies: ["CloakHost"]),
    ]
)
