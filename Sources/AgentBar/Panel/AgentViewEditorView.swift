import SwiftUI
import IndieCommandBar

/// The saved-view editor in the panel body: the shared IndieCommandBar fields (no AI filter for
/// agents yet) plus Agent Bar's criteria, and the shared footer with a live match count.
struct AgentViewEditorView: View {
    @ObservedObject var pages: AgentPagesModel
    /// Projects to offer (from the current feed), plus any the draft already has.
    let projectOptions: [String]
    let bodyHeight: CGFloat

    var body: some View {
        if let state = pages.editor {
            SavedViewEditorShell(isNew: state.isNew, style: .bar) {
                SavedViewEditorFields(
                    name: binding(\.name),
                    iconName: binding(\.iconName),
                    keywords: binding(\.keywords),
                    semanticPrompt: .constant(""),
                    iconChoices: AgentViewDraft.iconChoices,
                    namePlaceholder: "AptusFit workers",
                    keywordsPlaceholder: "Words, *wild*card or /regex/ in name, project, folder or prompt",
                    promptPlaceholder: "",
                    isAIAvailable: false,
                    aiHint: "",
                    showsAIFilter: false
                ) {
                    SavedViewFormRow("Agents") { namesField(state.draft) }
                    SavedViewFormRow("Projects") { projectChips(state.draft) }
                    SavedViewFormRow("Status") { statusChips(state.draft) }
                } afterKeywords: {
                    SavedViewFormRow("Active within") { activeWithinPicker }
                } trailing: {
                    SavedViewFormRow("Group by") { groupByPicker }
                }
            } footer: {
                SavedViewEditorFooter(
                    viewName: state.draft.name,
                    isNew: state.isNew,
                    isValid: state.draft.isValid,
                    firstIssue: state.draft.issues.first?.message,
                    matchCountText: matchCountText(state.draft),
                    deleteReassurance: "Your agents stay as they are.",
                    isConfirmingDelete: Binding(
                        get: { pages.editor?.isConfirmingDelete ?? false },
                        set: { pages.editor?.isConfirmingDelete = $0 }
                    ),
                    onCancel: { pages.cancelEditor() },
                    onSave: { pages.saveEditor() },
                    onDelete: state.isNew ? nil : { pages.deleteView(id: state.draft.id) }
                )
            }
            .frame(height: bodyHeight)
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<AgentViewDraft, T>) -> Binding<T> {
        Binding(
            get: { pages.editor?.draft[keyPath: keyPath] ?? AgentViewDraft.new()[keyPath: keyPath] },
            set: { pages.editor?.draft[keyPath: keyPath] = $0 }
        )
    }

    private func matchCountText(_ draft: AgentViewDraft) -> String {
        let count = pages.matchCount?(draft.view)
        guard let count else { return "Counting…" }
        return count == 1 ? "1 agent matches" : "\(count) agents match"
    }

    private func namesField(_ draft: AgentViewDraft) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField("pog-*, /^chief/, ~/01_Project/parklet", text: binding(\.namesText))
                .textFieldStyle(.roundedBorder)
            if let broken = draft.issues.first(where: { if case .brokenPattern = $0 { true } else { false } }) {
                SavedViewIssueText(broken.message)
            } else {
                Text("Comma-separated. Matches the session name or its folder.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func projectChips(_ draft: AgentViewDraft) -> some View {
        let options = Array(Set(projectOptions).union(draft.projects))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return Group {
            if options.isEmpty {
                Text("No projects in the feed yet.").font(.caption2).foregroundStyle(.tertiary)
            } else {
                SavedViewFlowLayout(spacing: 6) {
                    ForEach(options, id: \.self) { project in
                        SavedViewChip(title: project, systemImage: nil, isOn: draft.projects.contains(project)) {
                            toggle(project, in: \.projects)
                        }
                    }
                }
            }
        }
    }

    private func statusChips(_ draft: AgentViewDraft) -> some View {
        SavedViewFlowLayout(spacing: 6) {
            ForEach(AgentSection.allCases, id: \.self) { section in
                SavedViewChip(title: section.title, systemImage: nil, isOn: draft.sections.contains(section)) {
                    toggle(section, in: \.sections)
                }
            }
        }
    }

    private func toggle<T: Hashable>(_ value: T, in keyPath: WritableKeyPath<AgentViewDraft, Set<T>>) {
        guard var set = pages.editor?.draft[keyPath: keyPath] else { return }
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
        pages.editor?.draft[keyPath: keyPath] = set
    }

    private var activeWithinPicker: some View {
        Picker("Active within", selection: binding(\.activeWithinMinutes)) {
            ForEach(AgentViewDraft.activeWithinChoices, id: \.title) { choice in
                Text(choice.title).tag(choice.minutes)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    private var groupByPicker: some View {
        Picker("Group by", selection: binding(\.groupBy)) {
            ForEach(AgentViewGroupBy.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }
}
