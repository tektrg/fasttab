import Foundation
@testable import AgentBar

/// Scripted `DashboardWorkerCreating` for panel-model tests: never touches the network. Answers
/// stay pending until the test replies, mirroring `MessageFakeSource`'s shape for message sends.
final class FakeDashboardWorkerCreator: DashboardWorkerCreating, @unchecked Sendable {
    struct Call: Equatable {
        let repoAlias: String
        let slug: String
        let task: String
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var pending: [CheckedContinuation<WorkerCreationOutcome, Never>] = []

    var calls: [Call] { lock.withLock { _calls } }
    var pendingCount: Int { lock.withLock { pending.count } }

    func createWorker(repoAlias: String, slug: String, task: String) async -> WorkerCreationOutcome {
        await withCheckedContinuation { continuation in
            lock.withLock {
                _calls.append(Call(repoAlias: repoAlias, slug: slug, task: task))
                pending.append(continuation)
            }
        }
    }

    /// Resolves the oldest still-pending call.
    func reply(_ outcome: WorkerCreationOutcome) {
        let continuation = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        continuation?.resume(returning: outcome)
    }

    func waitForRequests(_ count: Int) async {
        await waitUntil { self.pendingCount >= count }
    }
}
