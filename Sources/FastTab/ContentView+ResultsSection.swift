import SwiftUI
import IndieCommandBar

extension ContentView {
    /// All currently-audible tabs, independent of the active search text — the
    /// "Playing now" strip must stay visible even when a query filters the
    /// tab out of the main results (`cachedLiveTabs` isn't query-filtered like
    /// `displayedResults` is).
    var audibleSectionTabs: [BrowserSearchResult] {
        appState.browserService.cachedLiveTabs.filter(\.isPinnedAudibleTab)
    }

    @ViewBuilder
    private func audibleTabsStrip(_ tabs: [BrowserSearchResult]) -> some View {
        if !tabs.isEmpty {
            VStack(spacing: 4) {
                HStack {
                    Text("PLAYING NOW")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)

                ForEach(tabs, id: \.id) { tab in
                    AudibleTabRow(
                        result: tab,
                        faviconImage: appState.browserService.faviconImage(for: tab),
                        onSelect: { activateAndHide(tab) },
                        onMute: { appState.browserService.toggleMute(tab) }
                    )
                    .padding(.horizontal, 8)
                }

                Divider().padding(.horizontal, 8).padding(.top, 2)
            }
        }
    }

    /// Everything pinned above the results list, inside its height budget
    /// (the window can't grow): the Automation-denied banner, then "Playing now".
    @ViewBuilder
    private func resultsTopStrips(_ audibleTabs: [BrowserSearchResult]) -> some View {
        AutomationDeniedBanner(isCommandBarVisible: appState.isVisible)
        audibleTabsStrip(audibleTabs)
    }

