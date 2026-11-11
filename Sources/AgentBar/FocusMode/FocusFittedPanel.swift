import SwiftUI

/// A Focus mode panel that sizes its own text (`FocusTextFit`): a hidden copy is laid out at the
/// base sizes to measure it, the visible one is drawn at the size that fits, and a scroll view
/// (with a fade at the bottom edge) takes over once even the floor does not fit.
struct FocusFittedPanel<Content: View>: View {
    @ViewBuilder let content: (FocusTextFit) -> Content
    @State private var heightAtBase: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let fit = FocusTextFit.fit(heightAtBase: heightAtBase, available: geometry.size.height)
            ScrollView(.vertical) {
                content(fit)
                    .frame(width: geometry.size.width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scrollIndicators(fit.scrolls ? .automatic : .hidden)
            .mask {
                if fit.scrolls {
                    LinearGradient(stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                } else {
                    Rectangle()
                }
            }
            .background(alignment: .topLeading) {
                content(.base)
                    .frame(width: geometry.size.width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .allowsHitTesting(false)
                    .onContentHeightChange { heightAtBase = $0 }
            }
        }
    }
}
