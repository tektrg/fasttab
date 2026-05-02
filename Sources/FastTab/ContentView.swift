import SwiftUI
import AppKit

private let kSpaceKeyCode: UInt16 = 49
private let kEnterKeyCode: UInt16 = 36
private let kEscapeKeyCode: UInt16 = 53
private let kUpArrowKeyCode: UInt16 = 126
private let kDownArrowKeyCode: UInt16 = 125

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var appState: AppState
    @StateObject private var updateService = UpdateService.shared
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var localMonitor: Any?
    /// True once the user has cycled to a tab via the shortcut; reset when the bar opens.
    @State private var hasCycled = false
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var faviconPrefetchDebounceTask: Task<Void, Never>?
    @State private var suppressNextSearchChange = false
    @State private var lastActiveRefreshAt: Date = .distantPast

    var filteredResults: [BrowserSearchResult] {
        appState.browserService.results
    }

    var displayedResults: [BrowserSearchResult] {
        if searchText.isEmpty {
            return Array(filteredResults.prefix(5))
        }
        return filteredResults
    }

    var shouldShowWindowName: Bool {
        appState.browserService.hasMultipleWindows
    }

    var shouldShowProfileName: Bool {
        var seen = Set<String>()
        for result in displayedResults {
            guard let name = result.profileName, !name.isEmpty else { continue }
            let key = result.browserName + "|" + name
            seen.insert(key)
            if seen.count > 1 { return true }
        }
        return false
    }

    var body: some View {
        ZStack {
            Color.clear
            fullScreenAmbientShadow
                .allowsHitTesting(false)

            CommandBarSurface {
                VStack(spacing: 10) {
                    if let globalShortcutRegistrationIssue = appState.globalShortcutRegistrationIssue {
                        PermissionBanner(
                            icon: "bolt.slash.fill",
                            tint: .orange,
                            message: "Shortcut \(ShortcutStore.shared.displayString) unavailable. \(globalShortcutRegistrationIssue)",
                            actionTitle: "Choose Another"
                        ) {
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if case .available(let version, _, let notes) = updateService.status {
                        PermissionBanner(
                            icon: "arrow.down.circle.fill",
                            tint: .blue,
                            message: "FastTab \(version) is available.\(notes.map { " \($0)" } ?? "")",
                            actionTitle: "Download"
                        ) {
                            updateService.openDownloadURL()
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    SearchHeader(
                        searchText: $searchText,
                        isSearchFocused: $isSearchFocused,
                        isSelected: appState.selectedIndex == -1,
                        onUpArrow: {
                            moveSelectionBackward(includeSearchField: true)
                        },
                        onDownArrow: {
                            moveSelectionForward(includeSearchField: true)
                        }
                    )

                    ScrollViewReader { proxy in
                        resultsSection(proxy: proxy)
                            .onChange(of: appState.isVisible) { _, visible in
                                if visible {
                                    searchDebounceTask?.cancel()
                                    suppressNextSearchChange = true
                                    searchText = ""
                                    appState.browserService.fetchResults(matching: searchText)
                                    appState.selectedIndex = -1
                                    hasCycled = false
                                    DispatchQueue.main.async {
                                        isSearchFocused = true
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                                            scrollResultsToTop(proxy)
                                        }
                                    }
                                }
                            }
                            .onChange(of: searchText) {
                                if suppressNextSearchChange {
                                    suppressNextSearchChange = false
                                    return
                                }

                                if searchText.isEmpty {
                                    appState.selectedIndex = -1
                                } else {
                                    appState.selectedIndex = displayedResults.isEmpty ? -1 : 0
                                }
                                isSearchFocused = true
                                if searchText.count <= 1 {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        scrollResultsToTop(proxy)
                                    }
                                } else {
                                    scrollResultsToTop(proxy)
                                }
                                scheduleSearchFetch()
                            }
                            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                                guard appState.isVisible else { return }

                                let now = Date()
                                guard now.timeIntervalSince(lastActiveRefreshAt) > 1.2 else { return }
                                lastActiveRefreshAt = now

                                appState.browserService.fetchResults(matching: searchText)
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    scrollResultsToTop(proxy)
                                }
                            }
                    }

                    FooterShortcutBar {
                        ShortcutRecorderView(store: ShortcutStore.shared)
                            .environmentObject(appState)
                    }
                }
                .padding(12)
            }
            .frame(width: CommandBarLayout.surfaceSize.width, height: CommandBarLayout.surfaceSize.height)
            .offset(y: CommandBarLayout.surfaceVerticalOffset)
        }
        .frame(width: CommandBarLayout.canvasSize.width, height: CommandBarLayout.canvasSize.height)
        .background(Color.clear)
        .onAppear {
            isSearchFocused = true
            setupLocalMonitor()
        }
        .onReceive(NotificationCenter.default.publisher(for: fastTabCycleShortcutNotification)) { _ in
            guard appState.isVisible else { return }
            cycleShortcutSelectionForward()
        }
        .onDisappear {
            searchDebounceTask?.cancel()
            faviconPrefetchDebounceTask?.cancel()
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
                localMonitor = nil
            }
        }
        .onChange(of: appState.browserService.results.map(\.id)) {
            let results = displayedResults
            if results.isEmpty {
                appState.selectedIndex = -1
                isSearchFocused = true
            } else if searchText.isEmpty {
                if appState.selectedIndex >= results.count {
                    appState.selectedIndex = max(0, results.count - 1)
                }
            } else if appState.selectedIndex < 0 || appState.selectedIndex >= results.count {
                appState.selectedIndex = 0
            }

            scheduleFaviconPrefetch(for: results)
        }
    }

    private var fullScreenAmbientShadow: some View {
        let shadowColor = commandBarFullScreenShadowColor(for: colorScheme)
        let backdropSize = CGSize(width: CommandBarLayout.canvasSize.width + 900, height: CommandBarLayout.canvasSize.height + 900)

        return RadialGradient(
            stops: [
                .init(color: shadowColor.opacity(0.54), location: 0.00),
                .init(color: shadowColor.opacity(0.46), location: 0.10),
                .init(color: shadowColor.opacity(0.30), location: 0.32),
                .init(color: shadowColor.opacity(0.15), location: 0.64),
                .init(color: shadowColor.opacity(0.04), location: 1.00)
            ],
            center: .center,
            startRadius: 60,
            endRadius: 1_250
        )
        .frame(width: backdropSize.width, height: backdropSize.height)
        .offset(y: CommandBarLayout.surfaceVerticalOffset)
    }

    @ViewBuilder
    private func resultsSection(proxy: ScrollViewProxy) -> some View {
        // Compute once here — not inside the List closure, which runs per row.
        let showWindowName = shouldShowWindowName
        let showProfileName = shouldShowProfileName
        Group {
            if appState.browserService.isLoading && displayedResults.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    ProgressView()
                        .controlSize(.regular)
                    Text(searchText.isEmpty ? "Fetching tabs…" : "Searching Chrome + Edge…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 300)
            } else if displayedResults.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "rectangle.stack.badge.magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(searchText.isEmpty ? "No tabs found" : "No matches")
                        .font(.headline)
                    Text(searchText.isEmpty ? "Open a tab in Chrome or Edge and try again." : "Try another keyword for tabs, bookmarks, or history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 300)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.thinMaterial)
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(displayedResults.enumerated()), id: \.element.id) { index, result in
                            ResultRowView(
                                result: result,
                                isSelected: appState.selectedIndex == index,
                                faviconImage: appState.browserService.faviconImage(for: result),
                                showWindowName: showWindowName,
                                showProfileName: showProfileName,
                                onCopyLink: { appState.browserService.copyLinkToClipboard(result) },
                                onRemove: {
                                    guard result.type == .tab else {
                                        appState.browserService.remove(result)
                                        return
                                    }

                                    withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                                        appState.browserService.remove(result)
                                    }
                                }
                            )
                            .contentShape(Rectangle())
                            .padding(.horizontal, 8)
                            .onTapGesture {
                                activateAndHide(result)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
                .background(Color.clear)
            }
        }
        .frame(height: 300)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.thinMaterial)
        )
    }

    private func scrollResultsToTop(_ proxy: ScrollViewProxy) {
        guard let firstResultID = displayedResults.first?.id else { return }
        proxy.scrollTo(firstResultID, anchor: .top)
    }

    private func scheduleFaviconPrefetch(for results: [BrowserSearchResult]) {
        faviconPrefetchDebounceTask?.cancel()
        let snapshot = results
        let prefetchLimit = searchText.isEmpty ? 5 : 12

        faviconPrefetchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                appState.browserService.preloadFavicons(for: snapshot, limit: prefetchLimit)
            }
        }
    }

    private func scheduleSearchFetch() {
        searchDebounceTask?.cancel()
        let query = searchText
        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                appState.browserService.fetchResults(matching: query)
            }
        }
    }

    private func activateAndHide(_ result: BrowserSearchResult) {
        appState.browserService.activate(result)
        appState.hideCommandBar()
    }

    private func moveSelectionForward(includeSearchField: Bool) {
        let results = displayedResults
        let minimumIndex = includeSearchField ? -1 : 0

        if results.isEmpty {
            appState.selectedIndex = minimumIndex
            isSearchFocused = includeSearchField
            return
        }

        let maximumIndex = results.count - 1
        if appState.selectedIndex < minimumIndex || appState.selectedIndex >= maximumIndex {
            appState.selectedIndex = minimumIndex
        } else {
            appState.selectedIndex += 1
        }

        isSearchFocused = includeSearchField && appState.selectedIndex == -1
    }

    private func moveSelectionBackward(includeSearchField: Bool) {
        let results = displayedResults
        let minimumIndex = includeSearchField ? -1 : 0

        if results.isEmpty {
            appState.selectedIndex = minimumIndex
            isSearchFocused = includeSearchField
            return
        }

        let maximumIndex = results.count - 1
        if appState.selectedIndex <= minimumIndex || appState.selectedIndex > maximumIndex {
            appState.selectedIndex = maximumIndex
        } else {
            appState.selectedIndex -= 1
        }

        isSearchFocused = includeSearchField && appState.selectedIndex == -1
    }

    private func cycleShortcutSelectionForward() {
        moveSelectionForward(includeSearchField: true)
        hasCycled = appState.selectedIndex != -1
    }

    private func handleEscapeKey() {
        if appState.selectedIndex == -1 {
            appState.hideCommandBar()
            hasCycled = false
            return
        }

        appState.selectedIndex = -1
        isSearchFocused = true
        hasCycled = false
    }

    private func setupLocalMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if appState.isRecordingShortcut { return event }

            if event.type == .keyDown {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let userModifiers = flags.intersection([.command, .option, .control, .shift])

                let noModifiers = userModifiers.isEmpty

                if event.keyCode == kEscapeKeyCode && appState.isVisible {
                    handleEscapeKey()
                    return nil
                }

                if noModifiers && event.keyCode == kUpArrowKeyCode {
                    moveSelectionBackward(includeSearchField: true)
                    return nil
                }

                if noModifiers && event.keyCode == kDownArrowKeyCode {
                    moveSelectionForward(includeSearchField: true)
                    return nil
                }

                let shiftOnly = userModifiers == .shift
                if event.keyCode == kSpaceKeyCode && (noModifiers || shiftOnly) && searchText.isEmpty {
                    if shiftOnly {
                        moveSelectionBackward(includeSearchField: true)
                    } else {
                        moveSelectionForward(includeSearchField: true)
                    }
                    return nil
                }

                if event.keyCode == kEnterKeyCode {
                    let results = displayedResults
                    if results.indices.contains(appState.selectedIndex) {
                        appState.browserService.activate(results[appState.selectedIndex])
                        appState.hideCommandBar()
                    }
                    return nil
                }
            } else if event.type == .flagsChanged && hasCycled && appState.isVisible {
                let store = ShortcutStore.shared
                let shortcutMods = store.modifiers.intersection(.deviceIndependentFlagsMask)
                let currentMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if currentMods.intersection(shortcutMods).isEmpty {
                    let results = displayedResults
                    if results.indices.contains(appState.selectedIndex) {
                        appState.browserService.activate(results[appState.selectedIndex])
                        appState.hideCommandBar()
                    }
                    hasCycled = false
                }
            }
            return event
        }
    }
}

