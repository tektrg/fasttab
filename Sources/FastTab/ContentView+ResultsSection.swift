import SwiftUI

extension ContentView {
    @ViewBuilder
    func resultsSection(proxy: ScrollViewProxy) -> some View {
        // Compute once here — not inside the List closure, which runs per row.
        let showWindowName = shouldShowWindowName
        let showProfileName = shouldShowProfileName
        let resultsHeight = CommandBarLayout.resultsHeight(for: commandBarAnchor, rowStyle: rowStyle, rowCount: resultsSizingRowCount)
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
                    LazyVStack(spacing: 6) {
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

private struct ShowAllTabsRow: View {
    let count: Int
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text("Show all tabs...")
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("\(count) open \(count == 1 ? "tab" : "tabs")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
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
