import AppKit
import Foundation
import SwiftUI
import Testing
import IndieCommandBar
@testable import FastTab

/// What a keyboard-shortcut open of Fast Tab looks like, dark, drawn offscreen
/// from the real views: `scripts/render-shortcut-open.sh [dir] [before-dir]` →
/// `<dir>/sheet.png` (+ `before-after.png` next to `<dir>` when a before dir is
/// given). Env-gated (skipped in a normal `swift test`).
///
/// Panels: (a) Recents right after the shortcut (first row selected), (b) the
/// same after typing a 2-letter query, (c) Settings › Shortcuts with ⌃Tab.
/// Rows and panel height come from `ShortcutOpenRenderGlue` (this checkout's
/// `ContentView` logic, real functions); the bar is the real chrome pieces
/// (`CommandBarSurface`, `SearchHeader`, `SwipeableResultRow`,
/// `CommandBarActionRow`, `GuidanceBarView`, `ShortcutRecorderView`) laid out
/// as `ContentView.body` does. The Settings page is laid out as
/// `ShortcutsSettingsView` (which needs `AppState`, unbuildable in a test).
/// Glass/material backgrounds may draw flat offscreen.
@MainActor
struct ShortcutOpenRenderSheet {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["SHORTCUT_OPEN_RENDER_OUT"]
    nonisolated static let beforeDir = ProcessInfo.processInfo.environment["SHORTCUT_OPEN_RENDER_BEFORE"].flatMap { $0.isEmpty ? nil : $0 }
    nonisolated static let codeLabel = ProcessInfo.processInfo.environment["SHORTCUT_OPEN_RENDER_LABEL"] ?? "this checkout"

    static let anchor: CommandBarAnchor = .notch
    static let rowStyle: ResultRowStyle = .minimal
    static let query = "do"
    static let canvasMargin: CGFloat = 24
    static let settingsSize = CGSize(width: 560, height: 420)

    /// Made-up open tabs (no user data), most recent first.
    static let tabs: [BrowserSearchResult] = {
        let now = Date()
        let rows: [(String, String)] = [
            ("Pull request #482 · Fix flaky sync test · acme/web-app", "https://github.com/acme/web-app/pull/482"),
            ("Q4 planning – Google Docs", "https://docs.google.com/document/d/1q4-planning/edit"),
            ("Concurrency in practice – Swift Forums", "https://forums.swift.org/t/concurrency-in-practice/71234"),
            ("Onboarding v3 – Figma", "https://www.figma.com/file/abc123/Onboarding-v3"),
            ("Compose file reference | Docker Docs", "https://docs.docker.com/reference/compose-file/"),
            ("Hacker News", "https://news.ycombinator.com/"),
            ("SwiftUI ScrollViewReader jumps on appear – Stack Overflow", "https://stackoverflow.com/questions/78123456"),
            ("What's new in SwiftUI – WWDC – YouTube", "https://www.youtube.com/watch?v=wwdc-swiftui"),
            ("Sprint 42 board – Linear", "https://linear.app/acme/team/WEB/cycle/42"),
            ("NSPanel | Apple Developer Documentation", "https://developer.apple.com/documentation/appkit/nspanel"),
            ("Release checklist – Notion", "https://www.notion.so/acme/Release-checklist-8f2e"),
            ("San Francisco weather – 10-day forecast", "https://weather.com/weather/tenday/l/San+Francisco"),
            ("CSS grid layout – MDN Web Docs", "https://developer.mozilla.org/en-US/docs/Web/CSS/CSS_grid_layout"),
            ("Week of Nov 10 – Calendar", "https://calendar.google.com/calendar/u/0/r/week"),
        ]
        return rows.enumerated().map { i, row in
            BrowserSearchResult(
                title: row.0, url: row.1, browserName: "Google Chrome", type: .tab,
                timestamp: now.addingTimeInterval(-Double(30 + i * 240)),
                windowIndex: 1, tabIndex: i + 1
            )
        }
    }()

    /// Recents' results for `query`: open tabs by recency on an empty search,
    /// else the search box's match + sort.
    static func results(for query: String) -> [BrowserSearchResult] {
        if query.isEmpty { return allQuickOpenTabs(from: tabs) }
        return sortBrowserSearchResults(tabs.filter { $0.matches(query: query) })
    }

    // MARK: - The bar

    struct Bar: View {
        let query: String
        let shortcut: ShortcutStore
        @FocusState private var isSearchFocused: Bool

        var items: [CommandBarDisplayItem] {
            ShortcutOpenRenderGlue.listItems(results: results(for: query), query: query, rowStyle: rowStyle)
        }
        var maxRows: Int {
            ShortcutOpenRenderGlue.maxRows(query: query, anchor: anchor, rowStyle: rowStyle, showFooter: true)
        }
        static func surfaceSize(maxRows: Int) -> CGSize {
            CommandBarLayout.surfaceSize(for: anchor, rowStyle: rowStyle, rowCount: Int.max, maxRows: maxRows, showFooter: true)
        }

