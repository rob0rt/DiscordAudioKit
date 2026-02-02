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
        .package(url: "git@github.com:hummingbird-project/swift-websocket.git", from: "1.3.2"),
        .package(url: "git@github.com:apple/swift-log.git", from: "1.9.0"),
        .package(url: "git@github.com:apple/swift-async-algorithms.git", from: "1.1.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "DiscordAudioKit",
            dependencies: [
                .product(name: "DaveKit", package: "DaveKit"),
                .product(name: "OpusKit", package: "OpusKit"),
                .product(name: "WSClient", package: "swift-websocket"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "Crypto", package: "swift-crypto"),
                .target(name: "DiscordRTP"),
            ],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
            ],
        ),

        .target(
            name: "DiscordRTP",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
            ],
        ),

        .testTarget(
            name: "DiscordAudioKitTests",
            dependencies: ["DiscordAudioKit"]
        ),
    ]
)
