import SwiftUI
import IndieCommandBar

/// Custom view pages (user-defined views after Stack) and the trailing
/// "＋ New View" page. Kept out of `ContentView.body`, which sits at the
/// type-checker's limit.
extension ContentView {
    /// Header switcher tabs, in swipe order.
    var headerViewTabs: [CommandBarViewTab] {
        CommandBarViewTab.tabs(for: viewStore.availableViews, customViews: customViewStore.views)
    }

    /// Rows of a custom page in display (section) order; selection indexes
    /// into this. The New View page has none. Rows of another custom view
    /// (a stale snapshot mid-switch) are never returned.
    func customPageDisplayItems(for view: CommandBarView) -> [CommandBarDisplayItem] {
        guard let id = view.customID,
              let snapshot = customViewPage.snapshot,
              snapshot.viewID == id else { return [] }
        return snapshot.items.map { CommandBarDisplayItem.result($0.result) }
    }

    /// Points the page model at the active custom view while the bar is
    /// visible (warming its sources), and idles it otherwise.
    func syncCustomViewPage() {
        customViewPage.activate(viewID: appState.isVisible ? viewStore.activeView.customID : nil)
        syncCustomViewEditor()
    }

    /// Keeps the selection valid as the page's rows change, and lands on the
    /// first row when a freshly opened page gets its first results (like
    /// Stack, which selects its first row on entry).
    private func handleCustomViewSnapshotChange() {
        guard let snapshot = customViewPage.snapshot,
              snapshot.viewID == viewStore.activeView.customID else { return }
        if snapshot.isInitial, appState.selectedIndex < 0, !snapshot.items.isEmpty {
            appState.selectedIndex = 0
            isSearchFocused = false
        } else {
            clampSelectionToDisplayedItems()
        }
    }

    @ViewBuilder
    func customViewResultsList(viewID: UUID, showWindowName: Bool, showProfileName: Bool) -> some View {
        let snapshot = customViewPage.snapshot.flatMap { $0.viewID == viewID ? $0 : nil }
        let groupBy = customViewStore.view(id: viewID)?.groupBy ?? .none
        // The inline builder replaces the rows while editing this view.
        let semanticStatus = snapshot == nil ? nil : customViewPage.semanticStatus
        let now = Date()
        CustomViewEditorSlot(page: .custom(viewID), presenter: env.customViewEditor) {
            VStack(spacing: 0) {
                // Inside the page's fixed height: the rows below give way.
                if let semanticStatus, !semanticStatus.message.isEmpty {
                    CustomViewSemanticStatusLine(status: semanticStatus)
                }
                if let snapshot {
                    if snapshot.items.allSatisfy({ rowRemovalExit.isHidden($0.result.id, now: now) }) {
                        if case .sorting = semanticStatus {
                            // First AI batches still running: not "no items" yet.
                            Color.clear
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            customViewEmptyState(viewID: viewID)
                        }
                    } else {
                        CommandBarSectionedList(
                            sections: snapshot.sections.map { section in
                                CommandBarSection(
                                    id: section.id,
                                    title: section.title.isEmpty ? nil : section.title.uppercased(),
                                    symbol: Self.sectionIcon(groupBy: groupBy, sectionID: section.id),
                                    // Same rows as `displayItems` (selection indices).
                                    rows: section.items.filter { !rowRemovalExit.isHidden($0.result.id, now: now) }
                                )
                            },
                            selectedIndex: appState.selectedIndex,
                            followsSelection: !isSearchFocused,
                            followAnimation: Self.selectionFollowAnimation,
                            scrollToTop: listScrollToTop
                        ) { item, index in
                            displayItemRow(
                                item: .result(item.result),
                                index: index,
                                isSelected: appState.selectedIndex == index,
                                showWindowName: showWindowName,
                                showProfileName: showProfileName
                            )
                        }
                    }
                } else {
                    // Evaluating (first pass is off the main thread) or waiting
                    // for cold caches — blank rather than a premature "no items".
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onChange(of: customViewPage.snapshot?.revision) { _, _ in
            handleCustomViewSnapshotChange()
        }
    }

    private static func sectionIcon(groupBy: CustomViewGroupBy, sectionID: String) -> String {
        switch groupBy {
        case .none: return "square.stack.3d.up"
        case .domain: return "globe"
        }
    }

    private func customViewEmptyState(viewID: UUID) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: CommandBarView.custom(viewID).iconName(customViews: customViewStore.views))
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No items match this view")
                .font(.headline)
            Text("Open tabs, bookmarks and history that match its filters show up here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Edit View") {
                env.customViewEditor.presentEdit(id: viewID)
            }
            .controlSize(.small)
            .padding(.top, 4)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "＋ New View" — the last page: an intro with "Create View", which
    /// (like Return here) opens the inline builder in its place.
    var newViewPage: some View {
        CustomViewEditorSlot(page: .newView, presenter: env.customViewEditor) { newViewIntro }
    }

    private var newViewIntro: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "plus.rectangle.on.rectangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("New View")
                .font(.headline)
            Text("Save a page of your own: open tabs, bookmarks and history filtered by type, profile, domain or keyword, grouped the way you like.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Create View") {
                env.customViewEditor.presentNew()
            }
            .commandBarProminentButtonStyle()
            .controlSize(.small)
            .padding(.top, 4)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One quiet line above a custom view's rows: the AI filter's progress, its
/// "paused" banner when Apple Intelligence can't run, or a note (cap reached,
/// items it couldn't check).
struct CustomViewSemanticStatusLine: View {
    let status: CustomViewSemanticStatus

    var body: some View {
        HStack(spacing: 6) {
            switch status {
            case .sorting:
                ProgressView()
                    .controlSize(.mini)
            case .paused:
                Image(systemName: "pause.circle")
            case .finished:
                Image(systemName: "sparkles")
            }
            Text(status.message)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .accessibilityElement(children: .combine)
    }
}
