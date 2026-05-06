import SwiftUI

enum LastInteractionKey: Equatable {
    case none, upDown, space, leftRight
}

struct GuidanceToken: Equatable, Hashable {
    let glyph: String
    let label: String
}

struct GuidanceHint: Equatable, Hashable {
    let tokens: [GuidanceToken]

    static let empty = GuidanceHint(tokens: [])

    var isEmpty: Bool { tokens.isEmpty }
}

struct GuidanceBarView: View {
    let hint: GuidanceHint

    var body: some View {
        ZStack(alignment: .leading) {
            if !hint.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(hint.tokens.enumerated()), id: \.offset) { index, token in
                        if index > 0 {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                        }
                        HStack(spacing: 3) {
                            Text(token.glyph)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(.quaternary)
                                )
                            Text(token.label)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .id(hint)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: hint)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
