// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RegentsCloak",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(path: "../host"),
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.8.1"),
    ],
    targets: [
        .target(name: "CloakControl"),
        .target(
            name: "CloakSupervisor",
            dependencies: ["CloakControl", .product(name: "CloakHost", package: "host")]),
        .target(name: "CloakChat", dependencies: ["CloakControl", .product(name: "CloakHost", package: "host")]),
        .target(name: "CloakDarkbloom"),
        .target(name: "CloakDoor", dependencies: ["CloakControl", "CloakSupervisor", "CloakChat"]),
        .executableTarget(
            name: "RegentsCloak",
            dependencies: [
                "CloakControl", "CloakSupervisor", "CloakChat", "CloakDarkbloom", "CloakDoor",
                .product(name: "Sparkle", package: "Sparkle"),
            ]),
        .executableTarget(
            name: "CloakWidgets",
            dependencies: ["CloakControl"]),
        .executableTarget(
            name: "cloak",
            dependencies: ["CloakControl", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(
            name: "CloakTests",
            dependencies: [
                "CloakChat", "CloakDarkbloom", "CloakDoor", "CloakSupervisor", .product(name: "CloakHost", package: "host"),
            ]),
    ]
)
