import SwiftUI

extension ContentView {
    var viewSwitcherSection: some View {
        CommandBarViewSwitcher(viewStore: viewStore)
    }
}
