import SwiftUI

/// App services the command-bar views use, handed in by the composition point
/// (`FastTabApp`) instead of read from singletons, so the generic pieces can
/// later move into a package that can't see Fast Tab's stores.
struct CommandBarEnvironment {
    /// Settings › General › "Swipe rows" toggle. Read on demand (not observed).
    var isRowSwipeEnabled: () -> Bool
    /// The inline custom-view builder / delete confirmation.
    var customViewEditor: CustomViewEditorPresenter
    /// Search alias keywords and trigger keys.
    var searchAliasStore: SearchAliasStore
    /// Opens Settings on a pane, using SwiftUI's `openSettings` action.
    var openSettingsPane: (SettingsTab, OpenSettingsAction) -> Void

    /// Fast Tab's real services.
    @MainActor static var live: CommandBarEnvironment {
        CommandBarEnvironment(
            isRowSwipeEnabled: { RowSwipeGestureStore.shared.isEnabled },
            customViewEditor: .shared,
            searchAliasStore: .shared,
            openSettingsPane: { pane, openSettings in
                SettingsNavigator.shared.open(pane, using: openSettings)
            }
        )
    }
}
