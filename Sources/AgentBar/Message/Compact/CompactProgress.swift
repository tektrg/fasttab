import Foundation

/// What AgentBar knows about one `/compact` job for a row. Pure state machine: the one owner of
/// the compact status (`CompactJobFollower` holds it and feeds it events; the card, the row label
/// and the footer only read the words). Every transition is in `apply`; stale or out-of-order
/// events are ignored.
///
/// ```
/// idle ──startPressed──▶ starting ──started/alreadyRunning──▶ tracking(job)
///   │                       ├──failed──▶ startFailed ──resumed(running job)──▶ tracking
///   │                       └──uncertain──▶ lookingUp ──resumed(job made since the press)──▶ tracking
///   │                                          └──resumed(none / older finished job / failed)──▶ startFailed
///   └──resumed(job)──▶ tracking(job) ──polled(job)──▶ tracking(job') … until job is terminal
///                          └──polled(none) / maxFailedPolls failures──▶ lostTrack
/// ```
/// A new start is accepted from any state except `starting`, `lookingUp` or a running `tracking`
/// (single-flight; the dashboard enforces it too with 409).
enum CompactProgress: Equatable, Sendable {
    case idle
    /// `POST /api/session/compact` on its way.
    case starting
    /// The start got no usable reply (timeout): a job may exist. The follower looks the row up
    /// (never re-posts); a job created at or after `notBefore` (press time minus
    /// `clockSkewSeconds`, compared with the dashboard's `createdAt`) is this press's job, even if
    /// it already finished.
    case lookingUp(reason: String, notBefore: Double)
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
        /// `pressedAt` = when the start was pressed (epoch seconds); used only after an uncertain reply.
        case startReplied(CompactStartOutcome, pressedAt: Double = 0)
        /// The GET by row made when the card opens (or after an uncertain start).
        case resumed(CompactJobRead)
        /// A GET by id while following.
        case polled(CompactJobRead)
    }

    /// Poll failures in a row before giving up (~7.5s at 1.5s polls).
    static let maxFailedPolls = 5
    /// Allowed difference between this Mac's clock (press time) and the dashboard's (`createdAt`).
    static let clockSkewSeconds: Double = 5
    static let adoptedNote = "A compact was already running for this agent — showing it. Your text was not sent."
    static let goneReason = "The dashboard no longer knows this compact (restarted?)"

    // MARK: - Reading

    /// The job being followed right now (the follower polls it).
    var runningJobId: String? {
        if case .tracking(let tracking) = self, !tracking.job.isTerminal { return tracking.job.id }
        return nil
    }

    /// True while a new start would be refused (one is on its way, being looked up, or running).
    var isBusy: Bool {
        if case .lookingUp = self { return true }
        return self == .starting || runningJobId != nil
    }

    /// Nothing more will happen without a new start: the job ended, never started, or was lost.
    var isSettled: Bool {
        switch self {
        case .tracking(let tracking): tracking.job.isTerminal
        case .startFailed, .lostTrack: true
        case .idle, .starting, .lookingUp: false
        }
    }

    /// The job ended `done` with nothing to warn about (the row's short "Compacted ✓"): model
    /// restored (or never switched) and no queued message left unsent.
    var isCleanDone: Bool {
        guard case .tracking(let tracking) = self else { return false }
        let job = tracking.job
        return job.state == .done && job.modelRestored != false && job.followUpSent != false
    }

    /// The main line for the card; nil when there is nothing to show.
    var line: String? {
        switch self {
        case .idle: nil
        case .starting: "Starting compact…"
        case .lookingUp: "Checking whether the compact started…"
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
        case .idle, .starting, .lookingUp: false
        }
    }

    /// The footer sentence for a compact started with no card (Tab-tag/Jev/Peek compose, the row's
    /// ⋯ Compact, Park) once it has settled; nil while it runs and for a clean `done` (the row says
    /// "Compacted ✓" instead). `followUp` = the queued text: repeated when it was NOT sent, so the
    /// user can send it again.
    func headlessNotice(label: String, followUp: String?) -> String? {
        switch self {
        case .idle, .starting, .lookingUp:
            return nil
        case .startFailed(let reason):
            return "Couldn't compact \(label): \(reason)"
        case .lostTrack(_, let reason):
            return "Lost track of \(label)'s compact: \(reason). It may still be running."
        case .tracking(let tracking):
            let job = tracking.job
            guard job.isTerminal else { return nil }
            // Our queued text never went: the job said so, or the job shown is another one (409).
            let typedFollowUp = followUp.flatMap { $0.isEmpty ? nil : $0 }
            let lostFollowUp = (job.followUpSent == false || tracking.adopted) ? typedFollowUp : nil
            if isCleanDone, lostFollowUp == nil { return nil }
            var notes = job.detailNotes.filter { $0 != CompactJob.followUpNotSentNote }
            if tracking.adopted { notes.insert(Self.adoptedHeadlessNote, at: 0) }
            if let lostFollowUp {
                notes.append("\(CompactJob.followUpNotSentNote): \u{201C}\(Self.clipped(lostFollowUp))\u{201D}")
            } else if job.followUpSent == false {
                notes.append(CompactJob.followUpNotSentNote)
            }
            return (["\(label): \(job.progressLine)"] + notes).joined(separator: " · ")
        }
    }

    static let adoptedHeadlessNote = "a compact was already running for this agent, so this one is shown instead"

    private static func clipped(_ text: String, limit: Int = 300) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    // MARK: - Changing

    /// Applies one event. Returns false when it was ignored (not valid from this state).
    @discardableResult
    mutating func apply(_ event: Event) -> Bool {
        switch (event, self) {
        case (.startPressed, _):
            guard !isBusy else { return false }
            self = .starting

        case (.startReplied(let outcome, let pressedAt), .starting):
            switch outcome {
            case .started(let job): self = .tracking(Tracking(job: job))
            case .alreadyRunning(let job): self = .tracking(Tracking(job: job, adopted: true))
            case .failed(let reason): self = .startFailed(reason)
            case .uncertain(let reason): self = .lookingUp(reason: reason, notBefore: pressedAt - Self.clockSkewSeconds)
            }
        case (.startReplied, _):
            return false

        case (.resumed(let read), .lookingUp(let reason, let notBefore)):
            // A job made since the press is this press's job, running or already finished: show it, so
            // pressing again can't send the follow-up twice. An older running one is not ours (adopted).
            guard case .job(let job) = read else {
                self = .startFailed(reason)
                return true
            }
            let createdKnown = job.createdAt > 0
            if createdKnown, job.createdAt >= notBefore {
                self = .tracking(Tracking(job: job))
            } else if !job.isTerminal {
                self = .tracking(Tracking(job: job, adopted: createdKnown))
            } else {
                self = .startFailed(reason)
            }
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
