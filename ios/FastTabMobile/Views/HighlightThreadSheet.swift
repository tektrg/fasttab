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
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var confirmsDelete = false

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
            .safeAreaInset(edge: .bottom) {
                // Its own view holding the draft: a keystroke re-renders only the input bar,
                // not this sheet's list (and the reader behind it).
                HighlightCommentComposer(placeholder: thread == nil ? "Add a comment" : "Reply",
                                         isBusy: isSending, focusOnAppear: thread == nil) { text in
                    await post(text)
                }
            }
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
        Section(footer: thread.state == .resolved ? Text("Resolved. Replying reopens it.") : nil) {
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

    /// Returns whether the comment was saved (the composer clears its draft only then).
    private func post(_ text: String) async -> Bool {
        isSending = true
        defer { isSending = false }
        do {
            try await threads.post(text, on: highlight)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
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

/// The comment input bar. Owns the draft so typing invalidates only this small view.
struct HighlightCommentComposer: View {
    let placeholder: String
    let isBusy: Bool
    /// A highlight with no comments yet opens straight into typing.
    let focusOnAppear: Bool
    let onSend: @MainActor (String) async -> Bool

    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: DS.Space.sm) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($isFocused)
                .padding(.horizontal, DS.Space.md)
                .padding(.vertical, DS.Space.sm)
                .background(DS.Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 18))
            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(isBusy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send comment")
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.sm)
        .background(.bar)
        .onAppear { if focusOnAppear { isFocused = true } }
    }

    private func send() {
        let text = draft
        Task {
            // Keep anything typed while it was sending.
            if await onSend(text), draft == text { draft = "" }
        }
    }
}
