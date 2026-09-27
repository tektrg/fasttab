import SwiftUI

/// "Personas" tab: the named, folder-based agents Jev routes messages to. Everything here is read
/// from and saved through the dashboard (it owns `~/.config/agentbar/personas.json`); nothing is
/// ever written into a project folder.
struct PersonasSettingsView: View {
    @StateObject private var model: PersonaSettingsModel
    @State private var isEditingGlobal = false
    @State private var pendingRemoval: RegistryPersona?

    init(settings: AgentBarSettings) {
        _model = StateObject(wrappedValue: PersonaSettingsModel { [settings] in
            PersonaRegistryClient(baseURL: settings.dashboardBaseURL)
        })
    }

    var body: some View {
        Form {
            if let loadError = model.loadError {
                Section {
                    PersonaNotice(text: loadError)
                    Button("Try again") { Task { await model.reload() } }
                }
            } else if let registry = model.registry {
                if let actionError = model.actionError {
                    Section { PersonaNotice(text: actionError) }
                }
                personasSection(registry)
                suggestionsSection(registry)
                globalSection(registry)
            } else {
                Section { ProgressView().controlSize(.small) }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            Button { Task { await model.reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(model.isLoading)
        }
        .task { await model.reload() }
        .sheet(isPresented: Binding(get: { model.editor != nil }, set: { if !$0 { model.cancelEditor() } })) {
            PersonaEditorSheet(model: model)
        }
        .sheet(isPresented: $isEditingGlobal) {
            if let registry = model.registry {
                GlobalInstructionsSheet(model: model, registry: registry, isPresented: $isEditingGlobal)
            }
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "")?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { persona in
            Button("Remove", role: .destructive) { Task { await model.remove(persona) } }
        } message: { _ in
            Text("Jev stops routing to it. The folder and its files are not touched; it can be adopted again from Suggestions.")
        }
    }

    // MARK: - Sections

    private func personasSection(_ registry: PersonaRegistry) -> some View {
        Section {
            if registry.personas.isEmpty {
                Text("No personas yet. Adopt one from Suggestions below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(registry.personas) { persona in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(persona.name).fontWeight(.semibold)
                            PersonaStatusTag(persona: persona)
                        }
                        Text(persona.address).font(.caption).foregroundStyle(.secondary)
                        if !persona.description.isEmpty {
                            Text(persona.description).font(.caption).lineLimit(2)
                        }
                    }
                    Spacer()
                    Button("Edit") { model.startEditing(persona) }
                    Menu {
                        Button(persona.hidden ? "Unhide" : "Hide") {
                            Task { await model.setHidden(!persona.hidden, persona: persona) }
                        }
                        Button("Remove…", role: .destructive) { pendingRemoval = persona }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                }
            }
        } header: {
            Text("Personas")
        } footer: {
            Text("Jev only offers a persona that has a description and isn't hidden. Its role still comes from the folder's own AGENTS.md / CLAUDE.md.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func suggestionsSection(_ registry: PersonaRegistry) -> some View {
        Section("Suggestions") {
            if let suggestionsError = model.suggestionsError {
                PersonaNotice(text: suggestionsError)
            } else if model.suggestions.isEmpty {
                Text("No other folders with Claude sessions in the last 30 days.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.suggestions) { suggestion in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.address)
                        Text(Self.activitySummary(suggestion)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Adopt") { model.startAdopting(suggestion) }
                    Button("Hide") { Task { await model.hideSuggestion(suggestion) } }
                }
            }
            if !registry.hiddenSuggestions.isEmpty {
                DisclosureGroup("Hidden folders (\(registry.hiddenSuggestions.count))") {
                    ForEach(registry.hiddenSuggestions, id: \.self) { address in
                        HStack {
                            Text(address).font(.caption)
                            Spacer()
                            Button("Unhide") { Task { await model.unhideSuggestion(address: address) } }
                        }
                    }
                }
            }
        }
    }

    private func globalSection(_ registry: PersonaRegistry) -> some View {
        Section("Global instructions") {
            HStack {
                Text(registry.usesDefaultGlobalInstructions ? "Default" : "Customized")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Edit…") { isEditingGlobal = true }
            }
            Text("Added to every persona's session when AgentBar starts or resumes it, before the persona's own extra instructions.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func activitySummary(_ suggestion: PersonaSuggestion, now: Date = Date()) -> String {
        let sessions = suggestion.sessionCount == 1 ? "1 session" : "\(suggestion.sessionCount) sessions"
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let when = formatter.localizedString(for: Date(timeIntervalSince1970: suggestion.lastActive), relativeTo: now)
        return "\(sessions) · last active \(when)"
    }
}

/// "Offered" / "Needs a description" / "Hidden" next to a persona's name.
private struct PersonaStatusTag: View {
    let persona: RegistryPersona

    var body: some View {
        let (text, color): (String, Color) =
            if persona.hidden { ("Hidden", .secondary) }
            else if persona.offered { ("Offered to Jev", .green) }
            else if persona.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ("Needs a description", WarningTextColor.color)
            } else { ("Not offered", .secondary) }
        Text(text).font(.caption2).foregroundStyle(color)
    }
}

/// An orange warning line, used for every dashboard failure on this tab.
struct PersonaNotice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(WarningTextColor.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
