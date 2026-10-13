import IndieComments
import SwiftUI

/// A highlight's comment thread: the passage, every comment in order, a box to add one,
/// Resolve / Reopen, and Delete Highlight (its comments go with it). Opened by tapping a
/// highlight in the reader or from the Highlights feed.
struct HighlightThreadSheet: View {
    let highlight: ReaderHighlight
    let onDeleteHighlight: () -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var threads = ReaderCommentThreads.shared
    @State private var draft = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var confirmsDelete = false
    @FocusState private var isComposerFocused: Bool

    private var thread: CommentThread? { threads.thread(for: highlight) }

    var body: some View {
        NavigationStack {
            List {
                Group {
                    passageSection
                    if let thread { messagesSection(thread) }
                }
                .dsListRow()
            }
            .dsListStyle()
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle(thread?.state == .resolved ? "Comments · Resolved" : "Comments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarButtons }
            .confirmationDialog("Delete Highlight?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete Highlight and Comments", role: .destructive) {
                    onDeleteHighlight()
                    dismiss()
                }
            }
            .alert("Couldn't save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                threads.load([highlight])
                if thread == nil { isComposerFocused = true }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(DS.Palette.surface)
    }

    private var passageSection: some View {
        Section {
            HStack(alignment: .top, spacing: DS.Space.md) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(highlight.color.swiftUIColor)
                    .frame(width: 4)
                Text(highlight.selectedText)
                    .font(.callout)
                    .lineLimit(6)
            }
            .padding(.vertical, DS.Space.xs)
        }
    }

    private func messagesSection(_ thread: CommentThread) -> some View {
        Section {
            ForEach(thread.messages) { message in
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text(Self.authorName(message.by))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(message.text ?? "")
                        .textSelection(.enabled)
                }
                .padding(.vertical, DS.Space.xs)
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: DS.Space.sm) {
            TextField(thread == nil ? "Add a comment" : "Reply", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($isComposerFocused)
                .padding(.horizontal, DS.Space.md)
                .padding(.vertical, DS.Space.sm)
                .background(DS.Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 18))
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send comment")
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarButtons: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if let thread {
                    let isResolved = thread.state == .resolved
                    Button {
                        perform { try await threads.setResolved(!isResolved, on: highlight) }
                    } label: {
                        Label(isResolved ? "Reopen" : "Resolve", systemImage: isResolved ? "arrow.uturn.backward" : "checkmark")
                    }
                }
                Button(role: .destructive) { confirmsDelete = true } label: {
                    Label("Delete Highlight", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

    private func send() {
        let text = draft
        perform {
            try await threads.post(text, on: highlight)
            // Keep anything typed while it was sending.
            if draft == text { draft = "" }
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        isSending = true
        Task {
            defer { isSending = false }
            do { try await action() } catch { errorMessage = error.localizedDescription }
        }
    }

    static func authorName(_ author: CommentAuthor) -> String {
        if let label = author.label, !label.isEmpty { return label }
        switch author.kind {
        case .human: return "You"
        case .agent: return "Agent"
        case .external: return author.id
        }
    }
}
