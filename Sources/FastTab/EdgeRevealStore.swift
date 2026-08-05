import Foundation
import AppKit
import Combine

/// Where hovering reveals the FastTab peek pill. `rawValue` is the persisted
/// key in UserDefaults — do not rename without a migration.
enum EdgeRevealStyle: String, CaseIterable, Identifiable {
    case off
    case notch
    case leftEdge
    case rightEdge

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:       return "Off"
        case .notch:     return "Notch"
        case .leftEdge:  return "Left Edge"
        case .rightEdge: return "Right Edge"
        }
    }

    /// Which screen edge the command bar's shape/position hugs — always
    /// matches the configured hover-trigger spot, even when the bar was
    /// opened another way (keyboard shortcut, menu bar). Falls back to
    /// `.notch` when the hover trigger itself is off, since the bar still
    /// needs some anchor to be shaped/positioned against.
    @MainActor
    static var commandBarAnchor: EdgeRevealStyle {
        let style = EdgeRevealStore.shared.style
        return style == .off ? .notch : style
    }
}

/// UserDefaults-backed observable setting for the hover-reveal trigger.
///
/// Defaulting rule: a background mouse-position listener is new behavior, so
/// it should not silently switch on for people who already set FastTab up
/// before this feature existed. We tell "new" from "existing" by checking
/// whether onboarding (`onboarding.v1.completed`, see `OnboardingView.swift`)
/// was already finished the first time this store reads its value — existing
/// users default to `.off`, fresh installs default to `.notch`.
@MainActor
final class EdgeRevealStore: ObservableObject {
    static let shared = EdgeRevealStore()

    private static let styleKey = "FastTab.edgeReveal.style"
    private static let onboardingCompletedKey = "onboarding.v1.completed"

    @Published private(set) var style: EdgeRevealStyle

    init(defaults: UserDefaults = .standard) {
        if let raw = defaults.string(forKey: Self.styleKey),
           let stored = EdgeRevealStyle(rawValue: raw) {
            style = stored
        } else {
            let isExistingUser = defaults.bool(forKey: Self.onboardingCompletedKey)
            style = isExistingUser ? .off : .notch
        }
    }

    func update(_ style: EdgeRevealStyle) {
        guard style != self.style else { return }
        self.style = style
        UserDefaults.standard.set(style.rawValue, forKey: Self.styleKey)
    }
}

/// Arms the SwiftUI-native grow-from-edge reveal animation played when the
/// command bar opens via hover (not the keyboard shortcut or menu bar icon,
/// which appear instantly). `ContentView` observes `token` rather than
/// `anchor` because the anchor is often unchanged between two consecutive
/// hover-opens, and a `@Published` value only republishes SwiftUI observers
/// on a real change — the token's job is purely to force a fresh trigger
/// every time regardless of whether the anchor moved.
@MainActor
final class CommandBarRevealTrigger: ObservableObject {
    static let shared = CommandBarRevealTrigger()

    @Published private(set) var token: Int = 0
    private(set) var anchor: EdgeRevealStyle = .notch

    private init() {}

    func fire(anchor: EdgeRevealStyle) {
        self.anchor = anchor
        token += 1
    }
}

/// Arms the SwiftUI-native shrink-to-edge animation played on every dismiss
/// (regardless of how the bar was opened, or which of the several dismiss
/// paths — Escape, outside click, hover-away, picking a result — triggered
/// it). `AppState.hideCommandBar()` fires this instead of ordering the window
/// out directly, so the window stays on screen for the shrink; `ContentView`
/// orders it out itself once the animation finishes, via
/// `AppState.finishHidingAfterDismissAnimation()`.
@MainActor
final class CommandBarDismissTrigger: ObservableObject {
    static let shared = CommandBarDismissTrigger()

    @Published private(set) var token: Int = 0

    private init() {}

    func fire() {
        token += 1
    }
}
