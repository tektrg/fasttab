import Foundation
@testable import AgentBar

/// An `AgentTreeEditing` scripted per test: every attach/detach call is recorded, and replies with
/// whatever the test queued (defaulting to success so a test that doesn't care can ignore it).
final class AgentTreeFakeEditing: AgentTreeEditing, @unchecked Sendable {
    struct AttachCall: Equatable { let child: String; let parent: String; let confirmCrossProject: Bool }

    private let lock = NSLock()
    private var attachCallsStorage: [AttachCall] = []
    private var detachCallsStorage: [String] = []
    private var attachReplyStorage: AttachOutcome = .attached(warning: nil)
    private var detachReplyStorage: DetachOutcome = .detached
    private var holdAttachStorage = false
    private var holdDetachStorage = false
    private var pendingAttachContinuation: CheckedContinuation<Void, Never>?
    private var pendingDetachContinuation: CheckedContinuation<Void, Never>?

    var attachCalls: [AttachCall] { lock.withLock { attachCallsStorage } }
    var detachCalls: [String] { lock.withLock { detachCallsStorage } }

    var attachReply: AttachOutcome {
        get { lock.withLock { attachReplyStorage } }
        set { lock.withLock { attachReplyStorage = newValue } }
    }

    var detachReply: DetachOutcome {
        get { lock.withLock { detachReplyStorage } }
        set { lock.withLock { detachReplyStorage = newValue } }
    }

    /// Set before the call, then release with `releaseAttach()`/`releaseDetach()`: parks the call
    /// mid-flight (after it's recorded, before it replies) so a test can act — e.g. deliver a fresh
    /// snapshot — while the "network round trip" is still outstanding.
    var holdAttach: Bool {
        get { lock.withLock { holdAttachStorage } }
        set { lock.withLock { holdAttachStorage = newValue } }
    }

    var holdDetach: Bool {
        get { lock.withLock { holdDetachStorage } }
        set { lock.withLock { holdDetachStorage = newValue } }
    }

    func attachToTree(child: String, parent: String, confirmCrossProject: Bool) async -> AttachOutcome {
        let shouldHold = lock.withLock { () -> Bool in
            attachCallsStorage.append(AttachCall(child: child, parent: parent, confirmCrossProject: confirmCrossProject))
            return holdAttachStorage
        }
        if shouldHold {
            await withCheckedContinuation { continuation in
                lock.withLock { pendingAttachContinuation = continuation }
            }
        }
        return attachReply
    }

    func detachFromTree(child: String) async -> DetachOutcome {
        let shouldHold = lock.withLock { () -> Bool in
            detachCallsStorage.append(child)
            return holdDetachStorage
        }
        if shouldHold {
            await withCheckedContinuation { continuation in
                lock.withLock { pendingDetachContinuation = continuation }
            }
        }
        return detachReply
    }

    func releaseAttach() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { pendingAttachContinuation = nil }
            return pendingAttachContinuation
        }
        continuation?.resume()
    }

    func releaseDetach() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { pendingDetachContinuation = nil }
            return pendingDetachContinuation
        }
        continuation?.resume()
    }
}
