import AppKit
import IndieMCP
import ReadingConnector
import SwiftUI

/// Settings › Highlights › "AI agent access": how to connect an agent (Claude Code) and the
/// `fasttab` terminal command, whether agents may see browser history (off by default) and how
/// far back, and the log of every agent call. The helper reads the same settings file on
/// every call, so a change applies at once.
struct AgentAccessSection: View {
    @State private var isExpanded = false
    @State private var settings = ReadingConnectorSettings()
    @State private var events: [AgentAccessEvent] = []

    private var supportDirectory: URL { SyncService.shared.fastTabSupportDirectory }
    private var helperPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/fasttab-mcp").path }
    private var mcpCommand: String { "claude mcp add fasttab -- \"\(helperPath)\"" }
    private var cliCommand: String { "ln -s \"\(helperPath)\" ~/.local/bin/fasttab" }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                commandRow("Connect Claude Code", mcpCommand)
                commandRow("Terminal command", cliCommand)
                Text("Read-only: agents see your FastTab List, reading progress, highlights, comments and bookmarks. "
                     + "Nothing leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Toggle("Let agents see browser history", isOn: $settings.historyEnabled)
                    Spacer()
                    Picker("Window", selection: $settings.historyWindowDays) {
                        ForEach(ReadingConnectorSettings.historyWindowChoices, id: \.self) { days in
                            Text(days == 1 ? "Last day" : "Last \(days) days").tag(days)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!settings.historyEnabled)
                }
                .font(.caption)
                recentCalls
            }
            .padding(.top, 6)
        } label: {
            Label("AI agent access", systemImage: "sparkles").font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .task { await load() }
        .onChange(of: settings) { _, new in try? new.save(supportDirectory: supportDirectory) }
    }

    private func commandRow(_ title: String, _ command: String) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).frame(width: 130, alignment: .leading)
            Text(command).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 4)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var recentCalls: some View {
        Text("Recent agent calls").font(.caption.weight(.semibold))
        if events.isEmpty {
            Text("None yet.").font(.caption).foregroundStyle(.secondary)
        } else {
            ForEach(events) { event in
                HStack(spacing: 6) {
                    Text(event.date, format: .dateTime.month().day().hour().minute()).monospacedDigit()
                    Text(AgentClientName.displayName(for: event.clientName))
                    Text(event.summary).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(event.resultCount) item\(event.resultCount == 1 ? "" : "s")").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }

    private func load() async {
        settings = ReadingConnectorSettings.load(supportDirectory: supportDirectory)
        await reloadEvents()
        for await _ in AgentAccessLogNotification.changes(named: ReadingConnectorSettings.accessLogNotification) {
            await reloadEvents()
        }
    }

    private func reloadEvents() async {
        let url = ReadingConnectorSettings.accessLogURL(supportDirectory: supportDirectory)
        guard FileManager.default.fileExists(atPath: url.path), let log = try? AgentAccessLog(fileURL: url) else { return }
        events = (try? await log.recentEvents(limit: 8)) ?? []
    }
}
