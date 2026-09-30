import SwiftUI
import IndieMotion

/// Tab list feature tip: the search field also finds bookmarks and history on
/// every connected Mac. Shown until dismissed; the dismissal is stored as
/// IndieMotion's `MotionSeenState` under `motionSeenState`.
struct SearchEveryMacTipRow: View {
    static let tipID = "tabList.searchEveryMac"
    @AppStorage("motionSeenState") private var seenState = MotionSeenState()

    var body: some View {
        if !seenState.isDismissed(Self.tipID) {
            let dismiss = MotionCardAction(String(localized: "Got it")) {
                withAnimation(.easeOut(duration: 0.2)) { seenState = seenState.dismissing(Self.tipID) }
            }
            MotionCard(
                .tip,
                title: String(localized: "Search every Mac"),
                message: String(localized: "Pull down to search. Matches come from tabs, bookmarks and history on all your Macs."),
                primary: dismiss,
                dismiss: MotionCardAction(String(localized: "Dismiss tip"), perform: dismiss.perform)
            ) { size in
                SearchEveryMacMotionArt(size: size)
            }
            .listRowInsets(EdgeInsets(top: DS.Space.sm, leading: 0, bottom: DS.Space.sm, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }
}
