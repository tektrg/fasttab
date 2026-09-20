import AppKit

/// Puts an agent's identifying text on the system pasteboard and remembers, for a moment,
/// which agent was copied so its row or card can say "Copied" (the view fades it).
@MainActor
final class IdentityCopier: ObservableObject {
    static let feedbackSeconds: TimeInterval = 1.2

    @Published private(set) var copiedAgentID: String?

    private let writeToPasteboard: (String) -> Void
    private let feedbackSeconds: TimeInterval
    private var resetTask: Task<Void, Never>?

    init(
        feedbackSeconds: TimeInterval = IdentityCopier.feedbackSeconds,
        writeToPasteboard: @escaping (String) -> Void = IdentityCopier.writeToSystemPasteboard
    ) {
        self.feedbackSeconds = feedbackSeconds
        self.writeToPasteboard = writeToPasteboard
    }

    func copy(_ text: String, for agentID: String) {
        guard !text.isEmpty else { return }
        writeToPasteboard(text)
        copiedAgentID = agentID
        resetTask?.cancel()
        resetTask = Task { [weak self, feedbackSeconds] in
            try? await Task.sleep(for: .seconds(feedbackSeconds))
            guard !Task.isCancelled else { return }
            self?.copiedAgentID = nil
        }
    }

    /// Forgets the feedback (the panel was closed and opened again).
    func clearFeedback() {
        resetTask?.cancel()
        copiedAgentID = nil
    }

    nonisolated static func writeToSystemPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
