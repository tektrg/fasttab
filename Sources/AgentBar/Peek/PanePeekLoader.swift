import Foundation

/// Runs the one on-demand screen read behind a peek. The read is slow (~2.5s),
/// so a result only counts if nothing was opened, closed or cancelled since it
/// started: each `load`/`cancel` bumps a generation and stale answers are dropped.
@MainActor
final class PanePeekLoader {
    private var generation = 0
    private var task: Task<Void, Never>?

    func load(
        paneId: String,
        from source: any AgentStatusSource,
        deliver: @escaping @MainActor (PaneScreenResult) -> Void
    ) {
        cancel()
        let startedGeneration = generation
        task = Task { [weak self] in
            let result = await source.paneScreen(paneId: paneId)
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
