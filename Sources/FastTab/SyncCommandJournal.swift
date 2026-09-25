import Foundation
import FastTabSync

enum SyncCommandDuplicateDecision: Equatable {
    case execute
    case reconcileExecuting(SyncCommand)
    case resendCompleted(SyncCommand)
}

final class SyncCommandJournal {
    private struct PersistedState: Codable {
        var executing: [String: SyncCommand] = [:]
        var completed: [String: SyncCommand] = [:]
    }

    private let fileURL: URL
    private var state: PersistedState

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            self.state = decoded
        } else {
            self.state = PersistedState()
        }
    }

    var completedResponses: [SyncCommand] {
        state.completed.values.sorted { $0.id < $1.id }
    }

    func decision(for command: SyncCommand) -> SyncCommandDuplicateDecision {
        if let response = state.completed[command.id] {
            return .resendCompleted(response)
        }
        if let executing = state.executing[command.id] {
            return .reconcileExecuting(executing)
        }
        return .execute
    }

    func markExecuting(_ command: SyncCommand) throws {
        var nextState = state
        nextState.executing[command.id] = command
        try persist(nextState)
        state = nextState
    }

    func storeCompletedResponse(_ response: SyncCommand) throws {
        var nextState = state
        nextState.executing.removeValue(forKey: response.id)
        nextState.completed[response.id] = response
        try persist(nextState)
        state = nextState
    }

    func acknowledgeCompletedResponse(commandID: String) throws {
        var nextState = state
        nextState.completed.removeValue(forKey: commandID)
        try persist(nextState)
        state = nextState
    }

    private func persist(_ state: PersistedState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}
