import SwiftUI
import IndieTags

/// Add or remove a highlight's tags. Type a name (`work/ssv` nests), pick a suggestion from
/// the tags already in use, or tap a tag to remove it. Saves on Done.
struct HighlightTagEditorSheet: View {
    let entry: HighlightFeedEntry
    let knownTags: [TagPath]
    let onSave: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var editedTags: [TagPath]
    @State private var draftTagText = ""
    @FocusState private var isFieldFocused: Bool

    init(entry: HighlightFeedEntry, knownTags: [TagPath], onSave: @escaping ([String]) -> Void) {
        self.entry = entry
        self.knownTags = knownTags
        self.onSave = onSave
        _editedTags = State(initialValue: entry.userTags)
    }

    private var suggestions: [TagPath] {
        HighlightFeedModel.tagSuggestions(query: draftTagText, knownTags: knownTags, excluding: editedTags)
    }

    /// The typed text as a new tag, when it is valid and not already on the highlight.
    private var typedTag: TagPath? {
        guard let tag = TagPath(draftTagText),
              !editedTags.contains(where: { $0.normalizedPath == tag.normalizedPath }) else { return nil }
        return tag
    }

    var body: some View {
        NavigationStack {
            List {
                Group {
                    currentTagsSection
                    addTagSection
                    if !entry.folderTags.isEmpty { folderTagsSection }
                }
                .dsListRow()
            }
            .dsListStyle()
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarButtons }
            .onAppear { isFieldFocused = true }
        }
        .presentationDetents([.medium, .large])
        // Solid, not the default glass: on a material the selected chips' `Color.primary`
        // fill turns vibrant grey and no longer reads as a chip.
        .presentationBackground(DS.Palette.surface)
    }

    private var currentTagsSection: some View {
        Section {
            if editedTags.isEmpty {
                Text("No tags yet").foregroundStyle(.secondary)
            } else {
                WrappingRowsLayout(spacing: DS.Space.sm, lineSpacing: DS.Space.sm) {
                    ForEach(editedTags, id: \.normalizedPath) { tag in
                        DSChip(tag.displayPath, systemImage: "xmark", isSelected: true) {
                            editedTags.removeAll { $0.normalizedPath == tag.normalizedPath }
                        }
                        .accessibilityLabel("Remove tag \(tag.displayPath)")
                    }
                }
                .padding(.vertical, DS.Space.xs)
            }
        } header: {
            Text(entry.highlight.selectedText).lineLimit(2).textCase(nil)
        }
    }

    private var addTagSection: some View {
        Section {
            TextField("Add a tag, e.g. work/ssv", text: $draftTagText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($isFieldFocused)
                .onSubmit { if let typedTag { add(typedTag) } }
            if let typedTag, !suggestions.contains(where: { $0.normalizedPath == typedTag.normalizedPath }) {
                suggestionButton(typedTag, systemImage: "plus.circle", label: "Add \u{201C}\(typedTag.displayPath)\u{201D}")
            }
            ForEach(suggestions, id: \.normalizedPath) { tag in
                suggestionButton(tag, systemImage: "tag", label: tag.displayPath)
            }
        }
    }

    private var folderTagsSection: some View {
        Section("From bookmark folder") {
            ForEach(entry.folderTags, id: \.normalizedPath) { tag in
                Label(tag.displayPath, systemImage: "folder").foregroundStyle(.secondary)
            }
        }
    }

    private func suggestionButton(_ tag: TagPath, systemImage: String, label: String) -> some View {
        Button { add(tag) } label: { Label(label, systemImage: systemImage) }
    }

    @ToolbarContentBuilder
    private var toolbarButtons: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
                // A tag typed but not yet added counts: Done means "keep what I wrote".
                if let typedTag { editedTags.append(typedTag) }
                onSave(editedTags.map(\.displayPath))
                dismiss()
            }
        }
    }

    private func add(_ tag: TagPath) {
        guard !editedTags.contains(where: { $0.normalizedPath == tag.normalizedPath }) else { return }
        editedTags.append(tag)
        draftTagText = ""
    }
}
