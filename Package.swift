// swift-tools-version: 6.2

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
        .executable(name: "AgentBar", targets: ["AgentBar"]),
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
        // Reusable command-bar building blocks shared with future apps.
        // No dependencies and no resources on purpose: it links statically into
        // the app binary, so `build-app.sh` keeps copying a single executable.
        .target(
            name: "CommandBarKit",
            dependencies: []
        ),
        .executableTarget(
            name: "FastTab",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "FastTabSync",
                "CommandBarKit"
            ]
        ),
        // Pure stdio<->socket relay launched by Chrome's native messaging.
        // Intentionally no dependency on the app target.
        .executableTarget(
            name: "FastTabNativeHost"
        ),
        // Read-only agent switcher. Standalone app: no Sparkle, no FastTabSync.
        .executableTarget(
            name: "AgentBar",
            dependencies: ["CommandBarKit"],
            path: "Sources/AgentBar"
        ),
        .testTarget(
            name: "FastTabTests",
            dependencies: ["FastTab", "FastTabSync", "CommandBarKit"]
        ),
        .testTarget(
            name: "AgentBarTests",
            dependencies: ["AgentBar", "CommandBarKit"]
        ),
        .testTarget(
            name: "CommandBarKitTests",
            dependencies: ["CommandBarKit"]
        )
    ]
)
