import Foundation

actor SyncSendCoordinator {
    typealias SendOperation = @Sendable () async -> Void

    private let operation: SendOperation
    private var isSending = false
    private var followUpRequested = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(operation: @escaping SendOperation) {
        self.operation = operation
    }

    func requestSend() {
        if isSending {
            followUpRequested = true
            return
        }

        isSending = true
        Task.detached { [weak self] in
            await self?.drainSendRequests()
        }
    }

    func waitUntilIdle() async {
        guard isSending else { return }

        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func drainSendRequests() async {
        while true {
            followUpRequested = false
            await operation()

            guard !followUpRequested else { continue }

            isSending = false
            let waiters = idleWaiters
            idleWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            return
        }
    }
}
