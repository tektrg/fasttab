import Foundation
import IndieSavedViews
import OSLog

/// The user's saved custom views, in swipe order (after Recent and Stack,
/// before "＋ New View"). Local-only UserDefaults JSON; the shared
/// `SavedViewStore` does the load (lossy per entry), mutations and persistence.
@MainActor
final class CustomViewStore: SavedViewStore<WebViewCriteria> {
    static let shared = CustomViewStore()

    /// Users' saved views live here; never rename.
    static let defaultsKey = "FastTab.customViews.v1"

    private static let logger = Logger(subsystem: "com.trungluong.FastTab", category: "CustomViewStore")

    init(defaults: UserDefaults = .standard) {
        super.init(defaults: defaults, key: Self.defaultsKey) { error in
            Self.logger.error("custom views encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
