import SwiftUI
import TipKit

/// First-time tips (Apple TipKit). Every tip lives here so the copy and the
/// rules are reviewed in one place.
///
/// - Each tip sits on a different root tab, so at most one is ever on screen.
/// - None shows until the first-run guide is finished or skipped
///   (`isOnboardingCompleted`), so a tip never competes with the guide.
/// - A tip goes away for good when the user closes it or does what it
///   teaches (`invalidate(reason: .actionPerformed)` at the call site), and
///   after `maxDisplayCount` sightings at most, so it never nags.
/// - Replaying the Setup Guide does not bring tips back: TipKit can only wipe
///   its store before `Tips.configure`, i.e. on the next launch, and the guide
///   is about setup, not about re-teaching gestures the user already met.
enum FastTabTips {
    /// Mirrors `OnboardingCompletionStore.isCompleted`; TipKit rules can only read
    /// their own parameters, not UserDefaults.
    @Parameter static var isOnboardingCompleted: Bool = false

    static let maxDisplayCount = 3

    /// Debug-only launch argument that shows every tip regardless of rules,
    /// for screenshots and manual QA.
    static let showAllLaunchArgument = "-FastTabShowAllTips"

    /// Call once, at app start, before any view with a tip appears.
    static func configure(onboardingCompleted: Bool) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(showAllLaunchArgument) {
            Tips.showAllTipsForTesting()
        }
        #endif
        do {
            try Tips.configure([.displayFrequency(.immediate)])
        } catch {
            // Already configured (e.g. SwiftUI previews): tips keep working.
        }
        isOnboardingCompleted = onboardingCompleted
    }
}

/// Shared rules and options for every FastTab tip.
protocol FastTabTip: Tip {}

extension FastTabTip {
    var rules: [Rule] {
        [#Rule(FastTabTips.$isOnboardingCompleted) { $0 == true }]
    }

    var options: [TipOption] {
        [Tips.MaxDisplayCount(FastTabTips.maxDisplayCount)]
    }
}

/// Read tab, first time the Emerging carousel has cards.
/// Lanes: `EmergingContentProvider` (Forgotten = bookmarks 30+ days old and
/// tabs idle 3+ days; Pick up = pages visited in the last 3 days, not open now).
struct EmergingLanesTip: FastTabTip {
    var title: Text { Text("Forgotten and Pick up") }
    var message: Text? {
        Text("Forgotten: month-old bookmarks and tabs left idle for days. Pick up: pages you visited lately but closed.")
    }
    var image: Image? { Image(systemName: "sparkles") }
}

/// Shuffle tab, first time the deck has a card (`RandomLinksView`).
struct ShuffleSwipeTip: FastTabTip {
    var title: Text { Text("Swipe to sort") }
    var message: Text? {
        Text("Swipe left to skip until tomorrow. Swipe right to move or save it to a folder.")
    }
    var image: Image? { Image(systemName: "hand.draw") }
}

/// Tabs tab, first time the list shows tabs synced from a Mac (`TabListView`).
struct SwipeToCloseTabTip: FastTabTip {
    var title: Text { Text("Swipe to close") }
    var message: Text? { Text("Swipe left on a tab to close it on your Mac.") }
    var image: Image? { Image(systemName: "xmark.circle") }
}

/// More tab, first visit (`MoreView` → Intelligence row). `IntelligenceService`
/// clusters with NaturalLanguage and the on-device Foundation model only.
struct IntelligenceTip: FastTabTip {
    var title: Text { Text("Sort your browsing into topics") }
    var message: Text? {
        Text("Intelligence groups recent pages and suggests bookmark folders, worked out on this iPhone.")
    }
    var image: Image? { Image(systemName: "sparkles") }
}

extension View {
    /// Styles an inline `TipView` as a FastTab card. A `TipView` collapses to
    /// nothing while its tip is ineligible, so callers place it unconditionally.
    func fastTabTipStyle() -> some View {
        self
            .tipBackground(DS.Palette.surface)
            .tint(DS.Tint.action)
    }
}
