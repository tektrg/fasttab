import SwiftUI
import AppKit
import CommandBarKit

private struct SearchHeaderFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}
struct ContentView: View {
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var licenseService: LicenseService
    @StateObject var updateService = UpdateService.shared
    @ObservedObject var shortcutStore = ShortcutStore.shared
    @ObservedObject var edgeRevealStore = EdgeRevealStore.shared
    @ObservedObject var viewStore = CommandBarViewStore.shared
    @ObservedObject var myOrderStore = MyOrderStore.shared
    @ObservedObject var sentLinkInbox = SentLinkInbox.shared
    @ObservedObject var revealTrigger = CommandBarRevealTrigger.shared
    @ObservedObject var dismissTrigger = CommandBarDismissTrigger.shared
    /// Reveal progress on the axis growing out of the anchored edge, and on the
    /// axis spreading along it. 0 is the pre-reveal sliver, 1 is fully open;
    /// each is driven by its own spring (see `playRevealAnimation`).
    @State var revealDepthProgress: Double = 1
    @State var revealSpreadProgress: Double = 1
    @State var searchText = ""
    @State var scopeChips: [ScopeChip] = []
    /// Non-nil while the command bar is in alias mode: the keyword has been
    /// consumed, `searchText` now holds the query destined for that alias.
    @State var activeSearchAlias: SearchAlias? = nil
    /// The text consumed when entering alias mode, restored if the user backs
    /// out. Without this, a mistaken Space costs them the whole keyword.
    @State var consumedAliasKeyword: String = ""
    /// A keyword the user just backed out of. Suppresses re-committing the same
    /// one so backing out and continuing to type can't loop.
    @State var rejectedAliasKeyword: String? = nil
    @ObservedObject var searchAliasStore = SearchAliasStore.shared
    @State var scopeSuggestionMode: ScopeSuggestionMode = .hidden
    @State var scopeDropdownSelectedIndex: Int = 0
    /// When set, the named chip is keyboard-focused; the next backspace removes
    /// it. Cleared as soon as the user types text or moves caret back into input.
    @State var focusedChipID: UUID? = nil
    @State private var isActivationPresented = false
    @FocusState var isSearchFocused: Bool
    @State var localMonitor: Any?
    /// Hold-modifier cycling state (`hasCycled`, `isModifierHeld`); reset when the bar opens.
    @ObservedObject var cycleSession = AppState.shared.cycleSession
    @State var searchDebounceTask: Task<Void, Never>?
    @State var faviconPrefetchDebounceTask: Task<Void, Never>?
    @State var suppressNextSearchChange = false
    @State private var lastActiveRefreshAt: Date = .distantPast
    @State var keyboardSwipeResultID: String?
    @State var keyboardSwipeAction: ResultSwipeAction?
    @State var closingResultID: String?
    @State var closingResultTask: Task<Void, Never>?
    @State var toastMessage: String?
    @State var toastDismissTask: Task<Void, Never>?
    @State var hoveredResultID: String?
    @State var pointerSwipeResultID: String?
    @State var pointerSwipeOffset: CGFloat = 0
    @State var pointerSwipeAction: ResultSwipeAction?
    @State var didConfirmPointerSwipe = false
    @State var isPointerSwipeGestureActive = false
    @State var suppressPointerSwipeUntilGestureEnds = false
    @State var pointerSwipeSuppressionTask: Task<Void, Never>?
    @State var flickDetector = ViewSwitchFlickDetector()
    @State var isShowingAllOpenTabs = false
    /// True for the lifetime of one open when the bar was revealed by hovering
    /// the notch/edge (not the keyboard shortcut or menu bar icon).
    @State var wasOpenedByHover = false
    /// True for the lifetime of one open when opened via mouse (notch/edge hover,
    /// menu bar icon, or dock icon). Mouse opens show all open tabs immediately in the switcher
    /// view; the 5-tab limit and "Show all tabs..." affordance only apply to shortcut opens.
    @State var wasOpenedByMouse = false
    @AppStorage("guidance.hasDiscoveredSwipe") var hasDiscoveredSwipe: Bool = false
    @State var lastInteractionKey: LastInteractionKey = .none
    /// Measured frame of the SearchHeader in the command-bar coordinate space.
    /// Used to position the scope dropdown directly below it as an overlay on
    /// the outer VStack, so the dropdown paints above the results section.
    @State private var searchHeaderFrame: CGRect = .zero

