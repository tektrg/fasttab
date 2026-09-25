import Foundation
@testable import AgentBar

/// Scripted `PersonaDirectorySource` for panel-model tests: never touches the dashboard. `fetchPersonas`
/// answers at once from `personas`; `startPersona` answers at once from `startOutcome` unless
/// `gatesStart` is set, in which case it hangs until the test calls `resolvePendingStart(with:)` —
/// needed to observe the `.startingPersona` in-between state before it resolves.
final class FakePersonaDirectorySource: PersonaDirectorySource, @unchecked Sendable {
    struct StartCall: Equatable {
        let name: String
        let text: String
        let fresh: Bool
    }

    private let lock = NSLock()
    private var _personas: [Persona] = []
    private var _startOutcome: PersonaStartOutcome = .failed("not configured")
    private var _startCalls: [StartCall] = []
    private var pending: [CheckedContinuation<PersonaStartOutcome, Never>] = []
    var gatesStart = false

    var personas: [Persona] {
        get { lock.withLock { _personas } }
        set { lock.withLock { _personas = newValue } }
    }
    var startOutcome: PersonaStartOutcome {
        get { lock.withLock { _startOutcome } }
        set { lock.withLock { _startOutcome = newValue } }
    }
    var startCalls: [StartCall] { lock.withLock { _startCalls } }
    var pendingStartCount: Int { lock.withLock { pending.count } }

    func fetchPersonas() async -> [Persona]? { personas }

    func startPersona(_ name: String, text: String, fresh: Bool) async -> PersonaStartOutcome {
        lock.withLock { _startCalls.append(StartCall(name: name, text: text, fresh: fresh)) }
        guard gatesStart else { return startOutcome }
        return await withCheckedContinuation { continuation in
            lock.withLock { pending.append(continuation) }
        }
    }

    /// Resolves the oldest still-pending gated call (only meaningful with `gatesStart == true`).
    func resolvePendingStart(with outcome: PersonaStartOutcome) {
        let continuation = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        continuation?.resume(returning: outcome)
    }
}
