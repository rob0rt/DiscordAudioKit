// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DiscordAudioKit",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "DiscordAudioKit",
            targets: ["DiscordAudioKit"]
        ),
    ],
    dependencies: [
        .package(url: "git@github.com:rob0rt/DaveKit.git", branch: "main"),
        .package(url: "git@github.com:rob0rt/OpusKit.git", branch: "main"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "DiscordAudioKit",
            dependencies: [
                .product(name: "DaveKit", package: "DaveKit"),
                .product(name: "OpusKit", package: "OpusKit"),
            ],
        ),
        .testTarget(
            name: "DiscordAudioKitTests",
            dependencies: ["DiscordAudioKit"]
        ),
    ]
)
