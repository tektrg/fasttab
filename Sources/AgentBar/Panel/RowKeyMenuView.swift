import SwiftUI

/// The ⌘K keyboard menu (`RowKeyMenu`): the selected row's ⋯ items, numbered, the highlighted one
/// tinted. Floats over the bottom-right of the list, above the search box. Labels never wrap.
struct RowKeyMenuView: View {
    let menu: RowKeyMenu
    let agentLabel: String
    let onChoose: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Actions · \(agentLabel)")
                .font(.avenir(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
            ForEach(Array(menu.items.enumerated()), id: \.offset) { index, spec in
                row(index: index, spec: spec)
            }
            Text("↑↓ move · ↩ choose · 1–9 pick · esc close")
                .font(.avenir(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 4)
        }
        .padding(4)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 10).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private func row(index: Int, spec: RowButtonSpec) -> some View {
        let isOn = index == menu.highlighted
        return Button { onChoose(index) } label: {
            HStack(spacing: 10) {
                Text(RowKeyMenu.number(at: index) ?? " ")
                    .font(.avenirMono(size: 11, weight: .semibold))
                    .foregroundStyle(isOn ? Color.white.opacity(0.9) : .secondary)
                    .frame(width: 12)
                Text(spec.label)
                    .font(.avenir(size: 13, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 16)
            }
            .foregroundStyle(isOn ? Color.white : (spec.isEnabled ? Color.primary : Color.secondary))
            .padding(.horizontal, 10)
            .frame(minWidth: 200, minHeight: 26, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!spec.isEnabled)
        .help(spec.disabledReason ?? spec.hint ?? "")
    }
}
