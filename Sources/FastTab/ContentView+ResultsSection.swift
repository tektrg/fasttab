import SwiftUI
import CommandBarKit

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

    private var modeSlideTransition: AnyTransition {
        let isForward = viewStore.slideDirection == .forward
        return .asymmetric(
            insertion: .move(edge: isForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: isForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    @ViewBuilder
    func resultsSection(proxy: ScrollViewProxy) -> some View {
        let showWindowName = shouldShowWindowName
        let showProfileName = shouldShowProfileName
        let resultsHeight = CommandBarLayout.resultsHeight(for: commandBarAnchor, rowStyle: rowStyle, rowCount: resultsSizingRowCount)
        let audibleTabs = audibleSectionTabs

        Group {
            if appState.browserService.isLoading && displayedResults.isEmpty {
                VStack(spacing: 10) {
                    audibleTabsStrip(audibleTabs)
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
            } else if !searchText.isEmpty {
                VStack(spacing: 0) {
                    audibleTabsStrip(audibleTabs)

                    if displayedItems.isEmpty {
                        searchEmptyState
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                                    displayItemRow(
                                        item: item,
                                        index: index,
                                        isSelected: appState.selectedIndex == index,
                                        showWindowName: showWindowName,
                                        showProfileName: showProfileName
                                    )
                                }
                            }
                            .padding(.vertical, 3)
                        }
                        .background(Color.clear)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    audibleTabsStrip(audibleTabs)

                    ZStack {
                        switch viewStore.activeView {
                        case .recents:
                            modeResultsList(for: .recents, showWindowName: showWindowName, showProfileName: showProfileName)
                                .transition(modeSlideTransition)
                        case .myOrder:
                            modeResultsList(for: .myOrder, showWindowName: showWindowName, showProfileName: showProfileName)
                                .transition(modeSlideTransition)
                        case .bookmarks:
                            modeResultsList(for: .bookmarks, showWindowName: showWindowName, showProfileName: showProfileName)
                                .transition(modeSlideTransition)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
            }
        }
        // `resultsHeight` is what the surface is sized around, but the chrome
        // allowance it budgets for is an estimate — the list takes up whatever
        // is actually left over so the slack never shows as a dead band.
        .frame(minHeight: resultsHeight, maxHeight: .infinity)
        .background(CommandBarSurfaceBackground(cornerRadius: 16))
    }

    @ViewBuilder
    private func modeResultsList(for view: CommandBarView, showWindowName: Bool, showProfileName: Bool) -> some View {
        let items = displayItems(for: view)
        if items.isEmpty {
            modeEmptyState(for: view)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        displayItemRow(
                            item: item,
                            index: index,
                            isSelected: viewStore.activeView == view && appState.selectedIndex == index,
                            showWindowName: showWindowName,
                            showProfileName: showProfileName
                        )
                    }
                }
                .padding(.vertical, 3)
            }
            .background(Color.clear)
        }
    }

    @ViewBuilder
    private func modeEmptyState(for view: CommandBarView) -> some View {
        let (title, subtitle, icon): (String, String, String) = {
            switch view {
            case .recents:
                return ("No tabs found", "Open a tab in Chrome or Edge and try again.", "rectangle.stack.badge.magnifyingglass")
            case .myOrder:
                return ("No tabs in My Order", "Add or reorder tabs to customize your list.", "list.bullet.rectangle")
            case .bookmarks:
                return ("No bookmarks found", "Bookmarks from your browser will appear here.", "bookmark")
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
    private func displayItemRow(
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
                pointerAction: pointerSwipeResultID == result.id ? pointerSwipeAction : nil,
                pointerOffset: pointerSwipeResultID == result.id ? pointerSwipeOffset : 0,
                keyboardAction: keyboardSwipeResultID == result.id ? keyboardSwipeAction : nil,
                isConfirmingRemoval: closingResultID == result.id,
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
                }
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .center)))
        case .orderedEntry(let slot):
            OrderedTabSlotRow(
                slot: slot,
                index: index - myOrderSlotIndexOffset,
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
                    appState.selectedIndex = myOrderSlotIndexOffset + min(to, max(0, myOrderStore.slots.count - 1))
                }
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
        case .bookmarkRow(let row):
            BookmarkTreeRow(
                row: row,
                isSelected: isSelected,
                onSelect: {
                    switch row {
                    case .folder(let id, _, _, _, _, _):
                        bookmarkTreeStore.toggleFolder(id)
                    case .bookmark(let item, _, let liveTab, _, _):
                        if let liveTab {
                            activateAndHide(liveTab)
                        } else {
                            activateAndHide(item.asSearchResult)
                        }
                    }
                },
                onToggleFolder: {
                    if case .folder(let id, _, _, _, _, _) = row {
                        bookmarkTreeStore.toggleFolder(id)
                    }
                },
                onCopy: {
                    if case .bookmark(let item, _, _, _, _) = row {
                        performCopyLink(item.asSearchResult)
                    }
                },
                onRemove: {
                    if case .bookmark(let item, _, _, let isArmed, let isDeleting) = row {
                        guard !isDeleting else { return }
                        if isArmed {
                            deleteBookmarkConfirmed(item)
                        } else {
                            bookmarkTreeStore.armedBookmarkID = item.uniqueKey
                        }
                    }
                },
                onCloseTab: {
                    if case .bookmark(_, _, let liveTab, _, _) = row, let liveTab {
                        appState.browserService.remove(liveTab)
                    }
                }
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
        case .showAllTabs(let count):
            ShowAllTabsRow(count: count, isSelected: isSelected)
                .contentShape(Rectangle())
                .padding(.horizontal, 8)
                .onTapGesture {
                    expandAllOpenTabs()
                }
        case .searchTheWeb(let query):
            SearchTheWebRow(
                query: query,
                browserName: appState.browserService.webSearchTargetBrowserName,
                isSelected: isSelected
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .onTapGesture {
                activateSearchTheWeb(query: query)
            }
        case .searchAliasHint(let alias):
            SearchAliasHintRow(
                alias: alias,
                triggerKeys: searchAliasStore.triggerKeys,
                isSelected: isSelected
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .onTapGesture {
                commitSearchAlias(alias)
            }
        case .searchAliasQuery(let alias, let query):
            SearchAliasQueryRow(
                alias: alias,
                query: query,
                isSelected: isSelected
            )
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .onTapGesture {
                activateSearchAlias(alias: alias, query: query)
            }
        }
    }

    func deleteBookmarkConfirmed(_ item: BookmarkItem) {
        bookmarkTreeStore.armedBookmarkID = nil
        bookmarkTreeStore.deletingBookmarkIDs.insert(item.uniqueKey)
        Task {
            let ok = await appState.browserService.deleteBookmarkAsync(item.asSearchResult)
            await MainActor.run {
                if ok {
                    withAnimation(.easeOut(duration: 0.2)) {
                        _ = bookmarkTreeStore.removeBookmark(id: item.id, browserName: item.browserName, profileName: item.profileName)
                        bookmarkTreeStore.deletingBookmarkIDs.remove(item.uniqueKey)
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        bookmarkTreeStore.deletingBookmarkIDs.remove(item.uniqueKey)
                    }
                    showToast("Could not delete bookmark from \(item.browserName)")
                }
            }
        }
    }

    func scrollResultsToTop(_ proxy: ScrollViewProxy) {
        guard let firstItemID = displayedItems.first?.id else { return }
        proxy.scrollTo(firstItemID, anchor: .top)
    }

    func scrollSelectedResultIntoView(_ proxy: ScrollViewProxy) {
        let items = displayedItems
        guard items.indices.contains(appState.selectedIndex) else { return }
        proxy.scrollTo(items[appState.selectedIndex].id, anchor: .center)
    }
}

private struct AudibleTabRow: View {
    let result: BrowserSearchResult
    let faviconImage: NSImage?
    let onSelect: () -> Void
    let onMute: () -> Void

    @State private var isHovering = false

    var body: some View {
        // The mute action overlays the trailing edge with a solid background on
        // hover via RowActionOverlay, allowing the tab title to take full width
        // while preserving unambiguous click hit-testing for both controls.
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
                        .font(.system(size: 13, weight: .semibold, design: .default))
                        .foregroundStyle(result.isDiscarded ? .tertiary : .primary)
                        .lineLimit(1)
                }

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
                isVisible: isHovering,
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
