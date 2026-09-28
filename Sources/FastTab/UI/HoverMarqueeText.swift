import SwiftUI

/// Single-line text that, after hovering for `hoverDelay`, scrolls
/// back and forth to reveal the part hidden by tail truncation.
/// Text that already fits never moves. Font and foreground style come
/// from the environment, like a plain `Text`.
struct HoverMarqueeText: View {
    let text: String
    var hoverDelay: Duration = .milliseconds(300)
    /// Scroll speed in points per second.
    var speed: Double = 40

    @State private var fullWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var isScrolling = false
    @State private var offset: CGFloat = 0
    @State private var hoverTask: Task<Void, Never>?

    init(_ text: String) {
        self.text = text
    }

    private var overflow: CGFloat { max(0, fullWidth - boxWidth) }

    var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.tail)
            .opacity(isScrolling ? 0 : 1)
            .background(widthReader { boxWidth = $0 })
            .background(
                // Untruncated copy, only to measure the full width.
                Text(text)
                    .lineLimit(1)
                    .fixedSize()
                    .hidden()
                    .background(widthReader { fullWidth = $0 })
            )
            .overlay(alignment: .leading) {
                if isScrolling {
                    Text(text)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: offset)
                }
            }
            .clipped()
            .onHover(perform: handleHover)
            .onDisappear(perform: stop)
            .onChange(of: text) { stop() }
    }

    private func widthReader(_ update: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { update(proxy.size.width) }
                .onChange(of: proxy.size.width) { update(proxy.size.width) }
        }
    }

    private func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        guard hovering else {
            stop()
            return
        }
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: hoverDelay)
            guard !Task.isCancelled, overflow > 1 else { return }
            start()
        }
    }

    private func start() {
        let distance = overflow
        isScrolling = true
        offset = 0
        withAnimation(
            .linear(duration: max(0.6, distance / speed))
                .delay(0.4)
                .repeatForever(autoreverses: true)
        ) {
            offset = -distance
        }
    }

    private func stop() {
        hoverTask?.cancel()
        hoverTask = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isScrolling = false
            offset = 0
        }
    }
}