    @AppStorage(CommandBarAppearance.resultRowStyleKey) var rowStyle: ResultRowStyle = .minimal
    @AppStorage(CommandBarAppearance.helperPanelVisibleKey) var showHelperPanel: Bool = true
    /// The "Background" appearance setting — handed to `CommandBarSurface`,
    /// which passes it down to every section background inside it.
    @AppStorage(CommandBarAppearance.outerPanelKey) var outerPanelEnabled: Bool = true
    /// User's preferred quick-open ("recent tabs") item count. Read through
    /// `effectiveQuickOpenLimit`, never used directly — it may exceed what the
    /// current screen can actually fit.
    @AppStorage(CommandBarAppearance.quickOpenItemLimitKey) var quickOpenItemLimitSetting: Int = 5

    var filteredResults: [BrowserSearchResult] {
        appState.browserService.results
    }

    var displayedResults: [BrowserSearchResult] {
        if isSearchActive {
            return filteredResults
        }
        return quickOpenState.results
    }

    /// The quick-open item count actually used: the user's setting, clamped to
    /// the Stepper's bounds and to however many rows the current screen can
    /// show without the panel growing past its edge (see
    /// `CommandBarLayout.maxQuickOpenRowsFittingScreen`).
    var effectiveQuickOpenLimit: Int {
        let bounded = min(max(quickOpenItemLimitSetting, CommandBarLayout.minQuickOpenItemLimit), CommandBarLayout.maxQuickOpenItemLimit)
        return min(bounded, CommandBarLayout.maxQuickOpenRowsFittingScreen(rowStyle: rowStyle))
    }

    var quickOpenState: QuickOpenDisplayState {
        quickOpenDisplayState(
            from: filteredResults,
            limit: effectiveQuickOpenLimit,
            isShowingAllOpenTabs: isShowingAllOpenTabs
        )
    }

    /// Pinned slots in stored order — the Stack view's top section. Pinned
    /// slots always occupy the prefix of `myOrderStore.slots` (see
    /// `partitionSlots`), so a row's position in this array is also its
    /// index in the store — reorder targets need no translation.
    var stackPinnedSlots: [OrderedTabSlot] {
        myOrderStore.slots.filter(\.isPinned)
    }

    /// Unopened iPhone-sent links ("Send to Mac"), newest first. The Stack
    /// view's bottom section; they stay out of Recents.
    var stackSentLinks: [BrowserSearchResult] {
        sentLinkInbox.asSearchResults().sorted { $0.timestamp > $1.timestamp }
    }

    /// Rows ahead of the sent-links section in the Stack list. 0 outside the
    /// Stack view, and 0 while any search — text, chips like `@Duplicate`,
    /// or alias — is active, since the list then shows filtered results
    /// instead of sections.
    var stackSentLinksOffset: Int {
        guard viewStore.activeView == .stack, !isSearchActive else { return 0 }
        return stackPinnedSlots.count
    }

    func displayItems(for view: CommandBarView) -> [CommandBarDisplayItem] {
        if !isSearchActive {
            switch view {
            case .stack:
                return stackPinnedSlots.map(CommandBarDisplayItem.orderedEntry)
                    + stackSentLinks.map(CommandBarDisplayItem.result)
            case .recents:
                break
            }
        }
        var items = displayedResults.map(CommandBarDisplayItem.result)
        if !isSearchActive, quickOpenState.includesShowAllTabsItem {
            items.append(.showAllTabs(count: filteredResults.count))
        }
        if !searchText.isEmpty, filteredResults.isEmpty, activeSearchAlias == nil {
            items.append(.searchTheWeb(query: searchText))
        }
        if let activeSearchAlias {
            // Top of the list, so it is the default Enter target: the user
            // explicitly committed to this alias, and anything typed since is
            // meant for it rather than for the local index.
            items.insert(.searchAliasQuery(alias: activeSearchAlias, query: searchText), at: 0)
        } else if let hintedAlias = searchAliasHint {
            // Bottom, and never auto-selected — a plain search for a word that
            // happens to be a keyword must not be hijacked.
            items.append(.searchAliasHint(hintedAlias))
        }
        return items
    }

    var displayedItems: [CommandBarDisplayItem] {
        displayItems(for: viewStore.activeView)
    }

    /// The alias the current text would commit to on Tab/Space, when alias mode
    /// is not already active.
    var searchAliasHint: SearchAlias? {
        guard activeSearchAlias == nil, !searchText.isEmpty else { return nil }
        guard !searchAliasStore.triggerKeys.isEmpty else { return nil }
        guard searchText.lowercased() != rejectedAliasKeyword else { return nil }
        return searchAliasStore.alias(committedBy: searchText)
    }

