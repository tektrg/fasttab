import SwiftUI
import AppKit

private struct SearchHeaderFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private let kSpaceKeyCode: UInt16 = 49
private let kEnterKeyCode: UInt16 = 36
private let kDeleteKeyCode: UInt16 = 51
private let kEscapeKeyCode: UInt16 = 53
private let kLeftArrowKeyCode: UInt16 = 123
private let kRightArrowKeyCode: UInt16 = 124
private let kUpArrowKeyCode: UInt16 = 126
private let kDownArrowKeyCode: UInt16 = 125

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var licenseService: LicenseService
    @StateObject private var updateService = UpdateService.shared
    @ObservedObject private var shortcutStore = ShortcutStore.shared
    @State private var searchText = ""
    @State private var scopeChips: [ScopeChip] = []
    @State private var scopeSuggestionMode: ScopeSuggestionMode = .hidden
    @State private var scopeDropdownSelectedIndex: Int = 0
    /// When set, the named chip is keyboard-focused; the next backspace removes
    /// it. Cleared as soon as the user types text or moves caret back into input.
    @State private var focusedChipID: UUID? = nil
    @State private var isActivationPresented = false
    @FocusState private var isSearchFocused: Bool
    @State private var localMonitor: Any?
    /// True once the user has cycled to a tab via the shortcut; reset when the bar opens.
    @State private var hasCycled = false
    /// True while the shortcut modifier keys are still held after opening the bar.
    @State private var isShortcutModifierHeld = false
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var faviconPrefetchDebounceTask: Task<Void, Never>?
    @State private var suppressNextSearchChange = false
    @State private var lastActiveRefreshAt: Date = .distantPast
    @State private var keyboardSwipeResultID: String?
    @State private var keyboardSwipeAction: ResultSwipeAction?
    @State private var toastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var hoveredResultID: String?
    @State private var pointerSwipeResultID: String?
    @State private var pointerSwipeOffset: CGFloat = 0
    @State private var pointerSwipeAction: ResultSwipeAction?
    @State private var didConfirmPointerSwipe = false
    @State private var isPointerSwipeGestureActive = false
    @State private var suppressPointerSwipeUntilGestureEnds = false
    @State private var pointerSwipeSuppressionTask: Task<Void, Never>?
    @AppStorage("guidance.hasDiscoveredSwipe") private var hasDiscoveredSwipe: Bool = false
    @State private var lastInteractionKey: LastInteractionKey = .none
    /// Measured frame of the SearchHeader in the command-bar coordinate space.
    /// Used to position the scope dropdown directly below it as an overlay on
    /// the outer VStack, so the dropdown paints above the results section.
    @State private var searchHeaderFrame: CGRect = .zero

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

    var openTabsStatusText: String? {
        guard appState.browserService.hasFetchedOpenTabCount else { return nil }
        let count = appState.browserService.openTabCount
        return "\(count) \(count == 1 ? "tab" : "tabs") found"
    }

    var guidanceHint: GuidanceHint {
        let store = shortcutStore
        let selectedIndex = appState.selectedIndex
        let isResultFocused = selectedIndex >= 0 && !isSearchFocused
        let hasResults = !displayedResults.isEmpty
        let queryEmpty = searchText.isEmpty

        // 0: Shortcut modifier still held on fresh open — search bar focused, no cycling yet
        if isShortcutModifierHeld && !hasCycled && isSearchFocused {
            return GuidanceHint(tokens: [
                .init(glyph: store.keyDisplayName, label: "next"),
                .init(glyph: "Esc", label: "cancel")
            ])
        }

        // 1–2: Pointer swipe past confirm threshold — "release to act"
        if pointerSwipeResultID != nil, !didConfirmPointerSwipe,
           abs(pointerSwipeOffset) >= ResultSwipeMetrics.confirmDistance {
            return pointerSwipeOffset < 0
                ? GuidanceHint(tokens: [.init(glyph: "←", label: "release to delete")])
                : GuidanceHint(tokens: [.init(glyph: "→", label: "release to copy link")])
        }

        // 3–4: Pointer swipe resting at reveal distance (gesture ended, not confirmed)
        if pointerSwipeResultID != nil, pointerSwipeAction != nil,
           !isPointerSwipeGestureActive, !didConfirmPointerSwipe {
            return pointerSwipeOffset < 0
                ? GuidanceHint(tokens: [.init(glyph: "←", label: "swipe more to delete"),
                                        .init(glyph: "Esc", label: "cancel")])
                : GuidanceHint(tokens: [.init(glyph: "→", label: "swipe more to copy"),
                                        .init(glyph: "Esc", label: "cancel")])
        }

        // 5–6: Pointer swipe in progress, below confirm threshold
        if pointerSwipeResultID != nil, isPointerSwipeGestureActive,
           abs(pointerSwipeOffset) > 3 {
            return pointerSwipeOffset < 0
                ? GuidanceHint(tokens: [.init(glyph: "←", label: "keep swiping to delete")])
                : GuidanceHint(tokens: [.init(glyph: "→", label: "keep swiping to copy link")])
        }

        // 7: Modifier cycling mode — user is holding modifier and cycling with shortcut key
        if hasCycled {
            return GuidanceHint(tokens: [
                .init(glyph: store.modifierSymbols, label: "release to open"),
                .init(glyph: store.keyDisplayName, label: "next"),
                .init(glyph: "Esc", label: "cancel")
            ])
        }

        // 8: Keyboard swipe revealed, awaiting second press to confirm
        if keyboardSwipeResultID != nil {
            let arrow = keyboardSwipeAction == .delete ? "←" : "→"
            let verb = keyboardSwipeAction == .delete ? "delete" : "copy"
            return GuidanceHint(tokens: [
                .init(glyph: arrow, label: "press again to \(verb)"),
                .init(glyph: "Esc", label: "cancel")
            ])
        }

        // 9–10: Result focused via keyboard navigation (arrow keys or space)
        if isResultFocused && (lastInteractionKey == .upDown || lastInteractionKey == .space) {
            if !hasDiscoveredSwipe {
                return GuidanceHint(tokens: [
                    .init(glyph: "←→", label: "more options"),
                    .init(glyph: "↵", label: "open"),
                    .init(glyph: "Esc", label: "back to search")
                ])
            } else {
                return GuidanceHint(tokens: [
                    .init(glyph: "←", label: "delete"),
                    .init(glyph: "→", label: "copy"),
                    .init(glyph: "↵", label: "open"),
                    .init(glyph: "Esc", label: "back")
                ])
            }
        }

        // 11: Result focused via mouse click (no keyboard nav recorded)
        if isResultFocused && lastInteractionKey == .none {
            return GuidanceHint(tokens: [
                .init(glyph: "↑↓", label: "navigate"),
                .init(glyph: "←", label: "delete"),
                .init(glyph: "→", label: "copy"),
                .init(glyph: "↵", label: "open")
            ])
        }

        // 12: Mouse hover over a row, no keyboard result selected
        if hoveredResultID != nil && !isResultFocused {
            return GuidanceHint(tokens: [
                .init(glyph: "←", label: "swipe to delete"),
                .init(glyph: "→", label: "swipe to copy")
            ])
        }

        // 13: Search field focused, empty query, results present
        if !isResultFocused && queryEmpty && hasResults {
            return GuidanceHint(tokens: [
                .init(glyph: "↑↓", label: "navigate"),
                .init(glyph: "↵", label: "open"),
                .init(glyph: "@", label: "scope"),
                .init(glyph: "Esc", label: "dismiss")
            ])
        }

        // 14: Search field focused, active query, results present
        if !isResultFocused && !queryEmpty && hasResults {
            return GuidanceHint(tokens: [
                .init(glyph: "↑↓", label: "navigate"),
                .init(glyph: "↵", label: "open"),
                .init(glyph: "@", label: "scope")
            ])
        }

        // 15–16: No results — empty-state UI owns this moment
        if !hasResults { return .empty }

        // 18: Fallback
        return GuidanceHint(tokens: [
            .init(glyph: "↑↓", label: "navigate"),
            .init(glyph: "↵", label: "open"),
            .init(glyph: "Esc", label: "dismiss")
        ])
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissCommandBar()
                    }
                fullScreenAmbientShadow(canvasSize: geometry.size)
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

                        if let banner = updateBannerConfig(updateService.status) {
                            PermissionBanner(
                                icon: banner.icon,
                                tint: banner.tint,
                                message: banner.message,
                                actionTitle: banner.actionTitle,
                                dismissAction: banner.dismissable ? { updateService.dismiss() } : nil
                            ) {
                                updateService.performPrimaryAction()
                            }
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if let lastErrorMessage = licenseService.snapshot.lastErrorMessage {
                            LicenseIssueBanner(message: lastErrorMessage) {
                                licenseService.openSupport()
                            }
                        }

                        if licenseService.snapshot.allowsCommandBarUtility {
                            if let trialDaysRemaining = licenseService.snapshot.trialDaysRemaining,
                               trialDaysRemaining <= 3 {
                                TrialStatusBanner(daysRemaining: trialDaysRemaining) {
                                    licenseService.openCheckout()
                                }
                            }

                            SearchHeader(
                                searchText: $searchText,
                                isSearchFocused: $isSearchFocused,
                                isSelected: appState.selectedIndex == -1,
                                scopeChips: scopeChips,
                                focusedChipID: focusedChipID,
                                onRemoveChip: { chip in
                                    removeChip(id: chip.id)
                                },
                                onFocusChip: { chip in
                                    focusedChipID = chip.id
                                },
                                onBackspaceAtEmpty: {
                                    handleBackspaceAtEmptyInput()
                                },
                                onLeftArrowAtEmpty: {
                                    handleLeftArrowAtEmptyInput()
                                },
                                onUpArrow: {
                                    if isScopeDropdownVisible {
                                        moveScopeSuggestionSelection(by: -1)
                                        return
                                    }
                                    moveSelectionBackward(includeSearchField: true)
                                    lastInteractionKey = .upDown
                                },
                                onDownArrow: {
                                    if isScopeDropdownVisible {
                                        moveScopeSuggestionSelection(by: 1)
                                        return
                                    }
                                    moveSelectionForward(includeSearchField: true)
                                    lastInteractionKey = .upDown
                                }
                            )
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: SearchHeaderFrameKey.self,
                                        value: geo.frame(in: .named("commandBar"))
                                    )
                                }
                            )
                            .zIndex(50)

                            // Zero-height layer that hosts the floating scope
                            // dropdown. `frame(height: 0)` keeps it out of the
                            // VStack's layout (no shift), and `zIndex(100)` makes
                            // its overlay paint above later VStack siblings.
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: 0)
                                .overlay(alignment: .topLeading) {
                                    if isScopeDropdownVisible {
                                        let suggestions = currentScopeSuggestions()
                                        ScopeSuggestionDropdown(
                                            suggestions: suggestions,
                                            selectedIndex: scopeDropdownSelectedIndex,
                                            emptyStateText: scopeDropdownEmptyStateText,
                                            onHover: { idx in scopeDropdownSelectedIndex = idx },
                                            onPick: { commitScopeSuggestion($0) }
                                        )
                                        .frame(width: 420, alignment: .topLeading)
                                        .padding(.top, 8)
                                        .transition(.opacity)
                                    }
                                }
                                .zIndex(100)
                                .allowsHitTesting(isScopeDropdownVisible)

                            ScrollViewReader { proxy in
                                resultsSection(proxy: proxy)
                                    .onChange(of: appState.isVisible) { _, visible in
                                        if visible {
                                            resetForCommandBarOpen()
                                            triggerFetch()
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
                                        recomputeScopeSuggestionMode()
                                        // Typing into the field returns control
                                        // to the input — drop any chip focus.
                                        if !searchText.isEmpty {
                                            focusedChipID = nil
                                        }
                                        lastInteractionKey = .none
                                        clearKeyboardSwipe()
                                        resetPointerSwipe(animated: false)
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

                                        triggerFetch()
                                        withAnimation(.easeInOut(duration: 0.18)) {
                                            scrollResultsToTop(proxy)
                                        }
                                    }
                                    .onChange(of: appState.selectedIndex) { _, _ in
                                        guard !isSearchFocused else { return }
                                        withAnimation(.easeInOut(duration: 0.14)) {
                                            scrollSelectedResultIntoView(proxy)
                                        }
                                    }
                            }

                            FooterShortcutBar {
                                HStack(spacing: 0) {
                                    GuidanceBarView(
                                        hint: guidanceHint,
                                        statusText: openTabsStatusText
                                    )
                                    Spacer(minLength: 12)
                                    ShortcutRecorderView(store: ShortcutStore.shared)
                                        .environmentObject(appState)
                                }
                            }
                        } else {
                            PaywallView(
                                snapshot: licenseService.snapshot,
                                onBuy: { licenseService.openCheckout() },
                                onActivate: { isActivationPresented = true },
                                onSupport: { licenseService.openSupport() }
                            )
                        }
                    }
                    .padding(12)
                    .coordinateSpace(name: "commandBar")
                    .onPreferenceChange(SearchHeaderFrameKey.self) { newValue in
                        searchHeaderFrame = newValue
                    }
                    // Floating scope-suggestion dropdown — overlaid on the entire
                    // command-bar surface so it paints above the results section.
                }
                .frame(width: CommandBarLayout.surfaceSize.width, height: CommandBarLayout.surfaceSize.height)
                .offset(y: CommandBarLayout.surfaceVerticalOffset)

                if let toastMessage {
                    CommandBarToast(message: toastMessage)
                        .offset(
                            y: CommandBarLayout.surfaceVerticalOffset
                                + (CommandBarLayout.surfaceSize.height / 2)
                                + 24
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color.clear)
        .onAppear {
            isSearchFocused = true
            setupLocalMonitor()
            licenseService.validateCachedLicenseIfNeeded()
        }
        .sheet(isPresented: $isActivationPresented) {
            LicenseActivationSheet()
                .environmentObject(licenseService)
        }
        .onReceive(NotificationCenter.default.publisher(for: fastTabCycleShortcutNotification)) { _ in
            guard appState.isVisible else { return }
            cycleShortcutSelectionForward()
        }
        .onDisappear {
            searchDebounceTask?.cancel()
            faviconPrefetchDebounceTask?.cancel()
            toastDismissTask?.cancel()
            clearPointerSwipeSuppression()
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
                clearKeyboardSwipe()
                resetPointerSwipe(animated: false)
            } else if searchText.isEmpty {
                if appState.selectedIndex >= results.count {
                    appState.selectedIndex = max(0, results.count - 1)
                    clearKeyboardSwipe()
                    resetPointerSwipe(animated: false)
                }
            } else if appState.selectedIndex < 0 || appState.selectedIndex >= results.count {
                appState.selectedIndex = 0
                clearKeyboardSwipe()
                resetPointerSwipe(animated: false)
            }

            scheduleFaviconPrefetch(for: results)
        }
    }

    private func fullScreenAmbientShadow(canvasSize: CGSize) -> some View {
        let shadowColor = commandBarFullScreenShadowColor(for: colorScheme)
        let backdropSize = CommandBarLayout.shadowBackdropSize(for: canvasSize)

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
                            SwipeableResultRow(
                                result: result,
                                isSelected: appState.selectedIndex == index,
                                faviconImage: appState.browserService.faviconImage(for: result),
                                showWindowName: showWindowName,
                                showProfileName: showProfileName,
                                pointerAction: pointerSwipeResultID == result.id ? pointerSwipeAction : nil,
                                pointerOffset: pointerSwipeResultID == result.id ? pointerSwipeOffset : 0,
                                keyboardAction: keyboardSwipeResultID == result.id ? keyboardSwipeAction : nil,
                                onCopyLink: { performCopyLink(result) },
                                onRemove: { performRemove(result) },
                                onHoverChange: { isHovering in
                                    if isHovering {
                                        hoveredResultID = result.id
                                    } else if hoveredResultID == result.id {
                                        hoveredResultID = nil
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

    private func scrollSelectedResultIntoView(_ proxy: ScrollViewProxy) {
        let results = displayedResults
        guard results.indices.contains(appState.selectedIndex) else { return }
        proxy.scrollTo(results[appState.selectedIndex].id, anchor: .center)
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
        let query = effectiveQueryString()
        let filter = ScopeFilter.from(chips: scopeChips)
        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                appState.browserService.fetchResults(matching: query, filter: filter)
            }
        }
    }

    /// Immediate (un-debounced) fetch using the current chip + query state.
    private func triggerFetch() {
        searchDebounceTask?.cancel()
        let query = effectiveQueryString()
        let filter = ScopeFilter.from(chips: scopeChips)
        appState.browserService.fetchResults(matching: query, filter: filter)
    }

    /// The free-text query portion (excludes any in-progress `in:` token, which
    /// hasn't been committed to a chip yet and shouldn't be sent to the backend).
    private func effectiveQueryString() -> String {
        switch scopeSuggestionMode {
        case .hidden: return searchText
        case .root(_, let range), .bookmarks(_, let range), .history(_, let range):
            var copy = searchText
            copy.removeSubrange(range)
            return copy.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var isScopeDropdownVisible: Bool {
        switch scopeSuggestionMode {
        case .hidden: return false
        case .root: return !currentScopeSuggestions().isEmpty
        // Drill-down modes always show the dropdown so an empty-folders state
        // is visible instead of silently disappearing.
        case .bookmarks, .history: return true
        }
    }

    private var scopeDropdownEmptyStateText: String? {
        switch scopeSuggestionMode {
        case .bookmarks:
            return appState.browserService.cachedBookmarks.isEmpty
                ? "Loading bookmarks…"
                : "No matching folders"
        case .history:
            return "No matching time range"
        default:
            return nil
        }
    }

    private func currentScopeSuggestions() -> [ScopeSuggestion] {
        switch scopeSuggestionMode {
        case .hidden:
            return []
        case .root(let prefix, _):
            let trimmed = prefix.lowercased()
            var items: [ScopeSuggestion] = [
                .root(.duplicate),
                .root(.bookmarks),
                .root(.history)
            ]
            for window in appState.browserService.availableWindows {
                items.append(.root(.window(window)))
            }
            if trimmed.isEmpty { return items }
            return items.filter { $0.label.lowercased().contains(trimmed) }
        case .bookmarks(let prefix, _):
            let trimmed = prefix.lowercased()
            let folders = appState.browserService.availableBookmarkFolders.map(ScopeSuggestion.bookmarkFolder)
            if trimmed.isEmpty { return folders }
            return folders.filter {
                $0.label.lowercased().contains(trimmed)
                    || ($0.detail ?? "").lowercased().contains(trimmed)
            }
        case .history(let prefix, _):
            let trimmed = prefix.lowercased()
            let times = HistoryTimeScope.allCases.map(ScopeSuggestion.historyTime)
            if trimmed.isEmpty { return times }
            return times.filter { $0.label.lowercased().contains(trimmed) }
        }
    }

    private func recomputeScopeSuggestionMode() {
        let newMode = ScopeSuggestionParser.mode(for: searchText)

        // Auto-commit drill-down parent when the user's typed prefix matches no
        // child suggestion. Picking `@Bookmarks:foo` commits `[Bookmarks]` and
        // leaves `foo` as free text. Only fires while drilling (root mode keeps
        // its empty state).
        if autoCommitDrillDownParentIfNeeded(for: newMode) {
            return
        }

        if newMode != scopeSuggestionMode {
            scopeSuggestionMode = newMode
            scopeDropdownSelectedIndex = 0
        } else {
            let count = currentScopeSuggestions().count
            if count == 0 {
                scopeDropdownSelectedIndex = 0
            } else if scopeDropdownSelectedIndex >= count {
                scopeDropdownSelectedIndex = count - 1
            }
        }
    }

    /// If the user is drilling into `@Bookmarks:` or `@History:` and has typed
    /// a non-empty prefix that matches no child option, commit the plain parent
    /// chip and let the prefix continue as free-text search. Returns true when
    /// it fired (caller should bail out of further mode handling).
    private func autoCommitDrillDownParentIfNeeded(for mode: ScopeSuggestionMode) -> Bool {
        switch mode {
        case .bookmarks(let prefix, let range):
            let trimmed = prefix.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            let lower = trimmed.lowercased()
            let folders = appState.browserService.availableBookmarkFolders
            let anyMatch = folders.contains {
                $0.displayName.lowercased().contains(lower)
                    || $0.folderPath.lowercased().contains(lower)
            }
            guard !anyMatch else { return false }
            commitDrillDownParent(parent: .bookmarks, keepingFreeText: prefix, tokenRange: range)
            return true
        case .history(let prefix, let range):
            let trimmed = prefix.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return false }
            let lower = trimmed.lowercased()
            let anyMatch = HistoryTimeScope.allCases.contains { $0.label.lowercased().contains(lower) }
            guard !anyMatch else { return false }
            commitDrillDownParent(parent: .historyAll, keepingFreeText: prefix, tokenRange: range)
            return true
        default:
            return false
        }
    }

    private enum DrillDownParent { case bookmarks, historyAll }

    private func commitDrillDownParent(
        parent: DrillDownParent,
        keepingFreeText prefix: String,
        tokenRange: Range<String.Index>
    ) {
        // Suppress the searchText onChange that our own replaceToken triggers —
        // we've already moved to a chip-committed state; the recomputeScope...
        // call below re-syncs without recursing.
        suppressNextSearchChange = true
        replaceToken(at: tokenRange, with: prefix)
        switch parent {
        case .bookmarks:
            appendChip(.init(kind: .bookmarks))
        case .historyAll:
            appendChip(.init(kind: .history(nil)))
        }
        scopeSuggestionMode = .hidden
        scopeDropdownSelectedIndex = 0
        triggerFetch()
        isSearchFocused = true
    }

    private func moveScopeSuggestionSelection(by delta: Int) {
        let count = currentScopeSuggestions().count
        guard count > 0 else { return }
        scopeDropdownSelectedIndex = (scopeDropdownSelectedIndex + delta + count) % count
    }

    private func commitScopeSuggestion(_ suggestion: ScopeSuggestion) {
        let tokenRange: Range<String.Index>?
        switch scopeSuggestionMode {
        case .hidden: tokenRange = nil
        case .root(_, let range), .bookmarks(_, let range), .history(_, let range):
            tokenRange = range
        }

        // Handle drill-down: picking `Bookmarks` or `History` from root replaces
        // the token with `@Bookmarks:` / `@History:` so the dropdown stays open.
        if case .root(let rootSugg) = suggestion {
            switch rootSugg {
            case .bookmarks:
                // Always drill into folder picker; the dropdown handles the
                // empty-folders state. Cold caches will populate via the
                // ambient refresh triggered by the scoped fetch.
                replaceToken(at: tokenRange, with: "@Bookmarks:")
                recomputeScopeSuggestionMode()
                return
            case .history:
                replaceToken(at: tokenRange, with: "@History:")
                recomputeScopeSuggestionMode()
                return
            case .duplicate:
                replaceToken(at: tokenRange, with: "")
                appendChip(.init(kind: .duplicate))
            case .window(let ref):
                replaceToken(at: tokenRange, with: "")
                appendChip(.init(kind: .window(ref)))
            }
        } else if case .bookmarkFolder(let ref) = suggestion {
            replaceToken(at: tokenRange, with: "")
            appendChip(.init(kind: .bookmarksFolder(ref)))
        } else if case .historyTime(let time) = suggestion {
            replaceToken(at: tokenRange, with: "")
            appendChip(.init(kind: .history(time)))
        }

        recomputeScopeSuggestionMode()
        triggerFetch()
        isSearchFocused = true
    }

    private func replaceToken(at range: Range<String.Index>?, with replacement: String) {
        guard let range else {
            searchText = replacement
            return
        }
        var text = searchText
        text.replaceSubrange(range, with: replacement)
        // Trim trailing whitespace if the chip eats the whole token, leaving "react in:foo" → "react ".
        if replacement.isEmpty {
            while text.hasSuffix(" ") { text.removeLast() }
        }
        searchText = text
    }

    private func appendChip(_ chip: ScopeChip) {
        // Stackable per design — duplicate chips in the same bucket are allowed
        // (redundant AND). User removes via backspace if unwanted.
        scopeChips.append(chip)
    }

    /// Removes the named chip and shifts keyboard focus sensibly: prefer the
    /// chip just to the left of the removed one, falling back to clearing focus
    /// (which returns the caret to the input field).
    private func removeChip(id: UUID) {
        guard let idx = scopeChips.firstIndex(where: { $0.id == id }) else { return }
        scopeChips.remove(at: idx)
        if scopeChips.isEmpty {
            focusedChipID = nil
        } else if idx > 0 {
            focusedChipID = scopeChips[idx - 1].id
        } else {
            focusedChipID = nil
        }
        isSearchFocused = focusedChipID == nil
        triggerFetch()
    }

    /// Gmail-style two-step delete: first backspace at empty input focuses the
    /// last chip; the next backspace (while a chip is focused) removes it.
    private func handleBackspaceAtEmptyInput() {
        guard !scopeChips.isEmpty else { return }
        if let focusedChipID {
            removeChip(id: focusedChipID)
        } else {
            focusedChipID = scopeChips.last?.id
        }
    }

    /// Left-arrow at empty input enters the chip strip from the right and walks
    /// further leftward through chips on each subsequent press.
    private func handleLeftArrowAtEmptyInput() {
        guard !scopeChips.isEmpty else { return }
        if let current = focusedChipID,
           let idx = scopeChips.firstIndex(where: { $0.id == current }),
           idx > 0 {
            focusedChipID = scopeChips[idx - 1].id
        } else if focusedChipID == nil {
            focusedChipID = scopeChips.last?.id
        }
    }

    private func handleScopeDropdownEnter() -> Bool {
        let suggestions = currentScopeSuggestions()
        guard !suggestions.isEmpty,
              suggestions.indices.contains(scopeDropdownSelectedIndex) else { return false }
        commitScopeSuggestion(suggestions[scopeDropdownSelectedIndex])
        return true
    }

    private func dismissScopeDropdown() {
        // Drop the in-progress `in:...` token entirely.
        if case .root(_, let range) = scopeSuggestionMode {
            replaceToken(at: range, with: "")
        } else if case .bookmarks(_, let range) = scopeSuggestionMode {
            replaceToken(at: range, with: "")
        } else if case .history(_, let range) = scopeSuggestionMode {
            replaceToken(at: range, with: "")
        }
        scopeSuggestionMode = .hidden
        scopeDropdownSelectedIndex = 0
    }

    private func resetForCommandBarOpen() {
        searchDebounceTask?.cancel()
        suppressNextSearchChange = true
        searchText = ""
        scopeChips = []
        scopeSuggestionMode = .hidden
        scopeDropdownSelectedIndex = 0
        focusedChipID = nil
        appState.selectedIndex = -1
        hasCycled = false
        lastInteractionKey = .none
        let store = ShortcutStore.shared
        let shortcutMods = store.modifiers.intersection(.deviceIndependentFlagsMask)
        let currentMods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        isShortcutModifierHeld = !currentMods.intersection(shortcutMods).isEmpty
        clearKeyboardSwipe()
        clearPointerSwipeSuppression()
        resetPointerSwipe(animated: false)
        toastDismissTask?.cancel()
        toastMessage = nil
    }

    private func activateAndHide(_ result: BrowserSearchResult) {
        clearKeyboardSwipe()
        clearPointerSwipeSuppression()
        resetPointerSwipe(animated: false)
        appState.browserService.activate(result)
        appState.hideCommandBar()
    }

    private func dismissCommandBar() {
        toastDismissTask?.cancel()
        toastMessage = nil
        clearKeyboardSwipe()
        clearPointerSwipeSuppression()
        resetPointerSwipe(animated: false)
        appState.hideCommandBar()
        hasCycled = false
    }

    private func performCopyLink(_ result: BrowserSearchResult) {
        appState.browserService.copyLinkToClipboard(result)
        showToastAndDismiss("Link copied")
    }

    private func performRemove(_ result: BrowserSearchResult) {
        clearKeyboardSwipe()
        resetPointerSwipe(animated: false)
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            appState.browserService.remove(result)
        }
    }

    private func showToastAndDismiss(_ message: String) {
        toastDismissTask?.cancel()
        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
            toastMessage = message
        }

        toastDismissTask = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                appState.hideCommandBar()
                clearKeyboardSwipe()
                clearPointerSwipeSuppression()
                resetPointerSwipe(animated: false)
                withAnimation(.easeOut(duration: 0.16)) {
                    toastMessage = nil
                }
            }
        }
    }

    private func clearKeyboardSwipe() {
        keyboardSwipeResultID = nil
        keyboardSwipeAction = nil
    }

    private func resetPointerSwipe(animated: Bool) {
        let update = {
            pointerSwipeResultID = nil
            pointerSwipeOffset = 0
            pointerSwipeAction = nil
            didConfirmPointerSwipe = false
            isPointerSwipeGestureActive = false
        }

        if animated {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.88), update)
        } else {
            update()
        }
    }

    private func clearPointerSwipeSuppression() {
        pointerSwipeSuppressionTask?.cancel()
        pointerSwipeSuppressionTask = nil
        suppressPointerSwipeUntilGestureEnds = false
    }

    private func suppressPointerSwipeUntilCurrentGestureEnds() {
        suppressPointerSwipeUntilGestureEnds = true
        pointerSwipeSuppressionTask?.cancel()
        pointerSwipeSuppressionTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                suppressPointerSwipeUntilGestureEnds = false
                pointerSwipeSuppressionTask = nil
            }
        }
    }

    private func handlePointerScrollSwipe(_ event: NSEvent) -> Bool {
        guard appState.isVisible else { return false }

        let ended = event.phase.contains(.ended) || event.momentumPhase.contains(.ended)
        let cancelled = event.phase.contains(.cancelled) || event.momentumPhase.contains(.cancelled)
        if suppressPointerSwipeUntilGestureEnds {
            if ended || cancelled {
                clearPointerSwipeSuppression()
            }
            return true
        }

        if ended || cancelled {
            return finishPointerScrollSwipe(cancelled: cancelled)
        }

        let deltaX = normalizedHorizontalScrollDelta(from: event)
        let deltaY = CGFloat(event.scrollingDeltaY)
        let absX = abs(deltaX)
        let absY = abs(deltaY)

        if pointerSwipeResultID != nil, absX < 3, absY > 3 {
            resetPointerSwipe(animated: true)
            return false
        }

        if pointerSwipeResultID == nil {
            guard absX > 3, absX > absY * 1.35, let hoveredResultID else { return false }
            pointerSwipeResultID = hoveredResultID
            didConfirmPointerSwipe = false
            isPointerSwipeGestureActive = true
        }

        guard !didConfirmPointerSwipe else { return true }

        let nextOffset = max(
            -ResultSwipeMetrics.maximumOffset,
             min(ResultSwipeMetrics.maximumOffset, pointerSwipeOffset + deltaX)
        )
        pointerSwipeOffset = nextOffset

        guard let nextAction = swipeAction(for: nextOffset) else {
            pointerSwipeAction = nil
            return true
        }

        if abs(nextOffset) >= ResultSwipeMetrics.confirmDistance {
            didConfirmPointerSwipe = true
            confirmPointerSwipe(nextAction)
        } else if abs(nextOffset) >= ResultSwipeMetrics.revealDistance {
            pointerSwipeAction = nextAction
            if !hasDiscoveredSwipe { hasDiscoveredSwipe = true }
        }

        return true
    }

    private func finishPointerScrollSwipe(cancelled: Bool) -> Bool {
        guard pointerSwipeResultID != nil else { return false }
        isPointerSwipeGestureActive = false
        guard !didConfirmPointerSwipe else {
            resetPointerSwipe(animated: false)
            return true
        }

        if cancelled || abs(pointerSwipeOffset) < ResultSwipeMetrics.revealDistance {
            resetPointerSwipe(animated: true)
            return true
        }

        let restingAction = swipeAction(for: pointerSwipeOffset)
        pointerSwipeAction = restingAction
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            pointerSwipeOffset = (restingAction?.sign ?? 0) * ResultSwipeMetrics.revealDistance
        }
        return true
    }

    private func confirmPointerSwipe(_ action: ResultSwipeAction) {
        let results = displayedResults
        guard let pointerSwipeResultID,
              let result = results.first(where: { $0.id == pointerSwipeResultID }) else {
            resetPointerSwipe(animated: true)
            return
        }

        switch action {
        case .delete:
            suppressPointerSwipeUntilCurrentGestureEnds()
            performRemove(result)
        case .copy:
            suppressPointerSwipeUntilCurrentGestureEnds()
            performCopyLink(result)
        }
    }

    private func swipeAction(for offset: CGFloat) -> ResultSwipeAction? {
        if offset <= -1 { return .delete }
        if offset >= 1 { return .copy }
        return nil
    }

    private func normalizedHorizontalScrollDelta(from event: NSEvent) -> CGFloat {
        let directionMultiplier: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        return -CGFloat(event.scrollingDeltaX) * directionMultiplier
    }

    private func handleKeyboardSwipe(_ action: ResultSwipeAction) {
        let results = displayedResults
        guard results.indices.contains(appState.selectedIndex) else { return }

        let result = results[appState.selectedIndex]
        if keyboardSwipeResultID == result.id, keyboardSwipeAction == action {
            switch action {
            case .delete:
                performRemove(result)
            case .copy:
                performCopyLink(result)
            }
            return
        }

        if !hasDiscoveredSwipe { hasDiscoveredSwipe = true }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            keyboardSwipeResultID = result.id
            keyboardSwipeAction = action
        }
        isSearchFocused = false
    }

    private func moveSelectionForward(includeSearchField: Bool) {
        clearKeyboardSwipe()
        resetPointerSwipe(animated: true)
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
        clearKeyboardSwipe()
        resetPointerSwipe(animated: true)
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
            clearKeyboardSwipe()
            resetPointerSwipe(animated: false)
            return
        }

        appState.selectedIndex = -1
        isSearchFocused = true
        hasCycled = false
        clearKeyboardSwipe()
        resetPointerSwipe(animated: true)
    }

    private func setupLocalMonitor() {
        guard localMonitor == nil else { return }
        let monitoredEvents: NSEvent.EventTypeMask = [
            .keyDown,
            .flagsChanged,
            .scrollWheel
        ]

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: monitoredEvents) { event in
            if appState.isRecordingShortcut { return event }

            if event.type == .scrollWheel {
                return handlePointerScrollSwipe(event) ? nil : event
            } else if event.type == .keyDown {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let userModifiers = flags.intersection([.command, .option, .control, .shift])

                let noModifiers = userModifiers.isEmpty

                // Backspace at empty input: step-back into the chip strip,
                // then delete on the next press. Routed here (not via SwiftUI
                // `.onKeyPress(.delete)`) because that hook is unreliable when
                // the TextField is empty.
                if noModifiers,
                   event.keyCode == kDeleteKeyCode,
                   appState.isVisible,
                   searchText.isEmpty,
                   !scopeChips.isEmpty {
                    handleBackspaceAtEmptyInput()
                    return nil
                }

                if event.keyCode == kEscapeKeyCode && appState.isVisible {
                    if isScopeDropdownVisible {
                        dismissScopeDropdown()
                        return nil
                    }
                    if focusedChipID != nil {
                        focusedChipID = nil
                        isSearchFocused = true
                        return nil
                    }
                    handleEscapeKey()
                    return nil
                }

                if noModifiers && event.keyCode == kUpArrowKeyCode {
                    if isScopeDropdownVisible {
                        moveScopeSuggestionSelection(by: -1)
                        return nil
                    }
                    moveSelectionBackward(includeSearchField: true)
                    lastInteractionKey = .upDown
                    return nil
                }

                if noModifiers && event.keyCode == kDownArrowKeyCode {
                    if isScopeDropdownVisible {
                        moveScopeSuggestionSelection(by: 1)
                        return nil
                    }
                    moveSelectionForward(includeSearchField: true)
                    lastInteractionKey = .upDown
                    return nil
                }

                if noModifiers && event.keyCode == kLeftArrowKeyCode && appState.selectedIndex >= 0 {
                    handleKeyboardSwipe(.delete)
                    lastInteractionKey = .leftRight
                    return nil
                }

                if noModifiers && event.keyCode == kRightArrowKeyCode && appState.selectedIndex >= 0 {
                    handleKeyboardSwipe(.copy)
                    lastInteractionKey = .leftRight
                    return nil
                }

                let shiftOnly = userModifiers == .shift
                if event.keyCode == kSpaceKeyCode && (noModifiers || shiftOnly) && searchText.isEmpty {
                    if shiftOnly {
                        moveSelectionBackward(includeSearchField: true)
                    } else {
                        moveSelectionForward(includeSearchField: true)
                    }
                    lastInteractionKey = .space
                    return nil
                }

                if event.keyCode == kEnterKeyCode {
                    if isScopeDropdownVisible, handleScopeDropdownEnter() {
                        return nil
                    }
                    let results = displayedResults
                    if results.indices.contains(appState.selectedIndex) {
                        appState.browserService.activate(results[appState.selectedIndex])
                        appState.hideCommandBar()
                        clearKeyboardSwipe()
                    }
                    return nil
                }
            } else if event.type == .flagsChanged && appState.isVisible {
                let store = ShortcutStore.shared
                let shortcutMods = store.modifiers.intersection(.deviceIndependentFlagsMask)
                let currentMods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let modifierReleased = currentMods.intersection(shortcutMods).isEmpty
                if modifierReleased {
                    isShortcutModifierHeld = false
                    if hasCycled {
                        let results = displayedResults
                        if results.indices.contains(appState.selectedIndex) {
                            appState.browserService.activate(results[appState.selectedIndex])
                            appState.hideCommandBar()
                            clearKeyboardSwipe()
                        }
                        hasCycled = false
                    }
                }
            }
            return event
        }
    }
}
