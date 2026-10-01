import SwiftUI

/// Adopt / edit one persona. Saving is one dashboard call; the sheet stays open with the
/// dashboard's own reason when it refuses.
struct PersonaEditorSheet: View {
    @ObservedObject var model: PersonaSettingsModel

    var body: some View {
        if let editor = model.editor {
            VStack(alignment: .leading, spacing: 0) {
                Form {
                    Section {
                        LabeledContent("Folder", value: editor.address)
                        TextField("Name", text: draft(\.name), prompt: Text("e.g. chief-aptus"))
                    }
                    Section {
                        PersonaTextEditor(text: draft(\.description), minHeight: 48)
                        if !editor.draft.hasDescription {
                            PersonaNotice(text: "Jev won't offer this persona until it has a description.")
                        } else if case .adopt = editor.mode {
                            Text("Drafted from the folder's AGENTS.md / CLAUDE.md — check it says what this persona owns.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Description (what Jev reads)")
                    }
                    Section {
                        PersonaTextEditor(text: draft(\.routesWhenText), minHeight: 36)
                    } header: {
                        Text("Routes here when… (one per line)")
                    }
                    Section {
                        PersonaTextEditor(text: draft(\.notForText), minHeight: 36)
                    } header: {
                        Text("Not for… (one per line)")
                    }
                    Section {
                        PersonaTextEditor(text: draft(\.extraInstructions), minHeight: 48)
                    } header: {
                        Text("Extra instructions")
                    } footer: {
                        Text("Given to this persona's session after the global instructions, when AgentBar starts or resumes it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("With nothing running") {
                        Picker("When picked", selection: draft(\.idle)) {
                            Text("Resume last conversation").tag(RegistryPersona.IdleMode.resume)
                            Text("Start fresh").tag(RegistryPersona.IdleMode.fresh)
                        }
                        Stepper(value: draft(\.resumeWithinDays), in: 0...365) {
                            Text("Resume only if active in the last \(editor.draft.resumeWithinDays) days")
                        }
                        .disabled(editor.draft.idle == .fresh)
                    }
                    if editor.draft.runsOn != nil, let machines = model.registry?.machines, machines.count > 1 {
                        Section {
                            Picker("Runs on", selection: draft(\.runsOn)) {
                                ForEach(machines, id: \.id) { Text($0.label).tag(Optional($0.id)) }
                            }
                            .pickerStyle(.segmented)
                        } footer: {
                            Text("Where AgentBar starts or resumes this persona. The confirm row can still pick another machine for one start.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .formStyle(.grouped)
                footer(editor)
            }
            .frame(width: 520, height: 560)
        }
    }

    private func footer(_ editor: PersonaSettingsModel.Editor) -> some View {
        HStack {
            if let error = editor.error { PersonaNotice(text: error) }
            Spacer()
            if editor.isSaving { ProgressView().controlSize(.small) }
            Button("Cancel", role: .cancel) { model.cancelEditor() }
                .keyboardShortcut(.cancelAction)
            Button(editor.mode == .adopt(address: editor.address) ? "Adopt" : "Save") {
                Task { await model.saveEditor() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(editor.isSaving || !editor.draft.hasName)
        }
        .padding(12)
    }

    private func draft<Value>(_ keyPath: WritableKeyPath<PersonaDraft, Value>) -> Binding<Value> {
        Binding(
            get: { model.editor?.draft[keyPath: keyPath] ?? PersonaDraft()[keyPath: keyPath] },
            set: { model.editor?.draft[keyPath: keyPath] = $0 }
        )
    }
}

/// The global instructions block, shared by every persona.
struct GlobalInstructionsSheet: View {
    @ObservedObject var model: PersonaSettingsModel
    let registry: PersonaRegistry
    @Binding var isPresented: Bool
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Global instructions").font(.headline)
            Text("`<name>` and `<description>` are filled in per persona. The list of persona names is appended so a misrouted reply can name a real one.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PersonaTextEditor(text: $text, minHeight: 260)
            if let error = model.actionError { PersonaNotice(text: error) }
            HStack {
                Button("Reset to default") { text = registry.defaultGlobalInstructions }
                    .disabled(text == registry.defaultGlobalInstructions)
                Spacer()
                if model.isSavingGlobal { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task { if await model.saveGlobalInstructions(text) { isPresented = false } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSavingGlobal || text == registry.globalInstructions)
            }
        }
        .padding(16)
        .frame(width: 560, height: 440)
        .onAppear { text = registry.globalInstructions }
    }
}

/// A bordered multi-line field sized for Settings forms.
struct PersonaTextEditor: View {
    @Binding var text: String
    let minHeight: CGFloat

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12))
            .frame(minHeight: minHeight)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
    }
}
