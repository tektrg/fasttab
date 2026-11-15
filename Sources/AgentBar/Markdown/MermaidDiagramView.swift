import AppKit
import SwiftUI

/// Size rule for a drawn diagram (pure, tested). pele lays labels out at 16px; the diagram is drawn
/// so its labels match the prose (`bodySize / 16`), then scaled DOWN uniformly to the width it is given
/// and to `maxHeight` — never wrapped or clipped, never scaled up past that. Height is always
/// width × aspect, and the image exists on the first layout pass (the render is synchronous and
/// cached), so there is no placeholder and no settle: the question under a card never moves.
enum MermaidLayout {
    static func maxHeight(bodySize: CGFloat) -> CGFloat { 360 * bodySize / 12 }

    static func preferredSize(natural: CGSize, bodySize: CGFloat) -> CGSize {
        let factor = bodySize / 16
        return CGSize(width: natural.width * factor, height: natural.height * factor)
    }

    static func fitted(natural: CGSize, bodySize: CGFloat, availableWidth: CGFloat) -> CGSize {
        let preferred = preferredSize(natural: natural, bodySize: bodySize)
        guard preferred.width > 0, preferred.height > 0 else { return .zero }
        let scale = min(1, availableWidth / preferred.width, maxHeight(bodySize: bodySize) / preferred.height)
        return CGSize(width: preferred.width * scale, height: preferred.height * scale)
    }

    /// Below this the labels are hard to read → the "click to enlarge" hint is shown.
    static func isShrunk(natural: CGSize, bodySize: CGFloat, fitted: CGSize) -> Bool {
        fitted.width < preferredSize(natural: natural, bodySize: bodySize).width * 0.75
    }
}

/// One ```mermaid block: the diagram on a tile, click → popover at full size. A source pele can't
/// draw falls back to `fallback` (the plain code tile).
struct MermaidDiagramView<Fallback: View>: View {
    let source: String
    let bodySize: CGFloat
    @ViewBuilder let fallback: () -> Fallback

    @Environment(\.colorScheme) private var colorScheme
    @State private var enlarged = false

    var body: some View {
        let dark = colorScheme == .dark
        switch MermaidRenderer.render(source, dark: dark) {
        case .failure:
            fallback()
        case .image(let image, let natural):
            let preferred = MermaidLayout.preferredSize(natural: natural, bodySize: bodySize)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: preferred.width, maxHeight: min(preferred.height, MermaidLayout.maxHeight(bodySize: bodySize)))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: MermaidRenderer.tileColor(dark: dark))))
                .contentShape(Rectangle())
                .onTapGesture { enlarged = true }
                .help("Click to enlarge")
                .accessibilityLabel("Diagram")
                .popover(isPresented: $enlarged, arrowEdge: .trailing) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: natural.width, height: natural.height)
                            .padding(16)
                    }
                    .frame(width: min(natural.width + 32, 1000), height: min(natural.height + 32, 760))
                    .background(Color(nsColor: MermaidRenderer.tileColor(dark: dark)))
                }
        }
    }
}
