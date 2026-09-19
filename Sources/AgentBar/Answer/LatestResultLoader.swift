import Foundation

/// Runs one slow, on-demand read at a time. A result only counts if nothing was
/// loaded or cancelled since it started: each `load`/`cancel` bumps a
/// generation, and answers from an older one are dropped (the row or question
/// they were for may no longer be showing).
@MainActor
final class LatestResultLoader<Result: Sendable> {
    private var generation = 0
    private var task: Task<Void, Never>?

    func load(
        _ work: @escaping @Sendable () async -> Result,
        deliver: @escaping @MainActor (Result) -> Void
    ) {
        cancel()
        let startedGeneration = generation
        task = Task { [weak self] in
            let result = await work()
            guard !Task.isCancelled, self?.generation == startedGeneration else { return }
            deliver(result)
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }
}
