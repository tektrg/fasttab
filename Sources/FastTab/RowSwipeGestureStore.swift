import Foundation

@available(*, deprecated, message: "Row swipe gestures are deprecated in favor of horizontal view switching.")
@MainActor
final class RowSwipeGestureStore: ObservableObject {
    static let shared = RowSwipeGestureStore()

    static let swipeGestureEnabledKey = "FastTab.rowSwipeGesture.enabled"

    private let defaults: UserDefaults

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Self.swipeGestureEnabledKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let explicit = defaults.object(forKey: Self.swipeGestureEnabledKey) as? Bool {
            self.isEnabled = explicit
        } else {
            // Disabled by default for all users in favor of view switching anywhere in the app
            self.isEnabled = false
        }
    }
}
