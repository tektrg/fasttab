import Foundation
import IndieSavedViews
import OSLog

/// The user's saved Agent Bar views, in page order (after All, before "＋ New view").
/// Local UserDefaults JSON; `SavedViewStore` does lossy loading and persistence.
@MainActor
final class AgentSavedViewStore: SavedViewStore<AgentViewCriteria> {
    /// Users' saved views live here; never rename.
    static let defaultsKey = "AgentBar.savedViews.v1"

    private static let logger = Logger(subsystem: AgentBarIdentity.bundleIdentifier, category: "SavedViews")

    init(defaults: UserDefaults = .standard) {
        super.init(defaults: defaults, key: Self.defaultsKey) { error in
            Self.logger.error("saved views encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
