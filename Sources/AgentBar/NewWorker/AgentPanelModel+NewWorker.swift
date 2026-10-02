import Foundation

/// New worker mode's key handling (state: `NewWorkerMode`). Each hook returns false outside the
/// mode, so the panel's usual Return / arrows / Esc handling is untouched then.
extension AgentPanelModel {
    /// Step 1's rows: the personas matching the box.
    var newWorkerFolders: [Persona] { newWorker?.visibleFolders(filter: query) ?? [] }
    var newWorkerSelectedFolderName: String? { newWorker?.selectedFolder(filter: query)?.name }
    /// Step 2's target (persona + machine chips).
    var newWorkerPick: PersonaPick? { newWorker?.composingPick }

    /// `/new` + Return, the "+" button, the empty state's button. Drops a Tab-tag (the box becomes
    /// the folder filter) and loads the folders from the dashboard. No-op while a card is open or
    /// a Jev route / persona start is showing.
    func enterNewWorkerMode() {
        guard !isCardOpen, routingState == nil else { return }
        removeTag()
        closePeek()
        let mode = NewWorkerMode()
        newWorker = mode
        query = ""
        refocusSearchField()
        guard let personaSource else {
            newWorker?.folders = .failed
            return
        }
        Task { [weak self] in
            let personas = await personaSource.fetchPersonas()
            self?.finishLoadingNewWorkerFolders(personas, entryID: mode.entryID)
        }
    }

    /// A reply for a mode the user already left (or re-entered) is dropped.
    private func finishLoadingNewWorkerFolders(_ personas: [Persona]?, entryID: UUID) {
        guard newWorker?.entryID == entryID else { return }
        newWorker?.folders = personas.map { .loaded($0) } ?? .failed
    }

    /// Return with `/new` in the box (outside the mode). Not while Tab-tagged: there the box is a
    /// message to that agent, so `/new` gets the usual slash-command refusal and the tag stays.
    func enterNewWorkerIfCommand() -> Bool {
        guard newWorker == nil, taggedAgentID == nil, NewWorkerMode.isEntryCommand(query) else { return false }
        enterNewWorkerMode()
        return true
    }

    /// Return inside the mode: step 1 picks the selected folder, step 2 starts the worker. Always
    /// true inside the mode, so Return never falls through to the hidden agent list.
    func handleNewWorkerReturn() -> Bool {
        guard var mode = newWorker else { return false }
        if let pick = mode.composingPick {
            startNewWorker(pick)
        } else if mode.pickSelectedFolder(filter: query) {
            newWorker = mode   // composing first, so the cleared box doesn't reset the folder selection
            query = ""
        }
        return true
    }

    /// Hover / click on a step-1 row.
    func selectNewWorkerFolder(named name: String) {
        guard newWorker?.isComposing == false else { return }
        newWorker?.selectedFolderName = name
    }

    func pickNewWorkerFolder(named name: String) {
        selectNewWorkerFolder(named: name)
        _ = handleNewWorkerReturn()
        refocusSearchField()
    }

    /// Up/Down: moves the folder selection in step 1; swallowed in step 2.
    func moveNewWorkerSelection(by offset: Int) -> Bool {
        guard var mode = newWorker else { return false }
        if !mode.isComposing {
            mode.moveSelection(by: offset, filter: query)
            newWorker = mode
        }
        return true
    }

    /// Up/Down in step 2 with machine chips. False otherwise.
    func moveNewWorkerMachine(by offset: Int) -> Bool {
        guard var mode = newWorker, mode.moveMachine(by: offset) else { return false }
        newWorker = mode
        return true
    }

    /// The target chip's ✕ (same as Esc in step 2), then the keyboard back to the box.
    func backOutOfNewWorkerByClick() {
        _ = backOutOfNewWorker()
        refocusSearchField()
    }

    /// Esc: step 2 → step 1 (filter restored), step 1 → the normal list.
    func backOutOfNewWorker() -> Bool {
        guard var mode = newWorker else { return false }
        if let filter = mode.backToFolders() {
            query = filter   // still composing here, so the folder selection survives
            newWorker = mode
        } else {
            newWorker = nil
            query = ""
        }
        return true
    }

    /// The first task is required and can't be a slash command (not even `/compact`/`/clear`):
    /// refused with the usual headless notice, staying on step 2 with the text intact.
    private func startNewWorker(_ pick: PersonaPick) {
        let verdict = MessageDraftValidator.check(query, allowsQuickCommands: false)
        if let refusal = MessageDraftValidator.headlessRefusal(for: verdict) {
            showAnswerNotice(refusal)
            return
        }
        newWorker = nil
        startFreshPersonaSession(pick, typedText: query.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
