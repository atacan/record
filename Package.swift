// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "record",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "record", targets: ["record"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "record",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
        ),
        .testTarget(
            name: "recordTests",
            dependencies: ["record"]
        ),
    ]
)