    var indexedDisplayItems: [(offset: Int, element: CommandBarDisplayItem)] {
        Array(displayedItems.enumerated())
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

    /// Row count the panel sizes itself around: always the full row budget
    /// (`resultsMaxRows`), so the panel holds a constant height — matching its
    /// default, 5-item size — as the result count changes while typing. A
    /// shorter result list leaves dead space below it rather than resizing
    /// (and repositioning) the window on every keystroke.
    var resultsSizingRowCount: Int {
        Int.max
    }

    var isSearchActive: Bool {
        CommandBarLayout.isSearchActive(
            searchText: searchText,
            hasScopeChips: !scopeChips.isEmpty,
            hasActiveAlias: activeSearchAlias != nil
        )
    }

    var isSearchEmpty: Bool {
        !isSearchActive
    }

    /// Ceiling `resultsSizingRowCount` clamps against: once "Show all tabs" is
    /// expanded, a fixed height ceiling (independent of screen size) so the
    /// panel doesn't grow to fill most of a tall display — see
    /// `CommandBarLayout.expandedAllTabsMaxHeight`. Otherwise the user's
    /// configurable, screen-safe quick-open limit while the search field is
    /// empty, or the fixed live-search row cap.
    var resultsMaxRows: Int {
        CommandBarLayout.surfaceMaxRows(
            view: viewStore.activeView,
            isShowingAllOpenTabs: isShowingAllOpenTabs,
            isSearching: isSearchActive,
            anchor: commandBarAnchor,
            rowStyle: rowStyle,
            showFooter: showHelperPanel,
            quickOpenLimit: effectiveQuickOpenLimit
        )
    }

    var openTabsStatusText: String? {
        guard appState.browserService.hasFetchedOpenTabCount else { return nil }
        let count = appState.browserService.openTabCount
        return "\(count) \(count == 1 ? "tab" : "tabs") found"
    }

    /// Minimal rows hide type/recency/window/URL to stay one line, so the
    /// footer surfaces that same metadata (in place of the tab-count text)
    /// while the user hovers a row, or — absent a hover — for whichever row
    /// is keyboard-selected. Full rows already show it inline, so this only
    /// applies in Minimal.
    var hoveredResultFooterMetadata: BrowserSearchResult? {
        guard rowStyle == .minimal else { return nil }
        if let hoveredResultID, let hovered = displayedResults.first(where: { $0.id == hoveredResultID }) {
            return hovered
        }
        guard displayedItems.indices.contains(appState.selectedIndex) else { return nil }
        return displayedItems[appState.selectedIndex].result
    }

    /// Hidden once `@duplicate` is already the active filter — tapping the
    /// tag again would be a no-op.
    var duplicateTabTagCount: Int {
        guard !scopeChips.contains(where: { $0.kind == .duplicate }) else { return 0 }
        return appState.browserService.duplicateTabCount
    }

    var commandBarAnchor: EdgeRevealStyle {
        edgeRevealStore.style == .off ? .notch : edgeRevealStore.style
    }

    /// Narrow (half-width) edge-anchored surface — content wraps instead of
    /// truncating. See `EnvironmentValues.isCompactCommandBar`.
    private func isCompact(_ anchor: EdgeRevealStyle) -> Bool {
        CommandBarLayout.isCompact(anchor)
    }

    /// Extracted out of the `.onChange(of: appState.selectedIndex)` modifier
    /// chain — inlining this closure there overwhelmed the type-checker
    /// ("unable to type-check this expression in reasonable time"), and the
    /// same applies to `handleSearchTextChange`/`handleAppDidBecomeActive`
    /// below: the combined chain of adjacent modifier closures was too much
    /// for the checker even after any single one shrank.
    private func handleActiveViewChange(proxy: ScrollViewProxy) {
        isShowingAllOpenTabs = wasOpenedByMouse
        clearKeyboardSwipe()
        resetPointerSwipe(animated: false)
        activeSearchAlias = nil
        consumedAliasKeyword = ""
        rejectedAliasKeyword = nil
        scopeChips = []
        focusedChipID = nil
        scopeSuggestionMode = .hidden
        if !searchText.isEmpty {
            suppressNextSearchChange = true
            searchText = ""
        }
        appState.selectedIndex = 0
        scrollResultsToTop(proxy)
    }

    private func handleSelectedIndexChange(proxy: ScrollViewProxy) {
        guard !isSearchFocused else { return }
        withAnimation(.easeInOut(duration: 0.14)) {
            scrollSelectedResultIntoView(proxy)
        }
    }

    private func handleSearchTextChange(proxy: ScrollViewProxy) {
        if suppressNextSearchChange {
            suppressNextSearchChange = false
            return
        }

        if !searchText.isEmpty {
            isShowingAllOpenTabs = false
        }
        if searchText.isEmpty {
            // Clearing the field is a fresh start — the earlier rejection of a
            // keyword no longer applies.
            rejectedAliasKeyword = nil
            appState.selectedIndex = -1
            // Stay in search mode while chips/alias remain — only restore the
            // mouse-open "show all" list when the bar is truly empty.
            if wasOpenedByMouse, scopeChips.isEmpty, activeSearchAlias == nil {
                isShowingAllOpenTabs = true
            }
        } else {
            appState.selectedIndex = displayedResults.isEmpty ? -1 : 0
        }
        recomputeScopeSuggestionMode()
        // Typing into the field returns control to the input — drop any chip focus.
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

    private func handleCommandBarVisibilityChange(_ visible: Bool, proxy: ScrollViewProxy) {
        if visible {
            wasOpenedByHover = appState.wasOpenedByHover
            wasOpenedByMouse = appState.wasOpenedByMouse
            resetForCommandBarOpen()
            if wasOpenedByHover {
                viewStore.resetForHoverOpen()
            }
            isShowingAllOpenTabs = wasOpenedByMouse
            triggerFetch()
            DispatchQueue.main.async {
                isSearchFocused = true
                withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                    scrollResultsToTop(proxy)
                }
            }
        } else {
            wasOpenedByHover = false
            wasOpenedByMouse = false
            isShowingAllOpenTabs = false
        }
    }

    private func handleAppDidBecomeActive(proxy: ScrollViewProxy) {
        guard appState.isVisible else { return }

        let now = Date()
        guard now.timeIntervalSince(lastActiveRefreshAt) > 1.2 else { return }
        lastActiveRefreshAt = now

        triggerFetch()
        withAnimation(.easeInOut(duration: 0.18)) {
            scrollResultsToTop(proxy)
        }
    }

    var body: some View {
        let anchor = commandBarAnchor

        let rowCount = resultsSizingRowCount
        let maxRows = resultsMaxRows
        let surfaceSize = CommandBarLayout.surfaceSize(for: anchor, rowStyle: rowStyle, rowCount: rowCount, maxRows: maxRows, showFooter: showHelperPanel)
        let alignment = CommandBarLayout.surfaceAlignment(for: anchor)

        // Everything is positioned by aligning it against the canvas edge the
        // anchor hugs — never by measuring the canvas. See
        // `CommandBarLayout.surfaceAlignment` for why measuring cannot be flush
        // on the first rendered frame.
        //
        // Bound to `beforeActivationSheet` (rather than an immediate `return`)
        // and picked back up below, right before `.sheet(...)` — stacking the
        // whole tail (sheet/onReceive/onDisappear/onChange) onto one giant
        // expression overwhelmed the type-checker ("unable to type-check this
        // expression in reasonable time").
        let sizedSurface = Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                dismissCommandBar()
            }
            .overlay(alignment: alignment) {
                ambientShadow(anchor: anchor, surfaceSize: surfaceSize)
                    .allowsHitTesting(false)
                    // Same tail fade as the surface below — a shadow lingering
                    // at full strength under a dissolving panel would be the
                    // last thing left on screen.
                    .opacity(revealSurfaceOpacity)
            }
            .overlay(alignment: alignment) {
                CommandBarSurface(anchor: anchor, outerPanelEnabled: outerPanelEnabled) {
                    // The VStack's content is split from its long modifier
                    // tail below (padding/frame/opacity/background/etc.) —
                    // stacked directly on one expression, this whole surface
                    // overwhelmed the type-checker ("unable to type-check
                    // this expression in reasonable time"); AnyView gives
                    // each segment a hard type boundary.
                    let mainContent = VStack(spacing: 10) {
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
                                TrialStatusBanner(
                                    daysRemaining: trialDaysRemaining,
                                    onBuy: {
                                        licenseService.openCheckout(source: .trialBanner)
                                    },
                                    onActivate: {
                                        isActivationPresented = true
                                    }
                                )
                            }

                            // Split from its modifiers below — the combined
                            // expression (call + trailing closures + background
                            // GeometryReader) overwhelmed the type-checker.
                            let searchHeader = SearchHeader(
                                searchText: $searchText,
                                isSearchFocused: $isSearchFocused,
                                scopeChips: scopeChips,
                                activeAlias: activeSearchAlias,
                                onRemoveAlias: {
                                    exitSearchAliasMode()
                                },
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
                                },
                                isStackActive: viewStore.activeView == .stack,
                                onSelectView: { viewStore.selectView($0) }
                            )
                            searchHeader
                                .background(
                                    GeometryReader { geo in
                                        Color.clear.preference(
                                            key: SearchHeaderFrameKey.self,
                                            value: geo.frame(in: .named("commandBar"))
                                        )
                                    }
                                )
                                .zIndex(50)
                                // The search field only exists in Recents mode:
                                // focus it on entering search, release on
                                // entering Stack. Centralized here so every
                                // entry point (tabs, swipe, ⌘1/⌘2, hotkeys)
                                // gets the same focus behavior.
                                .onChange(of: viewStore.activeView) { _, newView in
                                    isSearchFocused = (newView == .recents)
                                }

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
                                        // Clamped to the surface: 420pt overflows
                                        // the half-width edge-anchored size.
                                        .frame(width: min(420, surfaceSize.width - 24), alignment: .topLeading)
                                        .padding(.top, 8)
                                        .transition(.opacity)
                                    }
                                }
                                .zIndex(100)
                                .allowsHitTesting(isScopeDropdownVisible)