    var modeSlideTransition: AnyTransition {
        let isForward = viewStore.slideDirection == .forward
        return .asymmetric(
            insertion: .move(edge: isForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: isForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    @ViewBuilder
    func resultsSection() -> some View {
        let showWindowName = shouldShowWindowName
        let showProfileName = shouldShowProfileName
        let resultsHeight = CommandBarLayout.resultsHeight(for: commandBarAnchor, rowStyle: rowStyle, rowCount: resultsSizingRowCount)
        let audibleTabs = audibleSectionTabs

        // Custom views and the New View page always show their own content
        // (`CommandBarView.isCustomPage`), never the Recents search/loading.
        let isCustomPage = viewStore.activeView.isCustomPage

        Group {
            if !isCustomPage && appState.browserService.isLoading && displayedResults.isEmpty {
                VStack(spacing: 10) {
                    resultsTopStrips(audibleTabs)
                    Spacer()
                    ProgressView()
                        .controlSize(.regular)
                    Text(searchText.isEmpty ? "Fetching tabs…" : "Searching Chrome + Edge…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .frame(height: resultsHeight)
            } else if !isCustomPage && isSearchActive {
                VStack(spacing: 0) {
                    resultsTopStrips(audibleTabs)

                    if displayedItems.isEmpty {
                        searchEmptyState
                    } else {
                        CommandBarSectionedList(
                            sections: [CommandBarSection(id: "results", rows: displayedItems)],
                            selectedIndex: appState.selectedIndex,
                            followsSelection: !isSearchFocused,
                            followAnimation: Self.selectionFollowAnimation,
                            scrollToTop: listScrollToTop
                        ) { item, index in
                            displayItemRow(
                                item: item,
                                index: index,
                                isSelected: appState.selectedIndex == index,
                                showWindowName: showWindowName,
                                showProfileName: showProfileName
                            )
                        }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    resultsTopStrips(audibleTabs)

                    ZStack {
                        switch viewStore.activeView {
                        case .recents:
                            modeResultsList(for: .recents, showWindowName: showWindowName, showProfileName: showProfileName)
                                .transition(modeSlideTransition)
                        case .stack:
                            stackResultsList(showWindowName: showWindowName, showProfileName: showProfileName)
                                .transition(modeSlideTransition)
                        case .custom(let id):
                            customViewResultsList(viewID: id, showWindowName: showWindowName, showProfileName: showProfileName)
                                .id(id)
                                .transition(modeSlideTransition)
                        case .newView:
                            newViewPage
                                .transition(modeSlideTransition)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
            }
        }
        // `resultsHeight` is an estimate: the list fills what is left, and
        // the shared results frame clips any overrun to the rounded corners.
        .commandBarResultsFrame(minHeight: resultsHeight)
    }

    /// The Stack view: pinned tabs on top, iPhone-sent links ("Send to
    /// Mac") below. Headers are decorative — keyboard selection still runs
    /// over the flat `displayedItems` array (pinned first, then sent), so
    /// the Nth row's global index is its section index plus the section's
    /// offset (`stackSentLinksOffset` for the sent section).
    @ViewBuilder
    private func stackResultsList(showWindowName: Bool, showProfileName: Bool) -> some View {
        let pinnedItems = stackPinnedSlots.map(CommandBarDisplayItem.orderedEntry)
        let sentItems = stackSentLinks.map(CommandBarDisplayItem.result)
        if pinnedItems.isEmpty && sentItems.isEmpty {
            modeEmptyState(for: .stack)
        } else {
            // Flat selection: sent rows start at `stackSentLinksOffset`
            // (= pinned count), which is the section offset the list passes.
            CommandBarSectionedList(
                sections: [
                    CommandBarSection(id: "pinned", title: "PINNED", symbol: "pin.fill", rows: pinnedItems),
                    CommandBarSection(id: "sent", title: "SENT TO MAC", symbol: "iphone", rows: sentItems),
                ],
                selectedIndex: appState.selectedIndex,
                followsSelection: !isSearchFocused,
                followAnimation: Self.selectionFollowAnimation,
                scrollToTop: listScrollToTop
            ) { item, index in
                displayItemRow(
                    item: item,
                    index: index,
                    isSelected: appState.selectedIndex == index,
                    showWindowName: showWindowName,
                    showProfileName: showProfileName
                )
            }
        }
    }

    @ViewBuilder
    private func modeResultsList(for view: CommandBarView, showWindowName: Bool, showProfileName: Bool) -> some View {
        let items = displayItems(for: view)
        if items.isEmpty {
            modeEmptyState(for: view)
        } else {
            CommandBarSectionedList(
                sections: [CommandBarSection(id: "items", rows: items)],
                selectedIndex: viewStore.activeView == view ? appState.selectedIndex : nil,
                followsSelection: !isSearchFocused,
                followAnimation: Self.selectionFollowAnimation,
                scrollToTop: listScrollToTop
            ) { item, index in
                displayItemRow(
                    item: item,
                    index: index,
                    isSelected: viewStore.activeView == view && appState.selectedIndex == index,
                    showWindowName: showWindowName,
                    showProfileName: showProfileName
                )
            }
        }
    }

    @ViewBuilder
    private func modeEmptyState(for view: CommandBarView) -> some View {
        let (title, subtitle, icon): (String, String, String) = {
            switch view {
            case .recents:
                return ("No tabs found", SearchSource.recentsEmptyHint(enabled: SourceSelectionStore.shared.launchSnapshot), "rectangle.stack.badge.magnifyingglass")
            case .stack:
                return ("Stack is empty", "Pin a tab to keep it here, or send a link from your iPhone.", "square.stack")
            case .custom, .newView:
                // Custom pages have their own empty states (ContentView+CustomViews).
                return ("Nothing here", "", "square.stack.3d.up")
            }
        }()

        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "rectangle.stack.badge.magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No matches")
                .font(.headline)
            Text("Try another keyword for tabs, bookmarks, or history.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    func displayItemRow(
        item: CommandBarDisplayItem,
        index: Int,
        isSelected: Bool,
        showWindowName: Bool,
        showProfileName: Bool
    ) -> some View {
        switch item {
        case .result(let result):
            SwipeableResultRow(
                result: result,
                isSelected: isSelected,
                faviconImage: appState.browserService.faviconImage(for: result),
                showWindowName: showWindowName,
                showProfileName: showProfileName,
                pointerEdge: pointerSwipe.rowID == result.id ? pointerSwipe.revealedEdge : nil,
                pointerOffset: pointerSwipe.rowID == result.id ? pointerSwipe.offset : 0,
                keyboardEdge: keyboardSwipe.rowID == result.id ? keyboardSwipe.edge : nil,
                isConfirmingRemoval: rowRemovalExit.isExiting(result.id),
                onHoverChange: { isHovering in
                    if isHovering {
                        hoveredResultID = result.id
                    } else if hoveredResultID == result.id {
                        hoveredResultID = nil
                    }
                },
                onSelect: {
                    activateAndHide(result)
                },
                onCopy: {
                    performCopyLink(result)
                },
                onRemove: {
                    performRemove(result)
                },
                onPin: {
                    appState.browserService.togglePin(result)
                },
                onFastTabListBridge: {
                    performFastTabListBridge(result)
                }
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .center)))
        case .orderedEntry(let slot):
            OrderedTabSlotRow(
                slot: slot,
                index: index,
                isSelected: isSelected,
                faviconImage: appState.browserService.faviconImage(for: slot.asSearchResult),
                onSelect: {
                    activateOrderedSlot(slot)
                },
                onClose: {
                    myOrderStore.closeSlot(slot.slotID)
                },
                onReopen: {
                    dismissCommandBar()
                    myOrderStore.reopenSlot(slot.slotID)
                },
                onTogglePin: {
                    myOrderStore.togglePinSlot(slot.slotID)
                },
                onReorder: { from, to in
                    myOrderStore.reorderSlot(from: from, to: to)
                    appState.selectedIndex = min(to, max(0, stackPinnedSlots.count - 1))
                },
                reorderUpperBound: stackPinnedSlots.count,
                onSendToFastTabList: {
                    sendStackSlotToFastTabList(slot)
                }
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
        case .showAllTabs, .searchTheWeb, .searchAliasHint, .searchAliasQuery:
            if let row = item.actionRow(
                webSearchBrowserName: appState.browserService.webSearchTargetBrowserName,
                aliasTriggerKeys: searchAliasStore.triggerKeys
            ) {
                CommandBarActionRow(row: row, isSelected: isSelected)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 8)
                    .onTapGesture {
                        activateExtraRow(item)
                    }
            }
        }
    }

    /// How the results list glides to a keyboard-selected row.
    static var selectionFollowAnimation: Animation { .easeInOut(duration: 0.14) }
}

private struct AudibleTabRow: View {
    let result: BrowserSearchResult
    let faviconImage: NSImage?
    let onSelect: () -> Void
    let onMute: () -> Void

    @State private var isHovering = false

    private var isActionsVisible: Bool {
        CommandBarRowOverlayPolicy.isVisible(.hoverOnly, isHovering: isHovering, isSelected: false)
    }

    var body: some View {
        // The mute action overlays the trailing edge with a solid background on
        // hover via RowActionOverlay; the title reserves trailing clearance
        // while it's visible so it truncates before the button instead of
        // running underneath it.
        Button(action: onSelect) {
            HStack(spacing: 10) {
                LeadingIconColumn(
                    browserName: result.browserName,
                    fallbackSymbol: result.type.symbolName,
                    faviconImage: faviconImage
                )

                HStack(spacing: 5) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.accentColor)

                    Text(result.title)
                        .font(.system(size: 13, weight: .regular, design: .default))
                        .foregroundStyle(result.isDiscarded ? .tertiary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.trailing, CommandBarRowOverlayPolicy.reservedWidth(
                    isVisible: isActionsVisible, isCompact: true, buttonCount: 1, buttonDiameter: 20))

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .trailing) {
            RowActionOverlay(
                isSelected: false,
                isHovering: isHovering,
                isVisible: isActionsVisible,
                accentTint: Color.accentColor.opacity(0.12),
                trailingPadding: 10
            ) {
                Button(action: onMute) {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Mute tab")
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(isHovering ? 0.12 : 0.08))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
