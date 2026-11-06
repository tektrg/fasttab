import Foundation
import SwiftUI
import Combine

/// One swipeable page of the command bar. Order (see
/// `CommandBarViewStore.availableViews`): Recents → Stack → the user's custom
/// views (in `CustomViewStore` order) → "＋ New View".
///
/// Persisted (default / hover-default view) as a plain string — `rawValue` —
/// so the pre-custom-views values "recents" / "stack" still decode as-is;
/// a custom view is stored as "custom:<UUID>".
public enum CommandBarView: Hashable, Codable, Sendable {
    case recents
    case stack
    /// A user-defined `CustomView`, by id.
    case custom(UUID)
    /// The trailing "＋ New View" page (builder placeholder until slice 3).
    case newView

    /// The fixed pages, in swipe order. They also own the global per-view
    /// shortcuts (`ShortcutStore`).
    public static let builtins: [CommandBarView] = [.recents, .stack]

    private static let customPrefix = "custom:"

    public var rawValue: String {
        switch self {
        case .recents: return "recents"
        case .stack: return "stack"
        case .custom(let id): return Self.customPrefix + id.uuidString
        case .newView: return "newView"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "recents": self = .recents
        case "stack": self = .stack
        case "newView": self = .newView
        default:
            guard rawValue.hasPrefix(Self.customPrefix),
                  let id = UUID(uuidString: String(rawValue.dropFirst(Self.customPrefix.count))) else { return nil }
            self = .custom(id)
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let view = CommandBarView(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown view \(raw)"))
        }
        self = view
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var customID: UUID? {
        if case .custom(let id) = self { return id }
        return nil
    }

    /// Custom views and the New View page are full pages of their own: they
    /// ignore the Recents search (which keeps its text across switches) and
    /// always show their own content.
    public var isCustomPage: Bool {
        switch self {
        case .recents, .stack: return false
        case .custom, .newView: return true
        }
    }

    /// Tall pages size the panel to `expandedAllTabsMaxRows` (both the SwiftUI
    /// surface and the hover-dismiss hit test — `CommandBarLayout.surfaceMaxRows`).
    public var isTall: Bool {
        switch self {
        case .recents: return false
        case .stack, .custom, .newView: return true
        }
    }

    /// Name for builtins / New View; custom views resolve through
    /// `customViews` ("Untitled View" when the name is blank or the id is gone).
    func displayName(customViews: [CustomView]) -> String {
        switch self {
        case .recents: return "Recents"
        case .stack: return "Stack"
        case .newView: return "New View"
        case .custom(let id):
            let name = customViews.first { $0.id == id }?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? "Untitled View" : name
        }
    }

    func iconName(customViews: [CustomView]) -> String {
        switch self {
        case .recents: return "clock"
        case .stack: return "square.stack"
        case .newView: return "plus"
        case .custom(let id):
            let icon = customViews.first { $0.id == id }?.iconName ?? ""
            return icon.isEmpty ? CustomView.defaultIconName : icon
        }
    }

    @MainActor public var displayName: String { displayName(customViews: CustomViewStore.shared.views) }
    @MainActor public var iconName: String { iconName(customViews: CustomViewStore.shared.views) }

    /// Swipe order: builtins, then `customViews` in order, then New View.
    static func ordered(customViews: [CustomView]) -> [CommandBarView] {
        builtins + customViews.map { .custom($0.id) } + [.newView]
    }

    /// ⌘1…⌘9 targets: every page except New View (it is a builder, not a
    /// view, and its position shifts as views are added). ⌘N = the Nth entry;
    /// nil past the end.
    static func numberedShortcutTarget(_ number: Int, in ordered: [CommandBarView]) -> CommandBarView? {
        let numbered = ordered.filter { $0 != .newView }
        guard number >= 1, number <= min(9, numbered.count) else { return nil }
        return numbered[number - 1]
    }

    /// The neighbouring page `step` places away in `ordered` (positive =
    /// forward), clamped: nil at either end or when `current` is not listed.
    static func neighbor(of current: CommandBarView, step: Int, in ordered: [CommandBarView]) -> CommandBarView? {
        guard let index = ordered.firstIndex(of: current) else { return nil }
        let target = index + step
        guard ordered.indices.contains(target), target != index else { return nil }
        return ordered[target]
    }
}

public enum SlideDirection: Sendable {
    case forward
    case backward
}

@MainActor
public final class CommandBarViewStore: ObservableObject {
    public static let shared = CommandBarViewStore()

    public static let defaultViewKey = "FastTab.commandBarView.default"
    public static let hoverDefaultViewKey = "FastTab.commandBarView.hoverDefault"
    private static let onboardingCompletedKey = "onboarding.v1.completed"

    @Published public var activeView: CommandBarView
    @Published public private(set) var defaultView: CommandBarView
    @Published public private(set) var hoverDefaultView: CommandBarView
    @Published public private(set) var slideDirection: SlideDirection = .forward
    /// Every page in swipe order (see `CommandBarView`); follows
    /// `CustomViewStore.views`.
    @Published public private(set) var availableViews: [CommandBarView]

    private let defaults: UserDefaults
    private var customViewsSubscription: AnyCancellable?

    init(defaults: UserDefaults = .standard, customViewStore: CustomViewStore = .shared) {
        self.defaults = defaults
        let customViews = customViewStore.views
        let ordered = CommandBarView.ordered(customViews: customViews)
        self.availableViews = ordered

        let resolvedDefault: CommandBarView
        if let raw = defaults.string(forKey: Self.defaultViewKey),
           let stored = Self.decodeView(raw, available: ordered) {
            resolvedDefault = stored
        } else {
            let isExistingUser = defaults.bool(forKey: Self.onboardingCompletedKey)
            resolvedDefault = isExistingUser ? .recents : .stack
        }
        self.defaultView = resolvedDefault
        self.activeView = resolvedDefault

        if let rawHover = defaults.string(forKey: Self.hoverDefaultViewKey),
           let storedHover = Self.decodeView(rawHover, available: ordered) {
            self.hoverDefaultView = storedHover
        } else {
            self.hoverDefaultView = .recents
        }

        // `@Published` emits in willSet, so use the delivered value rather
        // than reading the store back.
        customViewsSubscription = customViewStore.$views
            .dropFirst()
            .sink { [weak self] views in
                MainActor.assumeIsolated { self?.customViewsDidChange(views) }
            }
    }

    /// Decodes a persisted view, migrating the pre-Stack raw values:
    /// "myOrder" became "stack", and the removed "bookmarks" view falls
    /// back to Recents (bookmarks now live in Settings). A custom view that
    /// no longer exists — and the New View page, which is never a default —
    /// fall back to Recents.
    static func decodeView(_ raw: String, available: [CommandBarView]) -> CommandBarView? {
        if raw == "myOrder" { return .stack }
        if raw == "bookmarks" { return .recents }
        guard let view = CommandBarView(rawValue: raw) else { return nil }
        if view == .newView { return .recents }
        if view.customID != nil, !available.contains(view) { return .recents }
        return view
    }

    /// Pages offered by the default-view pickers: builtins + custom views.
    public var selectableDefaultViews: [CommandBarView] {
        availableViews.filter { $0 != .newView }
    }

    public func index(of view: CommandBarView) -> Int {
        availableViews.firstIndex(of: view) ?? 0
    }

    public func setDefaultView(_ view: CommandBarView, defaults: UserDefaults? = nil) {
        guard view != self.defaultView, view != .newView, availableViews.contains(view) else { return }
        self.defaultView = view
        (defaults ?? self.defaults).set(view.rawValue, forKey: Self.defaultViewKey)
    }

    public func setHoverDefaultView(_ view: CommandBarView, defaults: UserDefaults? = nil) {
        guard view != self.hoverDefaultView, view != .newView, availableViews.contains(view) else { return }
        self.hoverDefaultView = view
        (defaults ?? self.defaults).set(view.rawValue, forKey: Self.hoverDefaultViewKey)
    }

    public func selectView(_ view: CommandBarView) {
        guard view != self.activeView, availableViews.contains(view) else { return }
        slideDirection = index(of: view) > index(of: activeView) ? .forward : .backward
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            self.activeView = view
        }
    }

    /// ⌘1…⌘9 (see `CommandBarView.numberedShortcutTarget`). Returns false
    /// when the number maps to no page.
    @discardableResult
    public func selectNumberedView(_ number: Int) -> Bool {
        guard let target = CommandBarView.numberedShortcutTarget(number, in: availableViews) else { return false }
        selectView(target)
        return true
    }

    public func resetForOpen(to targetView: CommandBarView? = nil) {
        var target = targetView ?? defaultView
        if !availableViews.contains(target) { target = .recents }
        if target != self.activeView {
            slideDirection = index(of: target) > index(of: activeView) ? .forward : .backward
        }
        self.activeView = target
    }

    public func resetForHoverOpen() {
        resetForOpen(to: hoverDefaultView)
    }

    /// Keeps the page list in step with the user's views. A deleted view that
    /// was active, the default, or the hover default falls back to Recents
    /// (the defaults are rewritten so the stale id doesn't linger).
    private func customViewsDidChange(_ views: [CustomView]) {
        let ordered = CommandBarView.ordered(customViews: views)
        if ordered != availableViews { availableViews = ordered }
        if !ordered.contains(activeView) {
            slideDirection = .backward
            activeView = .recents
        }
        if !ordered.contains(defaultView) {
            defaultView = .recents
            defaults.set(CommandBarView.recents.rawValue, forKey: Self.defaultViewKey)
        }
        if !ordered.contains(hoverDefaultView) {
            hoverDefaultView = .recents
            defaults.set(CommandBarView.recents.rawValue, forKey: Self.hoverDefaultViewKey)
        }
    }
}
