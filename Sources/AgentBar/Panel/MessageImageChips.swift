import SwiftUI

/// The images attached to a message draft: a row of thumbnails, each with a remove button. Fixed
/// height (`height`): the card's body height is fixed, so this takes its room from the scrolling
/// last-message section above it, never from the window.
struct MessageImageChips: View {
    static let height: CGFloat = 40

    let images: [MessageImage]
    let removable: Bool
    let onRemove: (UUID) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(images) { image in
                ZStack(alignment: .topTrailing) {
                    thumbnail(image)
                    if removable {
                        Button { onRemove(image.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Remove image")
                        .offset(x: 4, y: -4)
                    }
                }
            }
            Text(images.count == 1 ? "1 image" : "\(images.count) images")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(height: Self.height)
    }

    private func thumbnail(_ image: MessageImage) -> some View {
        Group {
            if let nsImage = NSImage(data: image.thumbnail) {
                Image(nsImage: nsImage).resizable().scaledToFill()
            } else {
                Color.primary.opacity(0.1)
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
    }
}
