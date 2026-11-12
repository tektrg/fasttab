import AppKit
import IndieCommandBar
import SwiftUI
import Testing
@testable import FastTab

/// Renders the custom view builder (form + footer, unscrolled so every row
/// shows) at each width the command bar can have, dark mode, to PNGs — to
/// check nothing is clipped. A tool, not a check: it only runs when
/// `CUSTOM_VIEW_EDITOR_RENDER_OUT` is set (`scripts/render-custom-view-editor.sh`).
///
/// Drawn through an offscreen `NSHostingView` (`cacheDisplay`) so the
/// AppKit-backed controls (text fields, segmented pickers, menus) render for
/// real; `ImageRenderer` only draws placeholders for those.
@MainActor
struct CustomViewEditorRenderSheet {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["CUSTOM_VIEW_EDITOR_RENDER_OUT"]

    /// Editor widths: the bar's surface minus `mainContent`'s 12pt padding
    /// each side (`ContentView`), and the Settings › Views sheet.
    static let widths: [(name: String, width: CGFloat)] = [
        ("edge-narrow", CommandBarLayout.edgeSurfaceWidth - 24),
        // Same, less a 16pt legacy scroller ("Show scroll bars: Always").
        ("edge-narrow-scroller", CommandBarLayout.edgeSurfaceWidth - 24 - 16),
        ("notch-minimal", (CommandBarLayout.surfaceWidth * CommandBarLayout.minimalWidthFraction).rounded(.down) - 24),
        ("notch-full", CommandBarLayout.surfaceWidth - 24),
        ("settings-sheet", 520),
    ]

    static let profileOptions: [CustomViewProfileOption] = [
        ("Default", "Google Chrome"), ("AptusFit", "Microsoft Edge"), ("Work — Seven Lab Data Team", "Google Chrome"),
        ("Person 1", "Brave Browser"), ("Personal shopping and travel", "Microsoft Edge"),
        ("Default", "Arc"), ("Testing profile with a very long name", "Vivaldi"),
    ].map { CustomViewProfileOption(name: $0.0, browsers: [$0.1], showsBrowsers: true) }

    static func richDraft(profiles: [String]) -> CustomViewDraft {
        var draft = CustomViewDraft(view: CustomView(
            name: "Long-form reading from every work profile",
            iconName: "newspaper",
            types: [.tab, .bookmark],
            profiles: profiles,
            domains: ["developer.apple.com", "docs.swift.org", "forums.swift.org", "github.com/apple/swift-evolution"],
            keywords: "concurrency actors sendable migration guide",
            pinned: .exclude,
            semanticPrompt: "Long articles and design proposals I meant to read properly but only skimmed",
            groupBy: .domain
        ))
        draft.domainsText = "developer.apple.com, docs.swift.org, forums.swift.org, github.com"
        return draft
    }

    @Test(.enabled(if: CustomViewEditorRenderSheet.outDir != nil))
    func renderEditor() throws {
        let out = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let threeProfiles = ["AptusFit", "Work — Seven Lab Data Team", "Personal shopping and travel"]
        for (name, width) in Self.widths {
            try Self.write(
                Self.editor(draft: Self.richDraft(profiles: threeProfiles), width: width, count: 67, isConfirmingDelete: false),
                width: width, to: out.appendingPathComponent("editor-\(name)-dark.png")
            )
        }
        let narrow = Self.widths[0].width
        // Profile menu label states + the delete confirmation, at the narrowest width.
        try Self.write(
            Self.editor(draft: Self.richDraft(profiles: []), width: narrow, count: 1_204, isConfirmingDelete: false, isNew: true),
            width: narrow, to: out.appendingPathComponent("editor-edge-narrow-new-any-profile-dark.png")
        )
        try Self.write(
            Self.editor(draft: Self.richDraft(profiles: ["Testing profile with a very long name"]), width: narrow, count: 3, isConfirmingDelete: false),
            width: narrow, to: out.appendingPathComponent("editor-edge-narrow-one-profile-dark.png")
        )
        try Self.write(
            Self.editor(draft: Self.richDraft(profiles: threeProfiles), width: narrow, count: 67, isConfirmingDelete: true),
            width: narrow, to: out.appendingPathComponent("editor-edge-narrow-confirm-delete-dark.png")
        )
    }

    // MARK: - Views

    static func editor(draft: CustomViewDraft, width: CGFloat, count: Int, isConfirmingDelete: Bool, isNew: Bool = false) -> some View {
        VStack(spacing: 0) {
            CustomViewEditorForm(
                draft: .constant(draft),
                profileOptions: profileOptions
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            CustomViewEditorFooter(
                draft: draft,
                isNew: isNew,
                matchCountText: CustomViewEditorFooter.matchCountText(count: count, hasSemanticFilter: true),
                isConfirmingDelete: .constant(isConfirmingDelete),
                onCancel: {},
                onSave: {},
                onDelete: isNew ? nil : {}
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .controlSize(.small)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        // The bar's dark panel, with a 1pt outline so clipping at the edge shows.
        .background(Color(white: 0.11))
        .overlay(Rectangle().strokeBorder(Color.red.opacity(0.7), lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Rendering

    static func write(_ view: some View, width: CGFloat, to url: URL) throws {
        let host = NSHostingView(rootView: AnyView(view))
        host.appearance = NSAppearance(named: .darkAqua)
        let fitting = host.fittingSize
        let size = CGSize(width: width, height: max(fitting.height, 40))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // One run-loop turn so SwiftUI commits the AppKit controls.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()

        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        window.orderOut(nil)
    }
}
