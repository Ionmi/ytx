// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "ytx",
    platforms: [.macOS("26")],
    products: [
        .executable(name: "ytx", targets: ["ytx"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        .executableTarget(
            name: "ytx",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources"
        ),
    ]
)
