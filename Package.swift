// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FastTabPackage",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "FastTab", targets: ["FastTab"]),
        .executable(name: "FastTabNativeHost", targets: ["FastTabNativeHost"]),
        .library(name: "FastTabSync", targets: ["FastTabSync"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.1")
    ],
    targets: [
        .target(
            name: "FastTabSync",
            dependencies: []
        ),
        .executableTarget(
            name: "FastTab",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "FastTabSync"
            ]
        ),
        // Pure stdio<->socket relay launched by Chrome's native messaging.
        // Intentionally no dependency on the app target.
        .executableTarget(
            name: "FastTabNativeHost"
        ),
        .testTarget(
            name: "FastTabTests",
            dependencies: ["FastTab", "FastTabSync"]
        )
    ]
)
