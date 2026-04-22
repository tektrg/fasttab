import SwiftUI
import AppKit

private let kSpaceKeyCode: UInt16 = 49
private let kEnterKeyCode: UInt16 = 36
private let kUpArrowKeyCode: UInt16 = 126
private let kDownArrowKeyCode: UInt16 = 125

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var localMonitor: Any?
    /// True once the user has cycled to a tab via the shortcut; reset when the bar opens.
    @State private var hasCycled = false
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var suppressNextSearchChange = false

    var filteredResults: [BrowserSearchResult] {
        appState.browserService.results
    }

    var displayedResults: [BrowserSearchResult] {
        if searchText.isEmpty {
            return Array(filteredResults.prefix(5))
        }
        return filteredResults
    }

    private let cardSize = CGSize(width: 640, height: 460)
    private let canvasSize = CGSize(width: 760, height: 580)

    var body: some View {
        ZStack {
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
                                            proxy.scrollTo(0, anchor: .top)
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
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    proxy.scrollTo(0, anchor: .top)
                                }
                                scheduleSearchFetch()
                            }
                            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                                guard appState.isVisible else { return }
                                appState.browserService.fetchResults(matching: searchText)
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    proxy.scrollTo(0, anchor: .top)
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
            .frame(width: cardSize.width, height: cardSize.height)
            .padding(40)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
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
        }
    }

    @ViewBuilder
    private func resultsSection(proxy: ScrollViewProxy) -> some View {
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
                        .fill(.ultraThinMaterial)
                )
            } else {
                List(Array(displayedResults.enumerated()), id: \.element.id) { index, result in
                    ResultRowView(
                        result: result,
                        isSelected: appState.selectedIndex == index,
                        faviconURL: faviconURL(for: result.url),
                        onCopyLink: { appState.browserService.copyLinkToClipboard(result) },
                        onRemove: { appState.browserService.remove(result) }
                    )
                    .contentShape(Rectangle())
                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .onTapGesture {
                        activateAndHide(result)
                    }
                    .id(index)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .animation(.easeInOut(duration: 0.2), value: displayedResults.map(\.id))
            }
        }
        .frame(height: 300)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.09), lineWidth: 1)
                )
        )
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

    private func faviconURL(for urlString: String) -> URL? {
        guard let host = URL(string: urlString)?.host else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=32")
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

    private func setupLocalMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if appState.isRecordingShortcut { return event }

            if event.type == .keyDown {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let userModifiers = flags.intersection([.command, .option, .control, .shift])

                let noModifiers = userModifiers.isEmpty

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
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.28), .white.opacity(0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
            )
            .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
    }
}

private struct PermissionBanner: View {
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
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(tint.opacity(0.22), lineWidth: 1)
                )
        )
    }
}

private struct SearchHeader: View {
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
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.28) : .white.opacity(0.09), lineWidth: 1)
                )
        )
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isSelected)
    }
}

private struct ResultRowView: View {
    let result: BrowserSearchResult
    let isSelected: Bool
    let faviconURL: URL?
    let onCopyLink: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: faviconURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: result.type.symbolName)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(result.title)
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .lineLimit(1)

                Text(result.secondaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                        .background(
                            Capsule(style: .continuous)
                                .fill(.thinMaterial)
                        )
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

private struct ResultBadge: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(.thinMaterial)
            )
    }
}

private struct BrowserBadge: View {
    let browserName: String

    var body: some View {
        Group {
            if let appIcon = browserAppIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(4)
            } else {
                Image(systemName: "globe")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
        .frame(width: 22, height: 22)
        .background(
            Capsule(style: .continuous)
                .fill(.thinMaterial)
        )
    }

    private var browserAppIcon: NSImage? {
        let appPath: String? = switch browserName {
        case "Google Chrome": "/Applications/Google Chrome.app"
        case "Microsoft Edge": "/Applications/Microsoft Edge.app"
        default: nil
        }

        guard let appPath, FileManager.default.fileExists(atPath: appPath) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: appPath)
        icon.size = NSSize(width: 14, height: 14)
        return icon
    }
}

private struct FooterShortcutBar<Content: View>: View {
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
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        )
    }
}
