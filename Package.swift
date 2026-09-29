// swift-tools-version: 6.2

import PackageDescription

let indieSearch: Target.Dependency = .product(name: "IndieSearch", package: "IndieLibKit")
let indieMetrics: Target.Dependency = .product(name: "IndieMetrics", package: "IndieLibKit")

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
        .library(name: "FastTabSync", targets: ["FastTabSync"]),
        .library(name: "HeroMotion", targets: ["HeroMotion"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.1"),
        // Shared L1 library, sibling checkout (~/01_Project/IndieLibKit on both Macs).
        // Only Foundation-only products are linked here: `IndieSearch` (the search
        // folding every app shares) and `IndieMetrics` (tab-activity statistics).
        .package(path: "../IndieLibKit")
    ],
    targets: [
        .target(
            name: "FastTabSync",
            dependencies: [indieSearch]
        ),
        // Onboarding hero timing math (loop / one-shot clock, easing), shared by
        // the Mac onboarding and the iPhone app (`ios/project.yml`). Foundation only.
        .target(
            name: "HeroMotion",
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
                "CommandBarKit",
                "HeroMotion",
                indieSearch,
                indieMetrics
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
            dependencies: ["CommandBarKit", indieSearch],
            path: "Sources/AgentBar"
        ),
        .testTarget(
            name: "FastTabTests",
            dependencies: ["FastTab", "FastTabSync", "CommandBarKit", indieSearch, indieMetrics]
        ),
        .testTarget(
            name: "AgentBarTests",
            dependencies: ["AgentBar", "CommandBarKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "CommandBarKitTests",
            dependencies: ["CommandBarKit"]
        ),
        .testTarget(
            name: "HeroMotionTests",
            dependencies: ["HeroMotion"]
        )
    ]
)