private struct CommandBarSurface<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
    }
}

private struct PermissionBanner: View {
    @Environment(\.colorScheme) private var colorScheme
    let icon: String
    let tint: Color
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)

            Text(message)
                .font(.caption)
                .lineLimit(2)

            Spacer(minLength: 8)

            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
    }
}

private struct SearchHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var searchText: String
    @FocusState.Binding var isSearchFocused: Bool
    let isSelected: Bool
    let onUpArrow: () -> Void
    let onDownArrow: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search tabs, bookmarks, history…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .focused($isSearchFocused)
                .onKeyPress(.upArrow) {
                    onUpArrow()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    onDownArrow()
                    return .handled
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                )
        )
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isSelected)
    }
}

private struct ResultRowView: View {
    let result: BrowserSearchResult
    let isSelected: Bool
    let faviconImage: NSImage?
    let showWindowName: Bool
    let showProfileName: Bool
    let onCopyLink: () -> Void
    let onRemove: () -> Void

    private var secondaryMetadata: [String] {
        result.secondaryMetadata(showWindowName: showWindowName, showProfileName: showProfileName)
    }

    var body: some View {
        HStack(spacing: 10) {
            LeadingResultIcon(browserName: result.browserName, fallbackSymbol: result.type.symbolName, faviconImage: faviconImage)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    ForEach(secondaryMetadata, id: \.self) { metadata in
                        MetadataPill(title: metadata)
                    }

                    Text(result.secondaryBaseText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                ResultBadge(systemImage: result.type.symbolName)
                BrowserBadge(browserName: result.browserName)

                Menu {
                    Button("Copy Link", action: onCopyLink)
                    Divider()
                    if result.type == .tab {
                        Button("Close Tab", action: onRemove)
                    } else {
                        Button("Delete", role: .destructive, action: onRemove)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
            }
        }
        .opacity(result.type.dimmingOpacity)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.17) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : .clear, lineWidth: 1)
                )
        )
        .scaleEffect(isSelected ? 1.01 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isSelected)
    }
}

