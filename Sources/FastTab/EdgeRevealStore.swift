import Foundation
import AppKit
import Combine
import IndieCommandBar
import IndieEdgeReveal

/// `EdgeRevealStyle` itself lives in IndieLibKit (`IndieEdgeReveal`); its `rawValue` is the
/// persisted `FastTab.edgeReveal.style` value (`off`/`notch`/`leftEdge`/`rightEdge` predate
/// the move and are unchanged) — do not rename without a migration.
/// How the current open was triggered, and where the pointer was: the ONE owner of that state.
/// `AppState.showCommandBar` sets it before the card is shown; the card (`ContentView`), the
/// click-away test and the hover-dismiss box all read `position`, so they never disagree.
/// - Hover open (`EdgeRevealCoordinator`): the hover spot's own anchor, placed at the pointer.
/// - Shortcut / menu bar / dock open: the saved Position (Settings > Appearance), or a card on
///   the pointer when "Follow the mouse" is chosen.
@MainActor
final class CommandBarOpenSession: ObservableObject {
    static let shared = CommandBarOpenSession()

    @Published private(set) var source: CommandBarOpenSource = .keyboard
    /// Pointer (AppKit screen point, y up) when this open started.
    @Published private(set) var pointer: CGPoint?

    private init() {}

    /// `revealStyle` non-nil = a hover open from that spot.
    func begin(revealStyle: EdgeRevealStyle?, pointer: CGPoint = NSEvent.mouseLocation) {
        source = Self.source(revealStyle: revealStyle)
        self.pointer = pointer
    }

    nonisolated static func source(revealStyle: EdgeRevealStyle?) -> CommandBarOpenSource {
        revealStyle.map { .hover($0) } ?? .keyboard
    }

    /// Anchor + follow-the-pointer flag for this open, from the settings saved now.
    var position: CommandBarResolvedPosition {
        CommandBarAppearance.load().resolvedAnchor(opening: source)
    }
}

extension EdgeRevealStyle {
    /// The spots the onboarding step offers: the original four, which its
    /// hero art and layout were designed for. Settings offers every case.
    static let onboardingChoices: [EdgeRevealStyle] = [.off, .notch, .leftEdge, .rightEdge]
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

    /// Shared storage (IndieLibKit `EdgeRevealStyleSetting`); the key is unchanged.
    static let setting = EdgeRevealStyleSetting(key: "FastTab.edgeReveal.style")
    private static let onboardingCompletedKey = "onboarding.v1.completed"

    @Published private(set) var style: EdgeRevealStyle

    init(defaults: UserDefaults = .standard) {
        let isExistingUser = defaults.bool(forKey: Self.onboardingCompletedKey)
        style = Self.setting.load(from: defaults, fallback: isExistingUser ? .off : .notch)
    }

    func update(_ style: EdgeRevealStyle) {
        guard style != self.style else { return }
        self.style = style
        Self.setting.save(style)
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

    private init() {}

    func fire() {
        token += 1
    }

    /// Bumped when a floating card opens without hover (shortcut, menu bar), so it fades in
    /// too. Separate from `token`, which also switches the bar into its hover-open state.
    @Published private(set) var fadeInToken: Int = 0

    func fireFadeIn() {
        fadeInToken += 1
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
