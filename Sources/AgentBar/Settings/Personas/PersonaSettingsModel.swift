import Foundation

/// State behind Settings > Personas. Every change is one dashboard call whose reply is the new
/// registry, so the screen always shows what the dashboard saved — never an optimistic guess.
@MainActor
final class PersonaSettingsModel: ObservableObject {
    struct Editor: Equatable {
        enum Mode: Equatable {
            case adopt(address: String)
            case edit(address: String)
        }

        let mode: Mode
        var draft: PersonaDraft
        var error: String?
        var isSaving = false

        var address: String {
            switch mode {
            case .adopt(let address), .edit(let address): address
            }
        }

        var title: String {
            switch mode {
            case .adopt: "Adopt as persona"
            case .edit: "Edit persona"
            }
        }
    }

    @Published private(set) var registry: PersonaRegistry?
    @Published private(set) var suggestions: [PersonaSuggestion] = []
    /// Why the registry couldn't load (unreachable / too old): the whole screen shows only this.
    @Published private(set) var loadError: String?
    @Published private(set) var suggestionsError: String?
    /// The last failed hide/unhide/remove/global save, shown above the lists until the next change.
    @Published var actionError: String?
    @Published private(set) var isLoading = false
    @Published var editor: Editor?
    @Published private(set) var isSavingGlobal = false

    private let makeClient: () -> PersonaRegistryClient

    init(makeClient: @escaping () -> PersonaRegistryClient) {
        self.makeClient = makeClient
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        let client = makeClient()
        async let registryResult = client.loadRegistry()
        async let suggestionsResult = client.loadSuggestions()
        switch await registryResult {
        case .success(let loaded):
            registry = loaded
            loadError = nil
        case .failure(let failure):
            registry = nil
            loadError = failure.message
        }
        switch await suggestionsResult {
        case .success(let loaded):
            suggestions = loaded
            suggestionsError = nil
        case .failure(let failure):
            suggestions = []
            suggestionsError = failure.message
        }
    }

    // MARK: - Editor

    func startAdopting(_ suggestion: PersonaSuggestion) {
        editor = Editor(mode: .adopt(address: suggestion.address), draft: PersonaDraft(adopting: suggestion))
    }

    func startEditing(_ persona: RegistryPersona) {
        editor = Editor(mode: .edit(address: persona.address), draft: PersonaDraft(editing: persona))
    }

    func cancelEditor() {
        editor = nil
    }

    func saveEditor() async {
        guard var current = editor, !current.isSaving else { return }
        guard current.draft.hasName else {
            current.error = "Give the persona a name."
            editor = current
            return
        }
        current.isSaving = true
        current.error = nil
        editor = current
        let action: PersonaRegistryAction = switch current.mode {
        case .adopt(let address): .adopt(address: address, draft: current.draft)
        case .edit(let address): .edit(address: address, draft: current.draft)
        }
        switch await makeClient().apply(action) {
        case .success(let saved):
            registry = saved
            editor = nil
            if case .adopt(let address) = current.mode {
                suggestions.removeAll { $0.address == address }
            }
        case .failure(let failure):
            // The sheet may have been cancelled meanwhile; only an open editor for the same
            // persona shows the error.
            if editor?.mode == current.mode {
                editor?.isSaving = false
                editor?.error = failure.message
            }
        }
    }

    // MARK: - List actions

    func hideSuggestion(_ suggestion: PersonaSuggestion) async {
        if await perform(.hide(address: suggestion.address)) {
            suggestions.removeAll { $0.address == suggestion.address }
        }
    }

    func setHidden(_ hidden: Bool, persona: RegistryPersona) async {
        await perform(hidden ? .hide(address: persona.address) : .unhide(address: persona.address))
    }

    func unhideSuggestion(address: String) async {
        if await perform(.unhide(address: address)) { await reload() }
    }

    func remove(_ persona: RegistryPersona) async {
        if await perform(.remove(address: persona.address)) { await reload() }
    }

    /// "" (or the default text itself) resets to the default block.
    @discardableResult
    func saveGlobalInstructions(_ text: String) async -> Bool {
        isSavingGlobal = true
        defer { isSavingGlobal = false }
        return await perform(.setGlobalInstructions(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @discardableResult
    private func perform(_ action: PersonaRegistryAction) async -> Bool {
        switch await makeClient().apply(action) {
        case .success(let saved):
            registry = saved
            actionError = nil
            return true
        case .failure(let failure):
            actionError = failure.message
            return false
        }
    }
}
