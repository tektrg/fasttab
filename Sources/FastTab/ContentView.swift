import SwiftUI
import AppKit

private let kSpaceKeyCode: UInt16 = 49
private let kEnterKeyCode: UInt16 = 36
private let kEscapeKeyCode: UInt16 = 53
private let kLeftArrowKeyCode: UInt16 = 123
private let kRightArrowKeyCode: UInt16 = 124
private let kUpArrowKeyCode: UInt16 = 126
private let kDownArrowKeyCode: UInt16 = 125

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var appState: AppState
    @StateObject private var updateService = UpdateService.shared
    @ObservedObject private var shortcutStore = ShortcutStore.shared
    @State private var searchText = ""
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
                .init(glyph: "Esc", label: "dismiss")
            ])
        }

        // 14: Search field focused, active query, results present
        if !isResultFocused && !queryEmpty && hasResults {
            return GuidanceHint(tokens: [
                .init(glyph: "↑↓", label: "navigate"),
                .init(glyph: "↵", label: "open")
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

                        SearchHeader(
                            searchText: $searchText,
                            isSearchFocused: $isSearchFocused,
                            isSelected: appState.selectedIndex == -1,
                            onUpArrow: {
                                moveSelectionBackward(includeSearchField: true)
                                lastInteractionKey = .upDown
                            },
                            onDownArrow: {
                                moveSelectionForward(includeSearchField: true)
                                lastInteractionKey = .upDown
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

                                    appState.browserService.fetchResults(matching: searchText)
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
                                GuidanceBarView(hint: guidanceHint)
                                Spacer(minLength: 12)
                                ShortcutRecorderView(store: ShortcutStore.shared)
                                    .environmentObject(appState)
                            }
                        }
                    }
                    .padding(12)
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

                if event.keyCode == kEscapeKeyCode && appState.isVisible {
                    handleEscapeKey()
                    return nil
                }

                if noModifiers && event.keyCode == kUpArrowKeyCode {
                    moveSelectionBackward(includeSearchField: true)
                    lastInteractionKey = .upDown
                    return nil
                }

                if noModifiers && event.keyCode == kDownArrowKeyCode {
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

private struct UpdateBannerConfig {
    let icon: String
    let tint: Color
    let message: String
    let actionTitle: String
    let dismissable: Bool
}

private func updateBannerConfig(_ status: UpdateService.UpdateStatus) -> UpdateBannerConfig? {
    switch status {
    case .idle, .checking:
        return nil
    case .available(let version, let notes):
        let trail = notes.map { " \($0)" } ?? ""
        return UpdateBannerConfig(
            icon: "arrow.down.circle.fill",
            tint: .blue,
            message: "FastTab \(version) is available.\(trail)",
            actionTitle: "Update",
            dismissable: true
        )
    case .downloading(let progress):
        let pct = Int((progress * 100).rounded())
        return UpdateBannerConfig(
            icon: "arrow.down.circle",
            tint: .blue,
            message: "Downloading update… \(pct)%",
            actionTitle: "Cancel",
            dismissable: false
        )
    case .extracting:
        return UpdateBannerConfig(
            icon: "arrow.down.circle",
            tint: .blue,
            message: "Preparing update…",
            actionTitle: "Cancel",
            dismissable: false
        )
    case .readyToRestart(let version):
        return UpdateBannerConfig(
            icon: "arrow.triangle.2.circlepath.circle.fill",
            tint: .green,
            message: "FastTab \(version) is ready.",
            actionTitle: "Restart to Update",
            dismissable: true
        )
    case .installing:
        return UpdateBannerConfig(
            icon: "arrow.triangle.2.circlepath.circle",
            tint: .green,
            message: "Installing update…",
            actionTitle: "Installing",
            dismissable: false
        )
    case .upToDate:
        return nil
    case .error(let message):
        return UpdateBannerConfig(
            icon: "exclamationmark.triangle.fill",
            tint: .orange,
            message: "Update failed: \(message)",
            actionTitle: "Retry",
            dismissable: true
        )
    }
}
