// swift-tools-version: 6.2

import PackageDescription

let indieSearch: Target.Dependency = .product(name: "IndieSearch", package: "indielibkit")
// Saved views (model, store, day buckets, keyword matcher) shared by Fast Tab and Agent Bar.
let indieSavedViews: Target.Dependency = .product(name: "IndieSavedViews", package: "indielibkit")
let indieMetrics: Target.Dependency = .product(name: "IndieMetrics", package: "indielibkit")
let indieMotion: Target.Dependency = .product(name: "IndieMotion", package: "indielibkit")
let indieEdgeReveal: Target.Dependency = .product(name: "IndieEdgeReveal", package: "indielibkit")
let indieEdgeRevealUI: Target.Dependency = .product(name: "IndieEdgeRevealUI", package: "indielibkit")
// Shared Mac settings window (sidebar, groups, navigator, Feedback pane).
let indieSettings: Target.Dependency = .product(name: "IndieSettings", package: "indielibkit")
let indieFeedbackUI: Target.Dependency = .product(name: "IndieFeedbackUI", package: "indielibkit")
let indieFeedback: Target.Dependency = .product(name: "IndieFeedback", package: "indielibkit")
let indieComments: Target.Dependency = .product(name: "IndieComments", package: "indielibkit")
let indieTable: Target.Dependency = .product(name: "IndieTable", package: "indielibkit")
let indieMCP: Target.Dependency = .product(name: "IndieMCP", package: "indielibkit")
let indieSharing: Target.Dependency = .product(name: "IndieSharing", package: "indielibkit")
let indieAccount: Target.Dependency = .product(name: "IndieAccount", package: "indielibkit")
let indieAgentSessions: Target.Dependency = .product(name: "IndieAgentSessions", package: "indielibkit")
let indieCommandBar: Target.Dependency = .product(name: "IndieCommandBar", package: "indielibkit")
// Browser profiles (Chromium profile list, Local State names, window-title profile), shared with MacLanes.
// Accessibility window control (raise a Claude window), shared with MacLanes.
let indieWorkspace: Target.Dependency = .product(name: "IndieWorkspace", package: "indielibkit")
let indieBrowserTabs: Target.Dependency = .product(name: "IndieBrowserTabs", package: "indielibkit")
// In-app updates (Sparkle 2.9.1, pinned exactly by IndieLibKit): the inline update banner.
let indieUpdate: Target.Dependency = .product(name: "IndieUpdate", package: "indielibkit")
// The shared setup wizard: window, step runner, permission step, "has onboarded" flag.
let indieOnboarding: Target.Dependency = .product(name: "IndieOnboarding", package: "indielibkit")

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
        // Shared L1 library (GitHub tektrg/indielibkit; was a sibling checkout until the edge-anchors API).
        // Linked here: `IndieSearch` (the search folding every app shares), `IndieMetrics`
        // (tab-activity statistics), `IndieMotion` (onboarding hero clock + stage) and
        // `IndieEdgeReveal` (notch/edge/corner hover trigger) + `IndieEdgeRevealUI` (the black
        // edge-hugging surface and its grow-out motion).
        // `IndieFeedback`/`IndieFeedbackUI` (Settings > About > Chat with the Creator…).
        // `IndieUpdate` (Sparkle updater + update banner wording; Sparkle comes in through it).
        // Dogfooding: the ONE shared L1 checkout on this machine (`~/01_Project/IndieLibKit`), not a
        // downloaded copy, so an L1 change is in the next build of every app. `macapp` keeps that
        // folder level with origin/main. A clone without the sibling folder must switch this back
        // to .package(url: "https://github.com/tektrg/indielibkit", branch: "main").
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
                indieSettings,
                indieUpdate,
                indieOnboarding,
                "FastTabSync",
                "FastTabReader",
                "FastTabWebReader",
                "ReadingConnector",
                indieMCP,
                indieCommandBar,
                indieBrowserTabs,
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
            dependencies: [indieCommandBar, indieSearch, indieSavedViews, indieAgentSessions, indieEdgeReveal, indieWorkspace, indieSettings],
            path: "Sources/AgentBar",
            exclude: ["AGENTS.md", "Markdown/Resources/pele.LICENSE"],
            // pele 1.6.0 (MIT) bundled as IIFE `Pele`; see Markdown/MermaidRenderer.swift.
            resources: [.copy("Markdown/Resources/pele.min.js")]
        ),
        .testTarget(
            name: "FastTabTests",
            dependencies: ["FastTab", "FastTabSync", "FastTabReader", "FastTabWebReader", "FastTabMCP", "ReadingConnector", indieSharing, indieCommandBar, indieSearch, indieSavedViews, indieMetrics, indieMotion, indieEdgeReveal, indieComments, indieTable, indieMCP, indieUpdate,
                           .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "AgentBarTests",
            dependencies: ["AgentBar", indieCommandBar, indieSearch, indieSavedViews, indieAgentSessions, indieEdgeReveal, indieSettings],
            resources: [.copy("Fixtures")]
        )
    ]
)
