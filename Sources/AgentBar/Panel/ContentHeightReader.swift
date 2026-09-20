import SwiftUI

/// Reports a view's natural height as it lays out, for views that cap or clip it
/// (the footer notice, the collapsed latest message) and need to know if it fits.
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    func onContentHeightChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(ContentHeightKey.self, perform: action)
    }
}
