import Foundation

/// Text on the Open Tabs widget (`FastTabWidgets/OpenTabsWidget.swift`), per `AppMode`.
/// Reader-only phones have no Mac, so the widget says what it needs instead of "no tabs yet".
struct OpenTabsWidgetCopy: Equatable {
    let title: String
    let emptyMessage: String
    /// Reader-only phones show only the message: no count, no tab list.
    let showsTabs: Bool

    static func `for`(mode: AppMode?) -> OpenTabsWidgetCopy {
        switch mode {
        case .standalone:
            return OpenTabsWidgetCopy(
                title: "Open tabs",
                emptyMessage: "Open Tabs needs FastTab on your Mac.",
                showsTabs: false
            )
        case .mac, nil:
            return OpenTabsWidgetCopy(
                title: "Mac tabs",
                emptyMessage: "No tabs synced from your Mac yet.",
                showsTabs: true
            )
        }
    }
}
