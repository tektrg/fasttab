import SwiftUI

private let kSpaceKeyCode: UInt16 = 49
private let kEnterKeyCode: UInt16 = 36

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

    var body: some View {
        VStack(spacing: 0) {
            if !appState.hasAccessibilityAccess {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Accessibility access required for global shortcut (Cmd+Shift+Space).")
                        .font(.caption)
                    Spacer()
                    Button("Grant Access") {
                        AccessibilityService.requestPermissions()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
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
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Access granted. Restart the app to activate the global shortcut.")
                        .font(.caption)
                    Spacer()
                    Button("Restart") {
                        let url = Bundle.main.bundleURL
                        let task = Process()
                        task.launchPath = "/usr/bin/open"
                        task.arguments = [url.path]
                        try? task.run()
                        NSApp.terminate(nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(8)
                .background(Color.green.opacity(0.1))
            }

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search tabs...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            List(filteredTabs.indices, id: \.self) { index in
                let tab = filteredTabs[index]
                HStack {
                    AsyncImage(url: faviconURL(for: tab.url)) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else {
                            Image(systemName: "globe")
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(width: 16, height: 16)

                    VStack(alignment: .leading) {
                        Text(tab.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(tab.url)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(tab.appName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(4)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(appState.selectedIndex == index ? Color.accentColor.opacity(0.2) : Color.clear)
                .cornerRadius(6)
                .contentShape(Rectangle())
                .onTapGesture {
                    appState.browserService.activateTab(tab)
                    appState.isVisible = false
                    NSApp.hide(nil)
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Spacer()
                ShortcutRecorderView(store: ShortcutStore.shared)
                    .environmentObject(appState)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 600, height: 430)
        .onAppear {
            appState.browserService.fetchTabs()
            isSearchFocused = true
            setupLocalMonitor()
        }
        .onChange(of: appState.isVisible) { _, visible in
            if visible {
                appState.browserService.fetchTabs()
                searchText = ""
                appState.selectedIndex = 0
                hasCycled = false
                // Defer focus so the window is fully key before we request it
                DispatchQueue.main.async {
                    isSearchFocused = true
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.browserService.fetchTabs()
        }
        .onDisappear {
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
                localMonitor = nil
            }
        }
        .onChange(of: searchText) {
            appState.selectedIndex = 0
        }
    }

    private func faviconURL(for urlString: String) -> URL? {
        guard let host = URL(string: urlString)?.host else { return nil }
        return URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=32")
    }

    private func setupLocalMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Pass everything through while the shortcut recorder is capturing a new key.
            if appState.isRecordingShortcut { return event }

            if event.type == .keyDown {
                let store = ShortcutStore.shared
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

                // Configured shortcut pressed while the bar is open → cycle forward through first 5 items.
                // This mirrors what the global monitor does, but locally so it works even with focus.
                if event.keyCode == store.keyCode && flags == store.modifiers.intersection(.deviceIndependentFlagsMask) {
                    let tabs = filteredTabs
                    let cycleCount = min(5, tabs.count)
                    if cycleCount > 0 {
                        appState.selectedIndex = (appState.selectedIndex + 1) % cycleCount
                        hasCycled = true
                    }
                    return nil   // swallow — never reaches the text field
                }

                // Plain Space (±Shift) with empty search: also cycle
                let noModifiers = flags.isEmpty
                let shiftOnly = flags == .shift
                if event.keyCode == kSpaceKeyCode && (noModifiers || shiftOnly) && searchText.isEmpty {
                    let tabs = filteredTabs
                    let cycleCount = min(5, tabs.count)
                    if cycleCount > 0 {
                        if shiftOnly {
                            appState.selectedIndex = (appState.selectedIndex - 1 + cycleCount) % cycleCount
                        } else {
                            appState.selectedIndex = (appState.selectedIndex + 1) % cycleCount
                        }
                    }
                    return nil
                }

                if event.keyCode == kEnterKeyCode {
                    let tabs = filteredTabs
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
                    let tabs = filteredTabs
                    if tabs.indices.contains(appState.selectedIndex) {
                        appState.browserService.activateTab(tabs[appState.selectedIndex])
                    }
                    appState.isVisible = false
                    hasCycled = false
                    NSApp.hide(nil)
                }
            }
            return event
        }
    }
}
