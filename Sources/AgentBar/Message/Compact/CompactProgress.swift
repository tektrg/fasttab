import Foundation

/// What the message card knows about a `/compact` job for its row. Pure state machine: the one
/// owner of the compact status (`CompactJobFollower` holds it and feeds it events; the card only
/// reads the words). Every transition is in `apply`; stale or out-of-order events are ignored.
///
/// ```
/// idle ──startPressed──▶ starting ──started/alreadyRunning──▶ tracking(job)
///   │                       └──failed/uncertain──▶ startFailed ──resumed(job)──▶ tracking
///   └──resumed(job)──▶ tracking(job) ──polled(job)──▶ tracking(job') … until job is terminal
///                          └──polled(none) / maxFailedPolls failures──▶ lostTrack
/// ```
/// A new start is accepted from any state except `starting` or a running `tracking`
/// (single-flight; the dashboard enforces it too with 409).
enum CompactProgress: Equatable, Sendable {
    case idle
    /// `POST /api/session/compact` on its way.
    case starting
    /// A job to show: followed while not terminal.
    case tracking(Tracking)
    /// Nothing was started (or a timed-out start found no job), in words.
    case startFailed(String)
    /// The job could no longer be read; it may still be running in the dashboard.
    case lostTrack(CompactJob, String)

    struct Tracking: Equatable, Sendable {
        var job: CompactJob
        /// The start hit a job already running (409): the user's text was not used.
        var adopted = false
        /// Poll failures in a row (reset by any good read).
        var failedPolls = 0
    }

    enum Event: Equatable, Sendable {
        case startPressed
        case startReplied(CompactStartOutcome)
        /// The GET by row made when the card opens (or after an uncertain start).
        case resumed(CompactJobRead)
        /// A GET by id while following.
        case polled(CompactJobRead)
    }

    /// Poll failures in a row before giving up (~7.5s at 1.5s polls).
    static let maxFailedPolls = 5
    static let adoptedNote = "A compact was already running for this agent — showing it. Your text was not sent."
    static let goneReason = "The dashboard no longer knows this compact (restarted?)"

    // MARK: - Reading

    /// The job being followed right now (the follower polls it).
    var runningJobId: String? {
        if case .tracking(let tracking) = self, !tracking.job.isTerminal { return tracking.job.id }
        return nil
    }

    /// True while a new start would be refused (one is on its way or running).
    var isBusy: Bool { self == .starting || runningJobId != nil }

    /// The main line for the card; nil when there is nothing to show.
    var line: String? {
        switch self {
        case .idle: nil
        case .starting: "Starting compact…"
        case .tracking(let tracking): tracking.job.progressLine
        case .startFailed(let reason): "Compact not started: \(reason)"
        case .lostTrack(_, let reason): "Lost track of the compact: \(reason). It may still be running — reopen to check."
        }
    }

    /// Smaller facts under the line; nil when there are none.
    var detail: String? {
        guard case .tracking(let tracking) = self else { return nil }
        let notes = [tracking.adopted ? Self.adoptedNote : nil, tracking.job.detailLine].compactMap { $0 }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// The line reads as a failure (red).
    var isFailure: Bool {
        switch self {
        case .startFailed, .lostTrack: true
        case .tracking(let tracking): tracking.job.state == .failed
        case .idle, .starting: false
        }
    }

    // MARK: - Changing

    /// Applies one event. Returns false when it was ignored (not valid from this state).
    @discardableResult
    mutating func apply(_ event: Event) -> Bool {
        switch (event, self) {
        case (.startPressed, _):
            guard !isBusy else { return false }
            self = .starting

        case (.startReplied(let outcome), .starting):
            switch outcome {
            case .started(let job): self = .tracking(Tracking(job: job))
            case .alreadyRunning(let job): self = .tracking(Tracking(job: job, adopted: true))
            case .failed(let reason), .uncertain(let reason): self = .startFailed(reason)
            }
        case (.startReplied, _):
            return false

        case (.resumed(.job(let job)), .idle), (.resumed(.job(let job)), .startFailed):
            // After a failed start, only a running job is news (a finished one predates the press).
            if case .startFailed = self, job.isTerminal { return false }
            self = .tracking(Tracking(job: job))
        case (.resumed, _):
            return false

        case (.polled(let read), .tracking(var tracking)) where !tracking.job.isTerminal:
            switch read {
            case .job(let job):
                guard job.id == tracking.job.id else { return false }
                tracking.job = job
                tracking.failedPolls = 0
                self = .tracking(tracking)
            case .none:
                self = .lostTrack(tracking.job, Self.goneReason)
            case .failed(let reason):
                tracking.failedPolls += 1
                self = tracking.failedPolls >= Self.maxFailedPolls ? .lostTrack(tracking.job, reason) : .tracking(tracking)
            }
        case (.polled, _):
            return false
        }
        return true
    }
}
