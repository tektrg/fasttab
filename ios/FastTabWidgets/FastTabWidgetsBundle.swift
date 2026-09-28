import SwiftUI
import WidgetKit

/// FastTab's home-screen widgets. Tap-to-open only: each one deep-links into the app
/// (`WidgetDeepLink`) and draws from the snapshot the app writes (`WidgetSnapshot`).
@main
struct FastTabWidgetsBundle: WidgetBundle {
    var body: some Widget {
        UpNextWidget()
        ReadingRingWidget()
        ShuffleWidget()
        OpenTabsWidget()
    }
}