        var hint: GuidanceHint {
            var state = CommandBarGuidanceState()
            state.cycleKeyGlyph = shortcut.keyDisplayName
            state.cycleModifierGlyph = shortcut.modifierSymbols
            state.isSearchFocused = true
            state.selectedIndex = 0
            state.hasResults = !items.isEmpty
            state.queryIsEmpty = query.isEmpty
            return CommandBarGuidance.hint(for: state, words: ContentView.guidanceWords)
        }

        var body: some View {
            let items = items
            let size = Self.surfaceSize(maxRows: maxRows)
            let resultsHeight = CommandBarLayout.resultsHeight(for: anchor, rowStyle: rowStyle, rowCount: Int.max)
            CommandBarSurface(anchor: anchor, outerPanelEnabled: true) {
                VStack(spacing: CommandBarLayout.interSectionSpacing) {
                    SearchHeader(
                        searchText: .constant(query),
                        isSearchFocused: $isSearchFocused,
                        scopeChips: [],
                        activeAlias: nil,
                        onRemoveAlias: {},
                        focusedChipID: nil,
                        onRemoveChip: { _ in },
                        onFocusChip: { _ in },
                        onBackspaceAtEmpty: {},
                        onLeftArrowAtEmpty: {},
                        onUpArrow: {},
                        onDownArrow: {},
                        activeView: .recents,
                        viewTabs: CommandBarViewTab.tabs(for: [.recents, .stack], customViews: []),
                        onSelectView: { _ in },
                        onEditView: { _ in },
                        onDeleteView: { _ in }
                    )
                    VStack(spacing: 0) {
                        CommandBarSectionedList(
                            sections: [CommandBarSection(id: "items", rows: items)],
                            selectedIndex: 0,
                            followsSelection: false
                        ) { item, index in
                            row(item, isSelected: index == 0)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .commandBarResultsFrame(minHeight: resultsHeight)
                    CommandBarFooterBar {
                        HStack(spacing: 0) {
                            GuidanceBarView(
                                hint: hint,
                                statusText: "\(tabs.count) tabs found",
                                hoveredResult: rowStyle == .minimal ? items.first?.result : nil
                            )
                            Spacer(minLength: 12)
                            ShortcutRecorderView(store: shortcut, showsSettingsButton: true)
                        }
                    }
                }
                .padding(12)
                .padding(.top, CommandBarLayout.surfaceTopInset(for: anchor))
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()
            }
            .environment(\.isCompactCommandBar, CommandBarLayout.isCompact(anchor))
            .environment(\.commandBarTheme, CommandBarTheme(accent: .system))
        }

        /// `ContentView.displayItemRow` for the cases Recents can show here.
        @ViewBuilder
        func row(_ item: CommandBarDisplayItem, isSelected: Bool) -> some View {
            switch item {
            case .result(let result):
                SwipeableResultRow(
                    result: result, isSelected: isSelected, faviconImage: nil,
                    showWindowName: false, showProfileName: false,
                    pointerEdge: nil, pointerOffset: 0, keyboardEdge: nil, isConfirmingRemoval: false,
                    onHoverChange: { _ in }, onSelect: {}, onCopy: {}, onRemove: {}
                )
                .padding(.horizontal, 8)
            default:
                if let row = item.actionRow(webSearchBrowserName: "Google Chrome", aliasTriggerKeys: []) {
                    CommandBarActionRow(row: row, isSelected: isSelected)
                        .padding(.horizontal, 8)
                }
            }
        }
    }

    /// The bar flush against the top of a desktop-coloured canvas, the way the
    /// notch anchor draws it. Every bar canvas is the tallest the bar can be,
    /// so panels line up and a shorter bar shows as empty desktop below it.
    struct BarCanvas: View {
        let query: String
        let shortcut: ShortcutStore
        static var size: CGSize {
            let tall = Bar.surfaceSize(maxRows: CommandBarLayout.expandedAllTabsMaxRows(for: anchor, rowStyle: rowStyle, showFooter: true))
            return CGSize(width: tall.width + 2 * canvasMargin, height: max(tall.height, CommandBarLayout.expandedAllTabsMaxHeight) + canvasMargin)
        }
        var body: some View {
            Bar(query: query, shortcut: shortcut)
                .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
                .background(Color(red: 0.16, green: 0.18, blue: 0.24))
        }
    }

    /// `ShortcutsSettingsView.body`, with the real recorder and caption.
    struct SettingsPage: View {
        let shortcut: ShortcutStore
        var body: some View {
            Form {
                Section("Primary Shortcut") {
                    HStack {
                        Text("Global shortcut")
                        Spacer()
                        ShortcutRecorderView(store: shortcut)
                    }
                    if let caption = ShortcutOpenRenderGlue.shortcutCaption(modifiers: shortcut.modifiers, keyName: shortcut.keyDisplayName) {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Default view", selection: .constant(CommandBarView.recents)) {
                        Text(CommandBarView.recents.displayName(customViews: [])).tag(CommandBarView.recents)
                    }
                }
                Section("Direct View Shortcuts") {
                    Text("Open FastTab directly to a specific view.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach([CommandBarView.recents, .stack], id: \.self) { view in
                        HStack {
                            Label(view.displayName(customViews: []), systemImage: view.iconName(customViews: []))
                            Spacer()
                            ShortcutRecorderView(displayString: "None", onRecord: { _, _, _ in })
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(width: settingsSize.width, height: settingsSize.height)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    // MARK: - Render

    static func render<V: View>(_ view: V, size: CGSize) throws -> CGImage {
        let appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        let layer = try #require(host.layer)
        let scale: CGFloat = 2
        let ctx = try #require(CGContext(
            data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.translateBy(x: 0, y: size.height * scale)
        ctx.scaleBy(x: scale, y: -scale)
        var drawn = false
        appearance?.performAsCurrentDrawingAppearance {
            layer.render(in: ctx)
            drawn = true
        }
        #expect(drawn)
        return try #require(ctx.makeImage())
    }

    @Test(.enabled(if: ShortcutOpenRenderSheet.outDir != nil))
    func sheet() throws {
        let out = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "test.fasttab.shortcutopen.\(UUID().uuidString)"))
        let shortcut = ShortcutStore(defaults: defaults)
        shortcut.update(keyCode: 48, modifiers: .control, keyName: "Tab")

        let barSize = BarCanvas.size
        let panels: [(file: String, title: String, image: CGImage, size: CGSize)] = [
            ("a-shortcut-open", "(a) Opened with \(shortcut.displayString): \(Self.tabs.count) open tabs, first row selected",
             try Self.render(BarCanvas(query: "", shortcut: shortcut), size: barSize), barSize),
            ("b-typed-query", "(b) Then typed \u{201C}\(Self.query)\u{201D}",
             try Self.render(BarCanvas(query: Self.query, shortcut: shortcut), size: barSize), barSize),
            ("c-settings-shortcuts", "(c) Settings \u{203A} Shortcuts",
             try Self.render(SettingsPage(shortcut: shortcut), size: Self.settingsSize), Self.settingsSize),
        ]
        for panel in panels {
            try Self.writePNG(NSImage(cgImage: panel.image, size: panel.size), to: out.appendingPathComponent("\(panel.file).png"))
        }
        let sheet = Self.column(title: Self.codeLabel, panels: panels.map { ($0.title, NSImage(cgImage: $0.image, size: $0.size)) })
        try Self.writePNG(sheet, to: out.appendingPathComponent("sheet.png"))

        if let beforeDir = Self.beforeDir {
            let before = try #require(NSImage(contentsOf: URL(fileURLWithPath: beforeDir).appendingPathComponent("sheet.png")))
            let combined = Self.sideBySide([("Before (main)", before, .systemRed), ("After (branch)", sheet, .systemGreen)])
            try Self.writePNG(combined, to: out.deletingLastPathComponent().appendingPathComponent("before-after.png"))
        }
    }

    // MARK: - Sheet drawing

    static let labelFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let ink = NSColor(white: 0.12, alpha: 1)

    /// Panels stacked top to bottom, each under its title; `title` on top.
    static func column(title: String, panels: [(String, NSImage)]) -> NSImage {
        let pad: CGFloat = 16, labelH: CGFloat = 26, headerH: CGFloat = 30
        let width = (panels.map(\.1.size.width).max() ?? 0) + 2 * pad
        let height = headerH + panels.reduce(0) { $0 + labelH + $1.1.size.height + pad } + pad
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocusFlipped(true)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        (title as NSString).draw(at: NSPoint(x: pad, y: 8), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.gray])
        var y = headerH
        for (label, panel) in panels {
            (label as NSString).draw(at: NSPoint(x: pad, y: y + 4), withAttributes: [.font: labelFont, .foregroundColor: ink])
            y += labelH
            panel.draw(in: NSRect(x: pad, y: y, width: panel.size.width, height: panel.size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            y += panel.size.height + pad
        }
        image.unlockFocus()
        return image
    }

    static func sideBySide(_ columns: [(String, NSImage, NSColor)]) -> NSImage {
        let headerH: CGFloat = 44, gap: CGFloat = 8
        let width = columns.reduce(0) { $0 + $1.1.size.width } + gap * CGFloat(columns.count - 1)
        let height = headerH + (columns.map(\.1.size.height).max() ?? 0)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocusFlipped(true)
        NSColor(white: 0.85, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        var x: CGFloat = 0
        for (label, column, color) in columns {
            NSColor.white.setFill()
            NSRect(x: x, y: 0, width: column.size.width, height: height).fill()
            (label as NSString).draw(at: NSPoint(x: x + 16, y: 10), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: color])
            column.draw(in: NSRect(x: x, y: headerH, width: column.size.width, height: column.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += column.size.width + gap
        }
        image.unlockFocus()
        return image
    }

    /// Written at 2x the image's point size.
    static func writePNG(_ image: NSImage, to url: URL) throws {
        let size = image.size
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
