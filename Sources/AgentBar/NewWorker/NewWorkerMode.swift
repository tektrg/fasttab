import Foundation

/// **New worker mode** (`/new` + Return, the search row's "+", or the empty state's button): start a
/// FRESH session in a persona's folder without asking Jev. Two steps, both typed into the one search
/// box (`AgentPanelModel.query`):
/// 1. `.pickingFolder` — the list shows the personas (folders); the box filters them by name.
/// 2. `.composing` — the box is the first task; machine chips when the persona has 2+ machines.
/// Return in step 2 hands the pick to the same `POST /api/persona/start` path a Jev persona pick
/// takes (`AgentPanelModel.startFreshPersonaSession`). Pure state: `AgentPanelModel+NewWorker` drives it.
struct NewWorkerMode: Equatable {
    static let command = "/new"

    enum Folders: Equatable {
        case loading
        case loaded([Persona])
        /// No dashboard, or `GET /api/personas` failed.
        case failed
    }

    enum Step: Equatable {
        case pickingFolder
        /// `forcedStartNew` is always set: this mode never resumes or sends to a live main session.
        case composing(PersonaPick)
    }

    /// Tells a late `fetchPersonas` reply apart from a newer entry into the mode.
    let entryID = UUID()
    var folders: Folders = .loading
    private(set) var step: Step = .pickingFolder
    /// Step 1's highlighted folder; nil = the first visible one (the model clears it whenever the
    /// filter text changes, so typing always lands on the best match).
    var selectedFolderName: String?
    /// Step 1's filter, kept while composing so Esc back to step 1 restores it.
    private(set) var folderFilter = ""

    /// `/new` (any case, surrounding spaces ignored) typed in the search box.
    static func isEntryCommand(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == command
    }

    var isComposing: Bool { composingPick != nil }

    var composingPick: PersonaPick? {
        if case .composing(let pick) = step { pick } else { nil }
    }

    /// Online personas whose name contains `filter` (case-insensitive), in dashboard order.
    func visibleFolders(filter: String) -> [Persona] {
        guard case .loaded(let personas) = folders else { return [] }
        let online = personas.filter { !$0.offline }
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return online }
        return online.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    func selectedFolder(filter: String) -> Persona? {
        let visible = visibleFolders(filter: filter)
        return visible.first { $0.name == selectedFolderName } ?? visible.first
    }

    /// Up/Down in step 1, clamped at both ends.
    mutating func moveSelection(by offset: Int, filter: String) {
        let names = visibleFolders(filter: filter).map(\.name)
        guard !names.isEmpty else { return }
        let current = selectedFolder(filter: filter).flatMap { names.firstIndex(of: $0.name) } ?? 0
        selectedFolderName = names[min(max(current + offset, 0), names.count - 1)]
    }

    /// Return in step 1: the selected folder becomes the start target. False with nothing to pick.
    mutating func pickSelectedFolder(filter: String) -> Bool {
        guard case .pickingFolder = step, let persona = selectedFolder(filter: filter) else { return false }
        var pick = PersonaPick(persona: persona, confidence: 1, mainSession: .absent)
        pick.forcedStartNew = true
        pick.locksStartNew = true
        folderFilter = filter
        selectedFolderName = persona.name
        step = .composing(pick)
        return true
    }

    /// Esc in step 2: back to the folder list. Returns the filter to put back in the box; nil when
    /// already on step 1 (Esc then leaves the mode).
    mutating func backToFolders() -> String? {
        guard isComposing else { return nil }
        step = .pickingFolder
        return folderFilter
    }

    /// Left/Right in step 2 (`PersonaPick.moveMachine`). False when no chips show.
    mutating func moveMachine(by offset: Int) -> Bool {
        guard var pick = composingPick, pick.moveMachine(by: offset) else { return false }
        step = .composing(pick)
        return true
    }
}
