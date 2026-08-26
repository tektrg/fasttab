import SwiftUI

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

    @ViewBuilder
    func resultsSection(proxy: ScrollViewProxy) -> some View {
        // Compute once here — not inside the List closure, which runs per row.
        let showWindowName = shouldShowWindowName
        let showProfileName = shouldShowProfileName
        let resultsHeight = CommandBarLayout.resultsHeight(for: commandBarAnchor, rowStyle: rowStyle, rowCount: resultsSizingRowCount)
        let audibleTabs = audibleSectionTabs
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
                .frame(height: resultsHeight)
            } else if displayedItems.isEmpty {
                VStack(spacing: 8) {
                    audibleTabsStrip(audibleTabs)
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
                .frame(height: resultsHeight)
                .background(CommandBarSurfaceBackground(cornerRadius: 16))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        audibleTabsStrip(audibleTabs)
                        ForEach(indexedDisplayItems, id: \.element.id) { index, item in
                            switch item {
                            case .result(let result):
                                SwipeableResultRow(
                                    result: result,
                                    isSelected: appState.selectedIndex == index,
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
                                    }
                                )
                                .contentShape(Rectangle())
                                .padding(.horizontal, 8)
                                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .center)))
                                .onTapGesture {
                                    activateAndHide(result)
                                }
                            case .showAllTabs(let count):
                                ShowAllTabsRow(count: count, isSelected: appState.selectedIndex == index)
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 8)
                                    .onTapGesture {
                                        expandAllOpenTabs()
                                    }
                            case .searchTheWeb(let query):
                                SearchTheWebRow(
                                    query: query,
                                    browserName: appState.browserService.webSearchTargetBrowserName,
                                    isSelected: appState.selectedIndex == index
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
                                    isSelected: appState.selectedIndex == index
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
                                    isSelected: appState.selectedIndex == index
                                )
                                .contentShape(Rectangle())
                                .padding(.horizontal, 8)
                                .onTapGesture {
                                    activateSearchAlias(alias: alias, query: query)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
                .background(Color.clear)
            }
        }
        // `resultsHeight` is what the surface is sized around, but the chrome
        // allowance it budgets for is an estimate — the list takes up whatever
        // is actually left over so the slack never shows as a dead band.
        .frame(minHeight: resultsHeight, maxHeight: .infinity)
        .background(CommandBarSurfaceBackground(cornerRadius: 16))
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
        // The select button and the mute button are SIBLINGS in this outer
        // HStack, not one nested inside the other — a `Button` nested inside
        // a tappable parent (either another `Button` or a parent carrying
        // `.onTapGesture`) is ambiguous to hit-test on macOS, and lost to the
        // mute button in practice: clicking it fired the parent's
        // activate-and-hide instead. Two non-overlapping sibling controls
        // have no such ambiguity.
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 14)

                    if let faviconImage {
                        Image(nsImage: faviconImage)
                            .resizable()
                            .frame(width: 14, height: 14)
                    }

                    Text(result.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    Text(result.browserName)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovering {
                Button(action: onMute) {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Mute tab")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