                            ScrollViewReader { proxy in
                                // Each modifier is erased to AnyView and split
                                // into its own statement — stacking all four on
                                // one expression (even a plain, unannotated
                                // `let`) overwhelmed the type-checker ("unable
                                // to type-check this expression in reasonable
                                // time"); AnyView gives each statement a hard
                                // type boundary so inference doesn't have to
                                // carry the whole opaque chain forward.
                                let withVisibilityChange: AnyView = AnyView(
                                    resultsSection(proxy: proxy)
                                        .onChange(of: appState.isVisible) { _, visible in
                                            handleCommandBarVisibilityChange(visible, proxy: proxy)
                                        }
                                )
                                let withSearchTextChange: AnyView = AnyView(
                                    withVisibilityChange
                                        .onChange(of: searchText) {
                                            handleSearchTextChange(proxy: proxy)
                                        }
                                )
                                let withAppActiveReceive: AnyView = AnyView(
                                    withSearchTextChange
                                        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                                            handleAppDidBecomeActive(proxy: proxy)
                                        }
                                )
                                let withActiveViewChange: AnyView = AnyView(
                                    withAppActiveReceive
                                        .onChange(of: viewStore.activeView) { _, _ in
                                            handleActiveViewChange(proxy: proxy)
                                        }
                                )
                                withActiveViewChange
                                    .onChange(of: appState.selectedIndex) { _, _ in
                                        handleSelectedIndexChange(proxy: proxy)
                                    }
                            }

                            if showHelperPanel {
                                FooterShortcutBar {
                                    // Stacks at the narrow edge-anchored width,
                                    // where the hints and the shortcut recorder
                                    // can't sit side by side without clipping.
                                    if isCompact(anchor) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            GuidanceBarView(
                                                hint: guidanceHint,
                                                statusText: openTabsStatusText,
                                                duplicateTabCount: duplicateTabTagCount,
                                                onTapDuplicateTag: activateDuplicateFilterFromTag,
                                                hoveredResult: hoveredResultFooterMetadata,
                                                showWindowName: shouldShowWindowName,
                                                showProfileName: shouldShowProfileName
                                            )
                                            ShortcutRecorderView(store: ShortcutStore.shared, showsSettingsButton: true)
                                                .environmentObject(appState)
                                        }
                                    } else {
                                        HStack(spacing: 0) {
                                            GuidanceBarView(
                                                hint: guidanceHint,
                                                statusText: openTabsStatusText,
                                                duplicateTabCount: duplicateTabTagCount,
                                                onTapDuplicateTag: activateDuplicateFilterFromTag,
                                                hoveredResult: hoveredResultFooterMetadata,
                                                showWindowName: shouldShowWindowName,
                                                showProfileName: shouldShowProfileName
                                            )
                                            Spacer(minLength: 12)
                                            ShortcutRecorderView(store: ShortcutStore.shared, showsSettingsButton: true)
                                                .environmentObject(appState)
                                        }
                                    }
                                }
                            }
                        } else {
                            PaywallView(
                                snapshot: licenseService.snapshot,
                                onBuy: { licenseService.openCheckout(source: .expiredPaywall) },
                                onActivate: { isActivationPresented = true },
                                onSupport: { licenseService.openSupport() }
                            )
                        }
                    }
                    let sizedContent: AnyView = AnyView(
                        mainContent
                            .padding(12)
                            // Clears the physical notch / menu bar, which the surface
                            // now reaches under so it can sit flush against the very
                            // top of the display.
                            .padding(.top, CommandBarLayout.surfaceTopInset(for: anchor))
                            // Sized *inside* the surface, not outside it: the panel's
                            // background wraps whatever it is handed, so framing it from
                            // the outside made the background hug the (shorter) content
                            // and centered it, leaving an empty band above and below.
                            .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .top)
                            .animation(.easeOut(duration: 0.12), value: surfaceSize)
                    )
                    // Deliberately *inside* the notch connector background added
                    // below, so the connector stays opaque while the content
                    // fades — it stands in for the notch itself and has to keep
                    // reading as solid screen bezel throughout.
                    //
                    // Derived from the reveal springs rather than driven by its
                    // own animation: it then can't drift out of step with the
                    // growth, and the dismiss animation gets the matching
                    // fade-out for free.
                    let fadedContent: AnyView = AnyView(
                        sizedContent
                            .opacity(CommandBarLayout.revealContentOpacity(
                                depthProgress: revealDepthProgress,
                                spreadProgress: revealSpreadProgress
                            ))
                    )
                    // Fills the notch-clearance inset above with a small
                    // notch-width (not panel-width) black connector instead of
                    // leaving it transparent: without this, the reveal
                    // animation shrinks that dead space right along with
                    // everything else, so instead of growing flush out of the
                    // notch it left a visible gap between the true top edge
                    // and the first opaque pixel. Kept exactly notch-width so
                    // it reads as the notch extending down a little, not a
                    // bar spanning the whole panel.
                    fadedContent
                        .background(alignment: .top) {
                            UnevenRoundedRectangle(
                                topLeadingRadius: 0,
                                bottomLeadingRadius: 10,
                                bottomTrailingRadius: 10,
                                topTrailingRadius: 0,
                                style: .continuous
                            )
                            .fill(Color.black)
                            .frame(
                                width: CommandBarLayout.notchConnectorWidth(for: anchor),
                                height: CommandBarLayout.surfaceTopInset(for: anchor)
                            )
                        }
                        .coordinateSpace(name: "commandBar")
                        .onPreferenceChange(SearchHeaderFrameKey.self) { newValue in
                            searchHeaderFrame = newValue
                        }
                }
                .environment(\.isCompactCommandBar, isCompact(anchor))
                .scaleEffect(
                    x: revealScale(for: anchor, surfaceSize: surfaceSize).width,
                    y: revealScale(for: anchor, surfaceSize: surfaceSize).height,
                    anchor: CommandBarLayout.revealAnchorUnitPoint(for: anchor)
                )
                .opacity(revealSurfaceOpacity)
            }
            // Centred on the surface, then pushed 24pt past its bottom edge —
            // `fixedSize` so the surface-sized positioning box can't squeeze the
            // message onto a second line at the narrow edge-anchored width.
            .overlay(alignment: alignment) {
                if let toastMessage {
                    CommandBarToast(message: toastMessage)
                        .fixedSize()
                        .offset(y: (surfaceSize.height / 2) + 24)
                        .frame(width: surfaceSize.width, height: surfaceSize.height)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        let afterAppear: AnyView = AnyView(
            sizedSurface
                .onAppear {
                    isSearchFocused = true
                    setupLocalMonitor()
                    licenseService.validateCachedLicenseIfNeeded()
                    appState.isSearchTextEmpty = isSearchEmpty
                }
        )

        // Separate from the other `searchText` observer above: that one is
        // gated by `suppressNextSearchChange` and skips the clear that
        // `resetForCommandBarOpen` does on every open, which would leave
        // AppState holding a stale non-empty reading for the hover-dismiss
        // monitor (an AppKit service with no direct view access — see
        // `CommandBarPanelController.evaluateHoverDismiss`).
        //
        // A scope chip (e.g. "@Finder") or an active search engine alias
        // (e.g. [Jira]) counts as non-empty even when the text field itself is
        // blank, so the hover-dismiss monitor doesn't yank the bar out from
        // under an in-progress scoped search or alias query.
        let afterFieldObservers: AnyView = AnyView(
            afterAppear
                .onChange(of: searchText) { _, _ in
                    appState.recordTypingActivity()
                    appState.isSearchTextEmpty = isSearchEmpty
                }
                .onChange(of: scopeChips) { _, _ in
                    appState.isSearchTextEmpty = isSearchEmpty
                }
                .onChange(of: activeSearchAlias) { _, _ in
                    appState.isSearchTextEmpty = isSearchEmpty
                }
                // Same mirror for the "show all tabs" expansion: the hover-dismiss
                // monitor sizes its outside-box from this (`AppState.isShowingAllOpenTabs`)
                // so a hover reveal's taller, all-tabs panel isn't mistaken for a
                // quick-open one — see `CommandBarPanelController.isCursorOutsideSurface`.
                .onChange(of: isShowingAllOpenTabs) { _, newValue in
                    appState.isShowingAllOpenTabs = newValue
                }
        )

        let beforeActivationSheet: AnyView = AnyView(
            afterFieldObservers
                .onChange(of: revealTrigger.token) { _, _ in
                    // The reveal trigger only fires for notch/edge hover opens (see
                    // `AppState.showCommandBar(revealStyle:)`), so this is the one
                    // reliable signal that the bar was opened by hover. Record it for
                    // the session, ensure mouse-open full tabs state is active, and
                    // switch to the hover default view.
                    wasOpenedByHover = true
                    wasOpenedByMouse = true
                    isShowingAllOpenTabs = true
                    appState.wasOpenedByMouse = true
                    appState.isShowingAllOpenTabs = true
                    viewStore.resetForHoverOpen()
                    playRevealAnimation()
                }
                .onChange(of: dismissTrigger.token) { _, _ in
                    playDismissAnimation()
                }
        )

        let withActivationSheet: AnyView = AnyView(
            beforeActivationSheet
                .sheet(isPresented: $isActivationPresented) {
                    LicenseActivationSheet()
                        .environmentObject(licenseService)
                }
        )

        return withActivationSheet
        .onReceive(NotificationCenter.default.publisher(for: fastTabPresentLicenseActivationNotification)) { _ in
            isActivationPresented = true
        }
        .onDisappear {
            searchDebounceTask?.cancel()
            faviconPrefetchDebounceTask?.cancel()
            toastDismissTask?.cancel()
            clearPointerSwipeSuppression()
            myOrderStore.flush()
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
                localMonitor = nil
            }
        }
        .onChange(of: appState.browserService.results.map(\.id)) {
            clampSelectionToDisplayedItems()
            scheduleFaviconPrefetch(for: displayedResults)
        }
        .onChange(of: viewStore.activeView) { _, _ in
            clampSelectionToDisplayedItems()
        }
        .onChange(of: myOrderStore.slots.count) { _, _ in
            clampSelectionToDisplayedItems()
        }
        .onChange(of: sentLinkInbox.pendingCommands.count) { _, _ in
            clampSelectionToDisplayedItems()
        }
    }

    func clampSelectionToDisplayedItems() {
        let items = displayedItems
        if items.isEmpty {
            appState.selectedIndex = -1
            isSearchFocused = true
            clearKeyboardSwipe()
            resetPointerSwipe(animated: false)
        } else if searchText.isEmpty {
            if appState.selectedIndex >= items.count {
                appState.selectedIndex = max(0, items.count - 1)
                clearKeyboardSwipe()
                resetPointerSwipe(animated: false)
            }
        } else if appState.selectedIndex < 0 || appState.selectedIndex >= items.count {
            appState.selectedIndex = 0
            clearKeyboardSwipe()
            resetPointerSwipe(animated: false)
        }
    }

    /// Ambient shadow behind the surface. Sized and positioned exactly like the
    /// surface (the caller aligns it against the same edge), so it needs no
    /// knowledge of the canvas — only the direction to lean away from the edge.
    private func ambientShadow(anchor: EdgeRevealStyle, surfaceSize: CGSize) -> some View {
        let shadowColor = commandBarFullScreenShadowColor(for: colorScheme)
        let shift = CommandBarLayout.shadowShiftVector(for: anchor)
        let scale = revealScale(for: anchor, surfaceSize: surfaceSize)
        let anchorPoint = CommandBarLayout.revealAnchorUnitPoint(for: anchor)
        // The blur has to shrink with the panel too: left at its full radius it
        // spread the sliver-sized shadow into a haze reaching well past the
        // anchor edge, which read as a smudge floating away from the
        // notch/edge during the first frames of the reveal.
        let blurScale = CommandBarLayout.isCompact(anchor) ? scale.width : scale.height

        return Rectangle()
            .fill(shadowColor.opacity(0.6))
            .frame(
                width: surfaceSize.width,
                height: surfaceSize.height
            )
            // Shifted toward the surface's growth direction so the shadow reads
            // as cast away from the flush/anchor edge instead of evenly
            // surrounding the panel — applied *inside* the `scaleEffect` below
            // so the shift shrinks with the reveal and the shadow stays tucked
            // under the surface (see `CommandBarLayout.shadowShiftVector`).
            .offset(x: shift.width, y: shift.height)
            // Scaled from the same anchor/initial-scale as the surface itself
            // (before the blur widens its layout box) so the shadow grows in
            // lockstep with the reveal instead of popping in at full size while
            // the panel is still animating.
            .scaleEffect(x: scale.width, y: scale.height, anchor: anchorPoint)
            .blur(radius: CommandBarLayout.shadowBlurRadius * blurScale)
    }

    /// Tail fade shared by the surface and its shadow, so the two can never
    /// dissolve out of step (the same reason `revealScale` is shared).
    private var revealSurfaceOpacity: Double {
        CommandBarLayout.revealSurfaceOpacity(
            depthProgress: revealDepthProgress,
            spreadProgress: revealSpreadProgress
        )
    }

    /// Current reveal scale — interpolated from the pre-reveal sliver to 1:1 by
    /// the two progress values, per axis. Shared by the surface and its ambient
    /// shadow so the two can never animate out of step.
    ///
    /// Progress can pass 1 while the spring settles; that overshoot is passed
    /// straight through, so the bar swells a hair past full size and eases
    /// back. It always overshoots *away* from the anchored edge, so it can
    /// never lift off that edge.
    private func revealScale(for anchor: EdgeRevealStyle, surfaceSize: CGSize) -> CGSize {
        let depth = revealDepthProgress
        let spread = revealSpreadProgress
        guard depth != 1 || spread != 1 else { return CGSize(width: 1, height: 1) }

        let start = CommandBarLayout.revealInitialScale(for: anchor, surfaceSize: surfaceSize)
        // For the edge anchors the bar grows sideways out of the edge, so depth
        // is the horizontal axis; under the notch it grows downward.
        let growsSideways = CommandBarLayout.isCompact(anchor)
        return CGSize(
            width: CommandBarLayout.revealAxis(from: start.width, progress: growsSideways ? depth : spread),
            height: CommandBarLayout.revealAxis(from: start.height, progress: growsSideways ? spread : depth)
        )
    }

    /// Snaps the surface to its shrunk pre-reveal scale, then springs it open
    /// on the next run-loop turn — the window is ordered front synchronously
    /// right after this is armed (`AppState.showCommandBar`), so the first
    /// rendered frame must already be shrunk or the bar flashes at full size
    /// before shrinking.
    private func playRevealAnimation() {
        revealDepthProgress = 0
        revealSpreadProgress = 0
        DispatchQueue.main.async {
            // Two springs with damping carry the expansion smoothly from the notch / screen edge to 1:
            // Depth springs out with a snappy tactile overshoot (~5-7%) and quick damped settle (~260-280ms);
            // Spread widens along the edge slightly trailing depth so the reveal expands fluidly.
            withAnimation(CommandBarLayout.revealDepthSpring) {
                revealDepthProgress = 1
            }
            withAnimation(CommandBarLayout.revealSpreadSpring) {
                revealSpreadProgress = 1
            }
        }
    }

    /// Mirror of `playRevealAnimation` for closing. One spring drives both
    /// axes together — a shrink reads fine landing in lockstep, it's only the
    /// *open* that needs depth settling before spread to read as weighted —
    /// and it's noticeably quicker than the ~0.4s open with no overshoot, so
    /// the bar visibly retreats instead of just vanishing or bouncing on the
    /// way out. `AppState.hideCommandBar()` fires the trigger that calls
    /// this but doesn't order the window out itself; it stays on screen for
    /// this animation and `finishHidingAfterDismissAnimation()` orders it out
    /// once this completes.
    private func playDismissAnimation() {
        // `.removed` rather than the default `.logicallyComplete`: a spring is
        // only *logically* done once it reaches its target, while a low-amplitude
        // tail is still playing. Ordering the window out on the logical
        // completion therefore cut that tail off mid-motion, which is exactly
        // what made the last few frames of the collapse land hard. `.removed`
        // waits for the motion to actually stop.
        withAnimation(.spring(duration: 0.24, bounce: 0), completionCriteria: .removed) {
            revealDepthProgress = 0
            revealSpreadProgress = 0
        } completion: {
            appState.finishHidingAfterDismissAnimation()
            // Ready for the next open: a non-hover open (keyboard shortcut,
            // menu bar icon) never calls `playRevealAnimation`, so it needs
            // to find these already at 1 or the bar would appear pre-shrunk.
            revealDepthProgress = 1
            revealSpreadProgress = 1
        }
    }
}
