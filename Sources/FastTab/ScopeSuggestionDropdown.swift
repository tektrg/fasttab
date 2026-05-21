import SwiftUI

private struct DropdownContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct ScopeSuggestionDropdown: View {
    static let maxHeight: CGFloat = 240

    let suggestions: [ScopeSuggestion]
    let selectedIndex: Int
    let emptyStateText: String?
    let onHover: ((Int) -> Void)?
    let onPick: (ScopeSuggestion) -> Void

    @State private var contentHeight: CGFloat = 0

    init(
        suggestions: [ScopeSuggestion],
        selectedIndex: Int,
        emptyStateText: String? = nil,
        onHover: ((Int) -> Void)? = nil,
        onPick: @escaping (ScopeSuggestion) -> Void
    ) {
        self.suggestions = suggestions
        self.selectedIndex = selectedIndex
        self.emptyStateText = emptyStateText
        self.onHover = onHover
        self.onPick = onPick
    }

    var body: some View {
        if suggestions.isEmpty, let emptyStateText {
            Text(emptyStateText)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.regularMaterial)
                )
        } else if suggestions.isEmpty {
            EmptyView()
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(suggestions.enumerated()), id: \.element) { index, suggestion in
                            Button {
                                onPick(suggestion)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: suggestion.symbol)
                                        .frame(width: 16)
                                        .foregroundStyle(.secondary)
                                    Text(suggestion.label)
                                        .font(.system(size: 13, weight: .medium))
                                    if let detail = suggestion.detail {
                                        Text(detail)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(index == selectedIndex ? Color.accentColor.opacity(0.18) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering { onHover?(index) }
                            }
                            .accessibilityLabel(Text(scopeSuggestionAccessibilityLabel(for: suggestion)))
                            .accessibilityAddTraits(index == selectedIndex ? [.isSelected] : [])
                            .id(index)
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: DropdownContentHeightKey.self, value: geo.size.height)
                        }
                    )
                }
                .frame(height: min(max(contentHeight, 1), Self.maxHeight))
                .onPreferenceChange(DropdownContentHeightKey.self) { newValue in
                    if abs(newValue - contentHeight) > 0.5 {
                        contentHeight = newValue
                    }
                }
                .onChange(of: selectedIndex) { _, newValue in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        }
    }
}

private func scopeSuggestionAccessibilityLabel(for suggestion: ScopeSuggestion) -> String {
    if let detail = suggestion.detail {
        return "\(suggestion.label), \(detail)"
    }
    return suggestion.label
}

struct ScopeChipsRow: View {
    let chips: [ScopeChip]
    let focusedChipID: UUID?
    let onRemove: (ScopeChip) -> Void
    let onFocusChip: ((ScopeChip) -> Void)?

    init(
        chips: [ScopeChip],
        focusedChipID: UUID? = nil,
        onRemove: @escaping (ScopeChip) -> Void,
        onFocusChip: ((ScopeChip) -> Void)? = nil
    ) {
        self.chips = chips
        self.focusedChipID = focusedChipID
        self.onRemove = onRemove
        self.onFocusChip = onFocusChip
    }

    var body: some View {
        if chips.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                ForEach(chips) { chip in
                    let isFocused = chip.id == focusedChipID
                    HStack(spacing: 4) {
                        Text(chip.displayLabel)
                            .font(.system(size: 12, weight: .medium))
                        Button {
                            onRemove(chip)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove \(chip.displayLabel) scope")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.accentColor.opacity(isFocused ? 0.42 : 0.18))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.accentColor.opacity(isFocused ? 0.9 : 0), lineWidth: 1.5)
                    )
                    .foregroundStyle(.primary)
                    .contentShape(Capsule())
                    .onTapGesture { onFocusChip?(chip) }
                    .accessibilityAddTraits(isFocused ? [.isSelected] : [])
                }
            }
        }
    }
}
