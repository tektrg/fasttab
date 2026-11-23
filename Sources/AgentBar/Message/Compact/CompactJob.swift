import Foundation

/// One dashboard `/compact` job (contract `.claude/compact-api-contract.md` "Job"): switch the
/// agent to Sonnet for this session only, compact, restore its model, then send the queued
/// follow-up. The job runs in the dashboard; AgentBar only starts it and reads it.
/// Decoding is lenient: unknown fields are ignored, a null/odd optional is nil, an unknown state
/// is kept as `.unknown` (still followed) — only `id`, `rowId` and `state` are required.
struct CompactJob: Equatable, Sendable, Decodable {
    enum State: Equatable, Sendable {
        case waitingIdle, switchingModel, compacting, restoringModel, sendingFollowUp, done, failed
        /// A state this build does not know (a newer dashboard): followed like a running one.
        case unknown(String)

        init(raw: String) {
            switch raw {
            case "waitingIdle": self = .waitingIdle
            case "switchingModel": self = .switchingModel
            case "compacting": self = .compacting
            case "restoringModel": self = .restoringModel
            case "sendingFollowUp": self = .sendingFollowUp
            case "done": self = .done
            case "failed": self = .failed
            default: self = .unknown(raw)
            }
        }

        var isTerminal: Bool { self == .done || self == .failed }
    }

    let id: String
    let rowId: String
    let state: State
    /// Display label, e.g. "Opus 5.5".
    var originalModel: String?
    var switchSkipped = false
    var skipReason: String?
    /// Nil = not reached yet.
    var compactOk: Bool?
    var modelRestored: Bool?
    /// Nil = no follow-up, or not reached yet.
    var followUpSent: Bool?
    /// The first failure, in words.
    var error: String?
    var failedStep: String?
    var createdAt: Double = 0
    var updatedAt: Double = 0
    /// The `/model` picker may be open on the pane right now (dashboard QA2 2026-11-22). Only then does
    /// the dashboard refuse answers and permission decisions (409 `compact-running`). Missing = false.
    var inPicker = false

    init(id: String, rowId: String, state: State, originalModel: String? = nil, switchSkipped: Bool = false,
         skipReason: String? = nil, compactOk: Bool? = nil, modelRestored: Bool? = nil, followUpSent: Bool? = nil,
         error: String? = nil, failedStep: String? = nil, createdAt: Double = 0, updatedAt: Double = 0,
         inPicker: Bool = false) {
        self.id = id
        self.rowId = rowId
        self.state = state
        self.originalModel = originalModel
        self.switchSkipped = switchSkipped
        self.skipReason = skipReason
        self.compactOk = compactOk
        self.modelRestored = modelRestored
        self.followUpSent = followUpSent
        self.error = error
        self.failedStep = failedStep
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.inPicker = inPicker
    }

    private enum CodingKeys: String, CodingKey {
        case id, rowId, state, originalModel, switchSkipped, skipReason, compactOk, modelRestored
        case followUpSent, error, failedStep, createdAt, updatedAt, inPicker
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        rowId = try container.decode(String.self, forKey: .rowId)
        state = State(raw: try container.decode(String.self, forKey: .state))
        originalModel = Self.nonBlank(container.lenient(.originalModel))
        switchSkipped = container.lenient(.switchSkipped) ?? false
        skipReason = Self.nonBlank(container.lenient(.skipReason))
        compactOk = container.lenient(.compactOk)
        modelRestored = container.lenient(.modelRestored)
        followUpSent = container.lenient(.followUpSent)
        error = Self.nonBlank(container.lenient(.error))
        failedStep = Self.nonBlank(container.lenient(.failedStep))
        createdAt = container.lenient(.createdAt) ?? 0
        updatedAt = container.lenient(.updatedAt) ?? 0
        inPicker = container.lenient(.inPicker) ?? false
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    var isTerminal: Bool { state.isTerminal }

    // MARK: - Words for the card

    /// The progress line: where the job has got to.
    var progressLine: String {
        switch state {
        case .waitingIdle: "Waiting for agent…"
        case .switchingModel: "Switching to Sonnet…"
        case .compacting: "Compacting…"
        case .restoringModel: "Restoring \(originalModel ?? "the model")…"
        case .sendingFollowUp: "Sending your message…"
        case .done: "Compacted ✓"
        case .failed: "Compact failed: \(error ?? "no reason given")"
        case .unknown: "Compacting…"
        }
    }

    static let followUpNotSentNote = "Your queued message was NOT sent"
    static let modelNotRestoredNote = "Model NOT restored: still on Sonnet"

    /// Extra facts under the progress line, joined by " · "; nil when there are none.
    /// `followUpSent == false` / `modelRestored == false` are said in capitals whatever the end state:
    /// the dashboard sets them only when a queued message existed but did not go (also after a
    /// dashboard restart) or the restore did not happen.
    var detailLine: String? {
        let notes = detailNotes
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }

    /// `detailLine`'s facts, one per entry.
    var detailNotes: [String] {
        var notes: [String] = []
        if switchSkipped {
            notes.append("Model not switched" + (skipReason.map { ": \($0)" } ?? ""))
        }
        if modelRestored == false {
            notes.append(Self.modelNotRestoredNote + (originalModel.map { " (was \($0) — switch back with /model)" } ?? " — switch back with /model"))
        }
        switch followUpSent {
        case false?: notes.append(Self.followUpNotSentNote)
        case true? where state == .failed: notes.append("Your message was still sent")
        default: break
        }
        return notes
    }
}

/// How the dashboard answered `POST /api/session/compact`.
enum CompactStartOutcome: Equatable, Sendable {
    /// 202: the job is running.
    case started(CompactJob)
    /// 409 `job-active`: one already runs for this row (single-flight); this is it. The new request was dropped.
    case alreadyRunning(CompactJob)
    /// Refused (400/404) or unreachable, in words: nothing was started.
    case failed(String)
    /// No usable reply (timeout, unreadable): a job may have started. Look it up, never re-post.
    case uncertain(String)
}

/// A `GET /api/session/compact…` read.
enum CompactJobRead: Equatable, Sendable {
    case job(CompactJob)
    /// No job for the row (or that id is unknown, e.g. the dashboard restarted).
    case none
    /// Unreachable or unreadable, in words.
    case failed(String)
}
