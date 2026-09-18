import SwiftUI

/// "List" tab: what the panel lists and how tall it may grow. Applies live.
struct ListSettingsView: View {
    @ObservedObject var settings: AgentBarSettings

    var body: some View {
        Form {
            Section("Ended agents") {
                Picker("Keep listed for", selection: binding(\.endedWindowHours)) {
                    ForEach(AgentListSettings.endedWindowHoursChoices, id: \.self) { hours in
                        Text(Self.windowLabel(hours: hours)).tag(hours)
                    }
                }
                Picker("Show at most", selection: binding(\.maxEndedRows)) {
                    ForEach(AgentListSettings.maxEndedRowsChoices, id: \.self) { count in
                        Text(count == 0 ? "None (hide the section)" : "\(count) rows").tag(count)
                    }
                }
                Text("Ended agents are sessions that recently finished. The dashboard itself remembers them for 72 hours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Panes") {
                Toggle("Show non-Claude panes", isOn: binding(\.showsNonClaudePanes))
                Text("Plain shells and other tools such as OpenCode. Their status is a best guess, so they appear dimmed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Panel size") {
                Stepper(value: binding(\.maxVisibleRows), in: AgentListSettings.maxVisibleRowsRange) {
                    HStack {
                        Text("Rows before scrolling")
                        Spacer()
                        Text("\(settings.list.maxVisibleRows)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AgentListSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings.list[keyPath: keyPath] },
            set: { newValue in settings.updateList { $0[keyPath: keyPath] = newValue } }
        )
    }

    private static func windowLabel(hours: Int) -> String {
        hours % 24 == 0 ? "\(hours / 24) \(hours == 24 ? "day" : "days")" : "\(hours) \(hours == 1 ? "hour" : "hours")"
    }
}
