import Foundation
import Observation

/// What the sheet shows when no summary could be made. Wording is pure so it is unit-tested.
enum ReaderSummaryFailure: Equatable {
    case tooShort
    case subscriptionRequired
    case notSignedIn
    case quotaExhausted(resetsAt: Date?)
    case rateLimited
    case offline
    case unavailable

    init(_ error: ReaderSummaryError) {
        switch error {
        case .tooShort: self = .tooShort
        case .subscriptionRequired: self = .subscriptionRequired
        case .notSignedIn: self = .notSignedIn
        case .quotaExhausted(let resetsAt): self = .quotaExhausted(resetsAt: resetsAt)
        case .rateLimited: self = .rateLimited
        case .offline: self = .offline
        case .unavailable: self = .unavailable
        }
    }

    func message(now: Date = Date()) -> String {
        switch self {
        case .tooShort: return "This article is too short to summarize."
        case .subscriptionRequired: return "Summary is part of the FastTab subscription."
        case .notSignedIn: return "Sign in to use Summary."
        case .quotaExhausted(let resetsAt):
            guard let resetsAt, resetsAt > now else { return "You've used this month's summaries." }
            // The server resets at midnight UTC on the 1st: say that date, not the local one.
            let date = resetsAt.formatted(Date.FormatStyle(timeZone: .gmt).month(.wide).day())
            return "You've used this month's summaries. They renew on \(date)."
        case .rateLimited: return "Too many summaries at once. Try again in a minute."
        case .offline: return "You're offline. Connect to the internet and try again."
        case .unavailable: return "Summary isn't available right now. Try again later."
        }
    }

    /// Retrying can help (the other cases need a purchase, sign-in, or a different article).
    var canRetry: Bool {
        switch self {
        case .rateLimited, .offline, .unavailable: return true
        default: return false
        }
    }

    /// Resolving it needs the paywall / sign-in sheet.
    var needsPaywall: Bool { self == .subscriptionRequired || self == .notSignedIn }
}

struct ReaderSummaryResult: Equatable {
    let text: String
    let model: String
    let createdAt: Date
    let fromCache: Bool
    /// The person edited the prompt after this was written; it stays until they Regenerate.
    var madeWithOtherPrompt = false
}

/// One article's Summary: cache first (never pay twice), then the one-time consent, then the server.
/// It outlives the sheet on purpose: closing the sheet while a summary is being written lets it
/// finish and save, so reopening shows it instead of paying again. Two models for the same article
/// text (reader closed and reopened mid-write) share ONE request.
@MainActor
@Observable
final class ReaderSummaryModel {
    enum State: Equatable {
        case needsConsent
        case loading
        case ready(ReaderSummaryResult)
        case failed(ReaderSummaryFailure)
    }

    private(set) var state: State = .loading
    /// A Regenerate is running; the previous summary stays on screen meanwhile.
    private(set) var isRegenerating = false
    /// The last Regenerate failed; the previous summary is still shown.
    private(set) var regenerateFailure: ReaderSummaryFailure?

    let article: ReaderArticle
    private let urlKey: String
    private let client: ReaderSummaryClient
    private let store: ReaderSummaryStore
    private let consent: ReaderSummaryConsent
    private let now: @Sendable () -> Date
    @ObservationIgnored private var input: ReaderSummaryText.Input?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The person's custom prompt when this model was made; nil = the server's default.
    let instruction: String?

    /// Requests in flight, by article + text + prompt, so a second model joins instead of paying again.
    private static var inFlight: [String: Task<State, Never>] = [:]

    init(article: ReaderArticle, urlKey: String,
         client: ReaderSummaryClient = .live, store: ReaderSummaryStore = .shared,
         consent: ReaderSummaryConsent = ReaderSummaryConsent(), instruction: String? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.article = article
        self.urlKey = urlKey
        self.client = client
        self.store = store
        self.consent = consent
        self.instruction = instruction
        self.now = now
    }

    private var instructionHash: String { instruction.map(ReaderSummaryStore.hash) ?? "" }

    /// A saved summary exists for this exact text (so a lapsed subscriber can still read it).
    func hasSavedSummary() -> Bool {
        guard case .ready(let prepared) = ReaderSummaryText.prepare(article: article) else { return false }
        return store.anyRecord(urlKey: urlKey, textDigest: ReaderSummaryStore.digest(prepared.text)) != nil
    }

    /// Called whenever the sheet appears. Cheap when a summary is already showing or being written.
    func open() {
        if task != nil { return }
        if case .ready = state { return }
        switch ReaderSummaryText.prepare(article: article) {
        case .tooShort:
            state = .failed(.tooShort)
        case .ready(let prepared):
            input = prepared
            if let hit = store.anyRecord(urlKey: urlKey, textDigest: ReaderSummaryStore.digest(prepared.text)) {
                state = .ready(ReaderSummaryResult(text: hit.summary, model: hit.model,
                                                   createdAt: hit.createdAt, fromCache: true,
                                                   madeWithOtherPrompt: hit.instructionHash != instructionHash))
            } else if consent.isGranted {
                generate()
            } else {
                state = .needsConsent
            }
        }
    }

    func acceptConsent() {
        consent.grant()
        generate()
    }

    /// Asks again and replaces the saved summary (costs one use of the monthly allowance).
    func regenerate() { generate() }

    func retry() {
        if input == nil { open() } else { generate() }
    }

    private func generate() {
        guard task == nil, let input else { return }
        let previous: ReaderSummaryResult?
        if case .ready(let current) = state { previous = current } else { previous = nil }
        regenerateFailure = nil
        if previous != nil { isRegenerating = true } else { state = .loading }
        let digest = ReaderSummaryStore.digest(input.text)
        let key = "\(urlKey)\u{1F}\(digest)\u{1F}\(instructionHash)"
        let work: Task<State, Never>
        if let running = Self.inFlight[key] {
            work = running
        } else {
            let request = ReaderSummaryRequest(text: input.text, languageCode: input.languageCode,
                                               instruction: instruction,
                                               promptVersion: instruction == nil ? nil : ReaderSummaryPrompt.defaultVersion)
            // Not tied to the sheet or this model: the answer is saved for next time.
            work = Task { [client, store, urlKey, instructionHash, now] in
                do {
                    let response = try await client.summarize(request)
                    let record = ReaderSummaryRecord(textDigest: digest, instructionHash: instructionHash,
                                                     summary: response.summary, model: response.model,
                                                     createdAt: now(),
                                                     defaultInstructionVersion: response.defaultInstructionVersion)
                    store.save(record, urlKey: urlKey)
                    return State.ready(ReaderSummaryResult(text: record.summary, model: record.model,
                                                           createdAt: record.createdAt, fromCache: false))
                } catch let error as ReaderSummaryError {
                    return State.failed(ReaderSummaryFailure(error))
                } catch {
                    return State.failed(.unavailable)
                }
            }
            Self.inFlight[key] = work
        }
        task = Task {
            let outcome = await work.value
            if Self.inFlight[key] == work { Self.inFlight[key] = nil } // not a newer request's entry
            self.finish(outcome, keeping: previous)
        }
    }

    private func finish(_ outcome: State, keeping previous: ReaderSummaryResult?) {
        isRegenerating = false
        task = nil
        if case .failed(let failure) = outcome, let previous {
            state = .ready(previous)
            regenerateFailure = failure
        } else {
            state = outcome
        }
    }
}
