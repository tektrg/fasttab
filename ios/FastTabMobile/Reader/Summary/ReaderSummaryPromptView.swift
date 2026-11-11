import SwiftUI

/// More ▸ AI ▸ Summary prompt: edit the instruction the Summary follows. The server keeps fixed
/// safety rules around it, so this only changes style and structure.
struct ReaderSummaryPromptView: View {
    @State private var store = ReaderSummaryPromptStore.shared
    @State private var draft = ReaderSummaryPromptDraft(stored: ReaderSummaryPromptStore.shared.customInstruction)
    @State private var confirmsReset = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextEditor(text: $draft.text)
                    .frame(minHeight: 320)
                    .font(.callout)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Summary prompt")
            } header: {
                Text(draft.isUsingDefault ? "Using the default prompt" : "Using your prompt")
            } footer: {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("\(draft.length) / \(ReaderSummaryPrompt.maxInstructionLength)")
                        .foregroundStyle(draft.isOverLimit ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    Text("Write {language} where the summary's language should go. Fixed safety rules stay in place whatever you write. Summaries already saved are not changed; Regenerate in the Summary sheet to use a new prompt.")
                }
            }
            Section {
                Button("Reset to Default", role: .destructive) { confirmsReset = true }
                    .disabled(draft.isUsingDefault && store.customInstruction == nil)
            }
        }
        .navigationTitle("Summary Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    store.save(instruction: draft.text)
                    dismiss()
                }
                .disabled(!draft.canSave(stored: store.customInstruction))
            }
        }
        .confirmationDialog("Go back to the default prompt?", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("Reset to Default", role: .destructive) {
                store.reset()
                draft.resetToDefault()
            }
        }
        .onChange(of: store.customInstruction) { old, new in
            // Another device changed it (iCloud) while this screen is open: follow it unless the
            // person has unsaved edits here.
            if !draft.canSave(stored: old) { draft = ReaderSummaryPromptDraft(stored: new) }
        }
    }
}
