import SwiftUI
import IndieCommandBar

/// Key hints never wrap (2026-11-15): when a hint bar is too narrow, the lowest-priority hints are
/// dropped first, display order kept. Pure: `candidates` lists every line from all hints down to
/// the single most important one; the views put them in a `ViewThatFits`, which shows the first
/// that fits on one line.
enum KeyHintFit {
    /// Higher = kept longer. Esc and Return (the way out, the main action) go last; ⌘K and the
    /// mouse-like extras (space peek, ⌘↩ with its long label) go first.
    static func priority(ofGlyph glyph: String) -> Int {
        switch glyph {
        case "esc", "space/esc": 100
        case "↩": 90
        case "←→/tab", "⌘← ⌘→": 80
        case "↑↓", "↑ ↓": 70
        case "1–9", "1-9": 60
        case "⌘K": 40
        case "space": 30
        case "⌘↩": 35
        default: 55
        }
    }

    /// Lines from fullest to shortest; each drops the lowest-priority remaining hint (on a tie the
    /// rightmost). Never empty for a non-empty input; the last line is the single top hint.
    static func candidates<T>(_ items: [T], priority: (T) -> Int) -> [[T]] {
        guard !items.isEmpty else { return [[]] }
        var kept = Array(items.indices)
        var lines = [kept.map { items[$0] }]
        while kept.count > 1 {
            let drop = kept.enumerated().min { a, b in
                let pa = priority(items[a.element]), pb = priority(items[b.element])
                return pa != pb ? pa < pb : a.offset > b.offset
            }!.offset
            kept.remove(at: drop)
            lines.append(kept.map { items[$0] })
        }
        return lines
    }

    static func candidates(_ tokens: [GuidanceToken]) -> [[GuidanceToken]] {
        candidates(tokens) { priority(ofGlyph: $0.glyph) }
    }
}

/// One line of keycap hints that drops low-priority hints instead of wrapping.
struct FittingKeyHints<Item, Content: View>: View {
    let items: [Item]
    let priority: (Item) -> Int
    var spacing: CGFloat = 8
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        let lines = KeyHintFit.candidates(items, priority: priority)
        ViewThatFits(in: .horizontal) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: spacing) {
                    ForEach(Array(line.enumerated()), id: \.offset) { _, item in content(item) }
                }
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}
