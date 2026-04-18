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
    @State private var accessibilityTimer: Timer?
    @State private var localMonitor: Any?
    @State private var needsRestartAfterGrant = false
    /// True once the user has cycled to a tab via the shortcut; reset when the bar opens.
    @State private var hasCycled = false

    var filteredTabs: [BrowserTab] {
        if searchText.isEmpty {
            return appState.browserService.tabs
        }
        return appState.browserService.tabs.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.url.localizedCaseInsensitiveContains(searchText)
        }
    }

    var displayedTabs: [BrowserTab] {
        if searchText.isEmpty {
            return Array(filteredTabs.prefix(5))
        }
        return filteredTabs
    }

    private let cardSize = CGSize(width: 640, height: 460)
    private let canvasSize = CGSize(width: 760, height: 580)

    var body: some View {
        ZStack {
            CommandBarSurface {
                VStack(spacing: 10) {
                    if !appState.hasAccessibilityAccess {
                        PermissionBanner(
                            icon: "exclamationmark.triangle.fill",
                            tint: .orange,
                            message: "Accessibility access required for global shortcut (Cmd+Shift+Space).",
                            actionTitle: "Grant Access"
                        ) {
                            AccessibilityService.requestPermissions()
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                                Task { @MainActor in
                                    let hadAccess = appState.hasAccessibilityAccess
                                    appState.refreshPermissions()
                                    if !hadAccess && appState.hasAccessibilityAccess {
                                        needsRestartAfterGrant = true
                                    }
                                }
                            }
                        }
                        .onDisappear {
                            accessibilityTimer?.invalidate()
                            accessibilityTimer = nil
                        }
                    }

                    if needsRestartAfterGrant {
                        PermissionBanner(
                            icon: "checkmark.circle.fill",
                            tint: .green,
                            message: "Access granted. Restart the app to activate the global shortcut.",
                            actionTitle: "Restart"
                        ) {
                            restartApplication()
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
                                    appState.browserService.fetchTabs()
                                    searchText = ""
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
                                appState.selectedIndex = -1
                                isSearchFocused = true
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    proxy.scrollTo(0, anchor: .top)
                                }
                            }
                            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                                appState.browserService.fetchTabs()
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
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: needsRestartAfterGrant)
        .onAppear {
            appState.browserService.fetchTabs()
            isSearchFocused = true
            setupLocalMonitor()
        }
        .onDisappear {
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
                localMonitor = nil
            }
        }
        .onChange(of: appState.browserService.tabs.map(\.id)) {
            let tabs = displayedTabs
            if tabs.isEmpty {
                appState.selectedIndex = -1
                isSearchFocused = true
            } else if appState.selectedIndex >= tabs.count {
                appState.selectedIndex = max(0, tabs.count - 1)
            }
        }
    }

    @ViewBuilder
    private func resultsSection(proxy: ScrollViewProxy) -> some View {
        Group {
            if appState.browserService.isLoading && displayedTabs.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    ProgressView()
                        .controlSize(.regular)
                    Text("Fetching tabs…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(height: 300)
            } else if displayedTabs.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "rectangle.stack.badge.magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(searchText.isEmpty ? "No tabs found" : "No matches")
                        .font(.headline)
                    Text(searchText.isEmpty ? "Open a tab in Chrome or Edge and try again." : "Try another keyword")
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
                List(Array(displayedTabs.enumerated()), id: \.element.id) { index, tab in
                    TabRowView(
                        tab: tab,
                        isSelected: appState.selectedIndex == index,
                        faviconURL: faviconURL(for: tab.url)
                    )
                    .contentShape(Rectangle())
                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .onTapGesture {
                        activateAndHide(tab)
                    }
                    .id(index)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .animation(.easeInOut(duration: 0.2), value: displayedTabs.map(\.id))
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

    private func restartApplication() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [url.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func activateAndHide(_ tab: BrowserTab) {
        appState.browserService.activateTab(tab)
        appState.isVisible = false
        NSApp.hide(nil)
    }

    private func faviconURL(for urlString: String) -> URL? {
        guard let host = URL(string: urlString)?.host else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=32")
    }

    private func moveSelectionForward(includeSearchField: Bool) {
        let tabs = displayedTabs
        let minimumIndex = includeSearchField ? -1 : 0

        if tabs.isEmpty {
            appState.selectedIndex = minimumIndex
            isSearchFocused = includeSearchField
            return
        }

        let maximumIndex = tabs.count - 1
        if appState.selectedIndex < minimumIndex || appState.selectedIndex >= maximumIndex {
            appState.selectedIndex = minimumIndex
        } else {
            appState.selectedIndex += 1
        }

        isSearchFocused = includeSearchField && appState.selectedIndex == -1
    }

    private func moveSelectionBackward(includeSearchField: Bool) {
        let tabs = displayedTabs
        let minimumIndex = includeSearchField ? -1 : 0

        if tabs.isEmpty {
            appState.selectedIndex = minimumIndex
            isSearchFocused = includeSearchField
            return
        }

        let maximumIndex = tabs.count - 1
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
            // Pass everything through while the shortcut recorder is capturing a new key.
            if appState.isRecordingShortcut { return event }

            if event.type == .keyDown {
                let store = ShortcutStore.shared
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

                // Configured shortcut pressed while the bar is open → cycle through the current travel loop,
                // including the search field and the default 5 visible items.
                if event.keyCode == store.keyCode && flags == store.modifiers.intersection(.deviceIndependentFlagsMask) {
                    cycleShortcutSelectionForward()
                    return nil   // swallow — never reaches the text field
                }

                let noModifiers = flags.isEmpty

                // Up/down arrows: loop through the search field and visible results without moving the caret.
                if noModifiers && event.keyCode == kUpArrowKeyCode {
                    moveSelectionBackward(includeSearchField: true)
                    return nil
                }

                if noModifiers && event.keyCode == kDownArrowKeyCode {
                    moveSelectionForward(includeSearchField: true)
                    return nil
                }

                // Plain Space (±Shift) with empty search: same loop as the shortcut travel.
                let shiftOnly = flags == .shift
                if event.keyCode == kSpaceKeyCode && (noModifiers || shiftOnly) && searchText.isEmpty {
                    if shiftOnly {
                        moveSelectionBackward(includeSearchField: true)
                    } else {
                        moveSelectionForward(includeSearchField: true)
                    }
                    return nil
                }

                if event.keyCode == kEnterKeyCode {
                    let tabs = displayedTabs
                    if tabs.indices.contains(appState.selectedIndex) {
                        appState.browserService.activateTab(tabs[appState.selectedIndex])
                        appState.isVisible = false
                        NSApp.hide(nil)
                    }
                    return nil
                }
            } else if event.type == .flagsChanged && hasCycled && appState.isVisible {
                // When the shortcut's modifier keys are released after cycling, activate the selected tab.
                let store = ShortcutStore.shared
                let shortcutMods = store.modifiers.intersection(.deviceIndependentFlagsMask)
                let currentMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                // Fire as soon as none of the shortcut's modifiers are still held
                if !currentMods.contains(shortcutMods) {
                    let tabs = displayedTabs
                    if tabs.indices.contains(appState.selectedIndex) {
                        appState.browserService.activateTab(tabs[appState.selectedIndex])
                        appState.isVisible = false
                        NSApp.hide(nil)
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

            TextField("Search tabs…", text: $searchText)
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

private struct TabRowView: View {
    let tab: BrowserTab
    let isSelected: Bool
    let faviconURL: URL?

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: faviconURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "globe")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(tab.title)
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .lineLimit(1)

                Text(tab.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(tab.appName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(.thinMaterial)
                )
        }
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
