import Foundation
import SwiftUI

public enum CommandBarView: String, CaseIterable, Codable, Sendable {
    case recents
    case myOrder
    case bookmarks

    public var displayName: String {
        switch self {
        case .recents: return "Recents"
        case .myOrder: return "My Order"
        case .bookmarks: return "Bookmarks"
        }
    }

    public var isTall: Bool {
        switch self {
        case .recents: return false
        case .myOrder, .bookmarks: return true
        }
    }

    public var iconName: String {
        switch self {
        case .recents: return "clock"
        case .myOrder: return "list.bullet"
        case .bookmarks: return "bookmark"
        }
    }

    public var index: Int {
        switch self {
        case .recents: return 0
        case .myOrder: return 1
        case .bookmarks: return 2
        }
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

    public init(defaults: UserDefaults = .standard) {
        let resolvedDefault: CommandBarView
        if let raw = defaults.string(forKey: Self.defaultViewKey),
           let stored = CommandBarView(rawValue: raw) {
            resolvedDefault = stored
        } else {
            let isExistingUser = defaults.bool(forKey: Self.onboardingCompletedKey)
            resolvedDefault = isExistingUser ? .recents : .myOrder
        }
        self.defaultView = resolvedDefault
        self.activeView = resolvedDefault

        if let rawHover = defaults.string(forKey: Self.hoverDefaultViewKey),
           let storedHover = CommandBarView(rawValue: rawHover) {
            self.hoverDefaultView = storedHover
        } else {
            self.hoverDefaultView = .myOrder
        }
    }

    public func setDefaultView(_ view: CommandBarView, defaults: UserDefaults = .standard) {
        guard view != self.defaultView else { return }
        self.defaultView = view
        defaults.set(view.rawValue, forKey: Self.defaultViewKey)
    }

    public func setHoverDefaultView(_ view: CommandBarView, defaults: UserDefaults = .standard) {
        guard view != self.hoverDefaultView else { return }
        self.hoverDefaultView = view
        defaults.set(view.rawValue, forKey: Self.hoverDefaultViewKey)
    }

    public func selectView(_ view: CommandBarView) {
        guard view != self.activeView else { return }
        slideDirection = view.index > self.activeView.index ? .forward : .backward
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            self.activeView = view
        }
    }

    public func resetForOpen(to targetView: CommandBarView? = nil) {
        let target = targetView ?? defaultView
        if target != self.activeView {
            slideDirection = target.index > self.activeView.index ? .forward : .backward
        }
        self.activeView = target
    }

    public func resetForHoverOpen() {
        if hoverDefaultView != self.activeView {
            slideDirection = hoverDefaultView.index > self.activeView.index ? .forward : .backward
        }
        self.activeView = hoverDefaultView
    }
}
