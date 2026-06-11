// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FastTabPackage",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FastTab", targets: ["FastTab"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.1")
    ],
    targets: [
        .executableTarget(
            name: "FastTab",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .testTarget(
            name: "FastTabTests",
            dependencies: ["FastTab"]
        )
    ]
)