private struct MetadataPill: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(metadataPillTint)
                    )
            )
    }

    private var metadataPillTint: Color {
        colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.06)
    }
}

private struct ResultBadge: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
    }
}

private struct BrowserBadge: View {
    let browserName: String

    var body: some View {
        Group {
            if let appIcon = BrowserIconCache.icon(for: browserName, size: 14) {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "globe")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }
}

private struct LeadingResultIcon: View {
    let browserName: String
    let fallbackSymbol: String
    let faviconImage: NSImage?

    var body: some View {
        if let faviconImage {
            Image(nsImage: faviconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else if let appIcon = BrowserIconCache.icon(for: browserName, size: 16) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: fallbackSymbol)
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
private enum BrowserIconCache {
    private static let appPathByName: [String: String] = [
        "Google Chrome": "/Applications/Google Chrome.app",
        "Microsoft Edge": "/Applications/Microsoft Edge.app"
    ]

    private static var iconStore: [String: NSImage] = [:]

    static func icon(for browserName: String, size: CGFloat) -> NSImage? {
        if let cached = iconStore[browserName] {
            let icon = cached.copy() as? NSImage ?? cached
            icon.size = NSSize(width: size, height: size)
            return icon
        }

        guard let appPath = appPathByName[browserName],
              FileManager.default.fileExists(atPath: appPath) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: appPath)
        iconStore[browserName] = icon

        let sized = icon.copy() as? NSImage ?? icon
        sized.size = NSSize(width: size, height: size)
        return sized
    }
}

private struct FooterShortcutBar<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content

    var body: some View {
        HStack {
            Spacer()
            content
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
    }
}

private func commandBarFullScreenShadowColor(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? Color.black : Color.black.opacity(0.72)
}
