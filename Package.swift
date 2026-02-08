// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ytx",
    platforms: [.macOS("26")],
    products: [
        .executable(name: "ytx", targets: ["ytx"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
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
