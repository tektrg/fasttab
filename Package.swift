// swift-tools-version: 6.2

import PackageDescription

let indieSearch: Target.Dependency = .product(name: "IndieSearch", package: "IndieLibKit")
// Saved views (model, store, day buckets, keyword matcher) shared by Fast Tab and Agent Bar.
let indieSavedViews: Target.Dependency = .product(name: "IndieSavedViews", package: "IndieLibKit")
let indieMetrics: Target.Dependency = .product(name: "IndieMetrics", package: "IndieLibKit")
let indieMotion: Target.Dependency = .product(name: "IndieMotion", package: "IndieLibKit")
let indieEdgeReveal: Target.Dependency = .product(name: "IndieEdgeReveal", package: "IndieLibKit")
let indieEdgeRevealUI: Target.Dependency = .product(name: "IndieEdgeRevealUI", package: "IndieLibKit")
let indieFeedbackUI: Target.Dependency = .product(name: "IndieFeedbackUI", package: "IndieLibKit")
let indieFeedback: Target.Dependency = .product(name: "IndieFeedback", package: "IndieLibKit")
let indieComments: Target.Dependency = .product(name: "IndieComments", package: "IndieLibKit")
let indieTable: Target.Dependency = .product(name: "IndieTable", package: "IndieLibKit")
let indieMCP: Target.Dependency = .product(name: "IndieMCP", package: "IndieLibKit")
let indieSharing: Target.Dependency = .product(name: "IndieSharing", package: "IndieLibKit")
let indieAccount: Target.Dependency = .product(name: "IndieAccount", package: "IndieLibKit")
let indieAgentSessions: Target.Dependency = .product(name: "IndieAgentSessions", package: "IndieLibKit")
let indieCommandBar: Target.Dependency = .product(name: "IndieCommandBar", package: "IndieLibKit")

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
        .executable(name: "FastTabMCP", targets: ["FastTabMCP"]),
        .library(name: "FastTabSync", targets: ["FastTabSync"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.1"),
        // Shared L1 library, sibling checkout (~/01_Project/IndieLibKit on both Macs).
        // Linked here: `IndieSearch` (the search folding every app shares), `IndieMetrics`
        // (tab-activity statistics), `IndieMotion` (onboarding hero clock + stage) and
        // `IndieEdgeReveal` (notch/edge/corner hover trigger) + `IndieEdgeRevealUI` (the black
        // edge-hugging surface and its grow-out motion).
        // `IndieFeedback`/`IndieFeedbackUI` (Settings > About > Chat with the Creator…).
        .package(path: "../IndieLibKit"),
        // The reading connector's search index (FTS5). Same package IndieLibKit already pulls in.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "FastTabSync",
            // IndieComments: reader comment threads synced by ReaderSyncBridge.
            dependencies: [indieSearch, indieComments]
        ),
        // The phone's reader highlights + comment threads as the Mac sees them: the synced
        // mirror, the Highlights table (IndieTable views) and comment actions. Shared by the
        // app's Settings page and the FastTabMCP helper, so both show the same views.
        .target(
            name: "FastTabReader",
            dependencies: ["FastTabSync", indieComments, indieTable]
        ),
        // Experimental web reader (fasttab.theindie.app/web): E2E-encrypted snapshot upload,
        // browser highlights inbox. Contract: memory/Projects/fasttab-web-reader/contract.md.
        .target(
            name: "FastTabWebReader",
            dependencies: ["FastTabSync", indieSharing]
        ),
        // The reading connector's engine (read-only): the List, the phone's reading activity,
        // highlights + threads. Shared by the fasttab-mcp tools and the `fasttab` CLI.
        .target(
            name: "ReadingConnector",
            dependencies: ["FastTabSync", "FastTabReader", indieComments, indieMCP,
                           .product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Stdio MCP server bundled in the app (Contents/MacOS/fasttab-mcp): the read-only
        // reading connector + comment-thread tools. Also the `fasttab` CLI (`fasttab-mcp cli …`,
        // or symlinked as `fasttab`).
        .executableTarget(
            name: "FastTabMCP",
            dependencies: ["FastTabReader", "ReadingConnector", indieComments, indieMCP]
        ),
        .executableTarget(
            name: "FastTab",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "FastTabSync",
                "FastTabReader",
                "FastTabWebReader",
                "ReadingConnector",
                indieMCP,
                indieCommandBar,
                indieSearch,
                indieSavedViews,
                indieSharing,
                indieAccount,
                indieMetrics,
                indieMotion,
                indieEdgeReveal,
                indieFeedback,
                indieFeedbackUI
            ]
        ),
        // Pure stdio<->socket relay launched by Chrome's native messaging.
        // Intentionally no dependency on the app target.
        .executableTarget(
            name: "FastTabNativeHost"
        ),
        // Agent switcher (⌥Tab panel). Standalone app: no Sparkle, no FastTabSync.
        .executableTarget(
            name: "AgentBar",
            dependencies: [indieCommandBar, indieSearch, indieSavedViews, indieAgentSessions, indieEdgeReveal],
            path: "Sources/AgentBar"
        ),
        .testTarget(
            name: "FastTabTests",
            dependencies: ["FastTab", "FastTabSync", "FastTabReader", "FastTabWebReader", "FastTabMCP", "ReadingConnector", indieSharing, indieCommandBar, indieSearch, indieSavedViews, indieMetrics, indieMotion, indieEdgeReveal, indieComments, indieTable, indieMCP,
                           .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "AgentBarTests",
            dependencies: ["AgentBar", indieCommandBar, indieSearch, indieSavedViews, indieAgentSessions],
            resources: [.copy("Fixtures")]
        )
    ]
)
