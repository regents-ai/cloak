// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RegentsCloak",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../host"),
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
    ],
    targets: [
        .target(name: "CloakControl"),
        .target(
            name: "CloakSupervisor",
            dependencies: ["CloakControl", .product(name: "CloakHost", package: "host")]),
        .executableTarget(name: "RegentsCloak", dependencies: ["CloakControl", "CloakSupervisor"]),
        .executableTarget(
            name: "cloak",
            dependencies: ["CloakControl", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(
            name: "CloakTests",
            dependencies: ["CloakControl", "CloakSupervisor", .product(name: "CloakHost", package: "host")]),
    ]
)
