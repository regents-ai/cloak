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
        .target(name: "CloakChat", dependencies: ["CloakControl", .product(name: "CloakHost", package: "host")]),
        .target(name: "CloakDoor", dependencies: ["CloakControl", "CloakSupervisor", "CloakChat"]),
        .executableTarget(name: "RegentsCloak", dependencies: ["CloakControl", "CloakSupervisor", "CloakChat", "CloakDoor"]),
        .executableTarget(
            name: "cloak",
            dependencies: ["CloakControl", .product(name: "ArgumentParser", package: "swift-argument-parser")]),
        .testTarget(
            name: "CloakTests",
            dependencies: [
                "CloakControl", "CloakSupervisor", "CloakChat", "CloakDoor", "RegentsCloak",
                .product(name: "CloakHost", package: "host"),
            ]),
    ]
)
