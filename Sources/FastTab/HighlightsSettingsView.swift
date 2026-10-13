import AppKit
import FastTabReader
import IndieComments
import SwiftUI

/// "Highlights" tab of Settings: the phone's reader highlights (synced) in the IndieTable
/// views All / Open threads / By page / By date, searchable across quotes and comments.
/// Clicking a row opens the article at the passage; its comment button expands the thread
/// to reply, resolve or reopen. Agents get the same views through fasttab-mcp.
struct HighlightsSettingsView: View {
    @State private var view: HighlightView = .all
    @State private var searchText = ""
    @State private var entries: [HighlightEntry] = []
    @State private var sections: [HighlightSection] = []
    @State private var expandedID: String?
    @State private var errorMessage: String?

    private var library: ReaderLibrary { SyncService.shared.readerLibrary }
    static let me = CommentAuthor(kind: .human, id: "me", label: "You")

    var body: some View {
        VStack(spacing: 0) {
            header
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.orange).padding(.bottom, 6)
            }
            content
            Divider()
            AgentHint()
        }
        .task { await reloadPeriodically() }
        .onReceive(NotificationCenter.default.publisher(for: .readerMirrorDidChange)) { _ in
            Task { await reload() }
        }
        .onChange(of: view) { _, _ in rerun() }
        .onChange(of: searchText) { _, _ in rerun() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("View", selection: $view) {
                ForEach(HighlightView.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search quotes and comments", text: $searchText).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty {
            emptyState("No highlights yet", systemImage: "highlighter",
                       message: "Highlights you make in Fast Tab on iPhone show up here.")
        } else if sections.allSatisfy(\.entries.isEmpty) {
            emptyState(view == .openThreads && searchText.isEmpty ? "No open threads" : "No matches",
                       systemImage: "text.bubble", message: "")
        } else {
            List {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    Section {
                        ForEach(section.entries) { entry in
                            HighlightSettingsRow(
                                entry: entry,
                                isExpanded: expandedID == entry.id,
                                toggle: { expandedID = expandedID == entry.id ? nil : entry.id },
                                reply: { text in perform { try await library.comment(text, onHighlight: entry.id, by: Self.me) } },
                                setResolved: { resolved in
                                    perform { try await library.setResolved(resolved, onHighlight: entry.id, by: Self.me) }
                                }
                            )
                        }
                    } header: {
                        if let title = section.title { Text(sectionTitle(title)) }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func emptyState(_ title: String, systemImage: String, message: String) -> some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: systemImage).font(.title2).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// By date sections are `yyyy-MM-dd`: shown as Today / Yesterday / a medium date.
    private func sectionTitle(_ title: String) -> String {
        guard view == .byDate, let date = Self.dayFormatter.date(from: title) else { return title }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: - Data

    /// The MCP helper writes from another process, so the page re-reads while it is open.
    private func reloadPeriodically() async {
        while !Task.isCancelled {
            await reload()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private func reload() async {
        entries = await library.entries()
        rerun()
    }

    private func rerun() {
        do {
            sections = try HighlightsTable.run(view, search: searchText, entries: entries)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't build this view: \(error.localizedDescription)"
        }
    }

    private func perform(_ action: @escaping () async throws -> HighlightEntry) {
        Task {
            do {
                _ = try await action()
                SyncService.shared.queueReaderChanges()
                await reload()
            } catch {
                errorMessage = String(describing: error)
            }
        }
    }
}

/// One highlight: colour, quote, page and date; its thread status on the right. Clicking
/// the row opens the article at the passage; the bubble expands the thread.
private struct HighlightSettingsRow: View {
    let entry: HighlightEntry
    let isExpanded: Bool
    let toggle: () -> Void
    let reply: (String) -> Void
    let setResolved: (Bool) -> Void

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(Self.color(entry.highlight.color)).frame(width: 8, height: 8).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.highlight.selectedText).lineLimit(isExpanded ? nil : 2)
                    Text("\(entry.highlight.pageTitle) · \(entry.highlight.site) · "
                         + entry.highlight.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if !isExpanded, let latest = entry.comments.last?.text {
                        Label(latest, systemImage: "text.bubble").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { open() }
                Spacer(minLength: 4)
                Button(action: toggle) { threadBadge }
                    .buttonStyle(.plain)
                    .help(entry.thread == nil ? "Comment" : "Show thread")
            }
            if isExpanded { thread }
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button("Open Article at Highlight") { open() }
            Button("Copy Quote") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.highlight.selectedText, forType: .string)
            }
        }
    }

    private var threadBadge: some View {
        let count = entry.comments.count
        return HStack(spacing: 3) {
            Image(systemName: entry.status == "resolved" ? "checkmark.bubble" : count > 0 ? "text.bubble.fill" : "plus.bubble")
            if count > 0 { Text("\(count)").monospacedDigit() }
        }
        .font(.caption)
        .foregroundStyle(entry.status == "open" ? Color.accentColor : .secondary)
    }

    private var thread: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entry.comments) { comment in
                VStack(alignment: .leading, spacing: 1) {
                    Text(comment.by.label ?? comment.by.id).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(comment.text ?? "").textSelection(.enabled)
                }
            }
            HStack {
                TextField(entry.thread == nil ? "Add a comment" : "Reply", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if entry.thread != nil {
                    Button(entry.status == "resolved" ? "Reopen" : "Resolve") { setResolved(entry.status != "resolved") }
                }
            }
        }
        .padding(.leading, 16)
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        draft = ""
        reply(text)
    }

    private func open() {
        guard let url = entry.highlight.urlAtHighlight else { return }
        NSWorkspace.shared.open(url)
    }

    private static func color(_ name: String) -> Color {
        switch name {
        case "green": .green
        case "blue": .blue
        case "pink": .pink
        default: .yellow
        }
    }
}

/// How to connect an agent: the command that registers fasttab-mcp with Claude Code.
private struct AgentHint: View {
    private var command: String {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/fasttab-mcp").path
        return "claude mcp add fasttab -- \"\(helper)\""
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            Text("Agents can work these views through fasttab-mcp.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Copy Claude Code command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
