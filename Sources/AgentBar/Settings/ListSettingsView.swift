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
                Toggle("Show Claude Desktop and CLI sessions", isOn: binding(\.showsClaudeOutsideHerdr))
                Text("Claude sessions outside herdr (the Claude app, or the CLI in tmux). Status only: no Answer, Message or Done. Enter opens a Claude Desktop session in the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Sleeping Claude Desktop sessions") {
                Picker("Show in list", selection: binding(\.sleepingListDays)) {
                    ForEach(AgentListSettings.sleepingListDaysChoices, id: \.self) { days in
                        Text(days == 0 ? "Never (search only)" : Self.daysLabel(days)).tag(days)
                    }
                }
                .disabled(!settings.list.showsClaudeOutsideHerdr)
                Picker("Include in search", selection: binding(\.sleepingSearchDays)) {
                    ForEach(AgentListSettings.sleepingSearchDaysChoices, id: \.self) { days in
                        Text(Self.daysLabel(days)).tag(days)
                    }
                }
                .disabled(!settings.list.showsClaudeOutsideHerdr)
                Text("Desktop sessions Claude has put to sleep (no running process), by last activity. Listed greyed at the bottom; Enter opens one in Claude Desktop. Needs \"Show Claude Desktop and CLI sessions\" on.")
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

    private static func daysLabel(_ days: Int) -> String {
        "Last \(days) \(days == 1 ? "day" : "days")"
    }

    private static func windowLabel(hours: Int) -> String {
        hours % 24 == 0 ? "\(hours / 24) \(hours == 24 ? "day" : "days")" : "\(hours) \(hours == 1 ? "hour" : "hours")"
    }
}
