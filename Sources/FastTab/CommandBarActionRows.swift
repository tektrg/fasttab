import SwiftUI

/// Shared chrome for the non-result rows in the command bar list ("Show all
/// tabs…", "Search the web", the search-alias rows).
///
/// These all render as one accent-glyph + title + caption line with the same
/// selection treatment; before this existed each row re-declared the identical
/// padding, rounded-rect selection fill, border and scale animation, so a
/// tweak to the selected look had to be made in several places to stay
/// consistent.
struct CommandBarActionRow<Trailing: View>: View {
    let symbolName: String
    let title: String
    /// Small caption under the title. `captionSymbolName` is its leading glyph.
    let caption: String?
    let captionSymbolName: String?
    let isSelected: Bool
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .default))
                    .lineLimit(1)

                if let caption {
                    HStack(spacing: 5) {
                        if let captionSymbolName {
                            Image(systemName: captionSymbolName)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            trailing
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.17) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : .clear, lineWidth: 1)
                )
        )
        .scaleEffect(isSelected ? 1.01 : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isSelected)
    }
}

extension CommandBarActionRow where Trailing == EmptyView {
    init(
        symbolName: String,
        title: String,
        caption: String?,
        captionSymbolName: String?,
        isSelected: Bool
    ) {
        self.init(
            symbolName: symbolName,
            title: title,
            caption: caption,
            captionSymbolName: captionSymbolName,
            isSelected: isSelected,
            trailing: { EmptyView() }
        )
    }
}

struct ShowAllTabsRow: View {
    let count: Int
    let isSelected: Bool

    var body: some View {
        CommandBarActionRow(
            symbolName: "rectangle.stack.fill",
            title: "Show all tabs...",
            caption: "\(count) open \(count == 1 ? "tab" : "tabs")",
            captionSymbolName: "list.bullet",
            isSelected: isSelected
        ) {
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
    }
}

struct SearchTheWebRow: View {
    let query: String
    let browserName: String?
    let isSelected: Bool

    var body: some View {
        CommandBarActionRow(
            symbolName: "magnifyingglass",
            title: "Search \u{201c}\(query)\u{201d}",
            caption: browserName.map { "Opens a new tab in \($0)" },
            captionSymbolName: "globe",
            isSelected: isSelected
        )
    }
}

/// Offered when the typed text exactly names an alias but hasn't been committed
/// yet. Deliberately worded as an instruction rather than an action: this row
/// does not open anything, it switches the bar into alias mode.
struct SearchAliasHintRow: View {
    let alias: SearchAlias
    let triggerKeys: Set<SearchAliasTriggerKey>
    let isSelected: Bool

    var body: some View {
        CommandBarActionRow(
            symbolName: "arrow.turn.down.right",
            title: "Search \(alias.displayName)",
            caption: triggerHint,
            captionSymbolName: "keyboard",
            isSelected: isSelected
        )
    }

    private var triggerHint: String {
        let names = SearchAliasTriggerKey.allCases
            .filter { triggerKeys.contains($0) }
            .map(\.label)
        guard !names.isEmpty else { return "Enable a trigger key in Settings" }
        return "Press \(names.joined(separator: " or ")) to search this site"
    }
}

/// The committed alias row: what Enter will actually open.
struct SearchAliasQueryRow: View {
    let alias: SearchAlias
    let query: String
    let isSelected: Bool

    var body: some View {
        CommandBarActionRow(
            symbolName: "magnifyingglass",
            title: title,
            caption: alias.origin.profileName.map { "\(alias.keyword) • \($0)" } ?? alias.keyword,
            captionSymbolName: "arrow.up.forward.app",
            isSelected: isSelected
        )
    }

    private var title: String {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return "Open \(alias.displayName)" }
        return "Search \(alias.displayName) for \u{201c}\(trimmedQuery)\u{201d}"
    }
}
