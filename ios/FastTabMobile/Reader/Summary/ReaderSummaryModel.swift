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

    func message(now: Date = Date(), calendar: Calendar = .current) -> String {
        switch self {
        case .tooShort: return "This article is too short to summarize."
        case .subscriptionRequired: return "Summary is part of the FastTab subscription."
        case .notSignedIn: return "Sign in to use Summary."
        case .quotaExhausted(let resetsAt):
            guard let resetsAt, resetsAt > now else { return "You've used this month's summaries." }
            let date = resetsAt.formatted(.dateTime.month(.wide).day())
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
}

/// One article's Summary: cache first (never pay twice), then the one-time consent, then the server.
/// It outlives the sheet on purpose: closing the sheet while a summary is being written lets it
/// finish and save, so reopening shows it instead of paying again.
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

    private let article: ReaderArticle
    private let urlKey: String
    private let client: ReaderSummaryClient
    private let store: ReaderSummaryStore
    private let consent: ReaderSummaryConsent
    private let now: @Sendable () -> Date
    @ObservationIgnored private var input: ReaderSummaryText.Input?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Custom prompt (slice 3); nil = the server's default.
    private let instruction: String?

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

    /// Called whenever the sheet appears. Cheap when a summary is already showing or being written.
    func open() {
        if task != nil { return }
        if case .ready = state { return }
        switch ReaderSummaryText.prepare(article: article) {
        case .tooShort:
            state = .failed(.tooShort)
        case .ready(let prepared):
            input = prepared
            if let hit = store.record(urlKey: urlKey, textDigest: ReaderSummaryStore.digest(prepared.text),
                                      instructionHash: instructionHash) {
                state = .ready(ReaderSummaryResult(text: hit.summary, model: hit.model,
                                                   createdAt: hit.createdAt, fromCache: true))
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
        state = .loading
        let request = ReaderSummaryRequest(text: input.text, languageCode: input.languageCode,
                                           instruction: instruction)
        let digest = ReaderSummaryStore.digest(input.text)
        // Not cancelled when the sheet closes: the answer is saved for next time.
        task = Task { [client, store, urlKey, instructionHash, now] in
            let outcome: State
            do {
                let response = try await client.summarize(request)
                let record = ReaderSummaryRecord(textDigest: digest, instructionHash: instructionHash,
                                                 summary: response.summary, model: response.model,
                                                 createdAt: now(),
                                                 defaultInstructionVersion: response.defaultInstructionVersion)
                store.save(record, urlKey: urlKey)
                outcome = .ready(ReaderSummaryResult(text: record.summary, model: record.model,
                                                     createdAt: record.createdAt, fromCache: false))
            } catch let error as ReaderSummaryError {
                outcome = .failed(ReaderSummaryFailure(error))
            } catch {
                outcome = .failed(.unavailable)
            }
            await self.finish(outcome)
        }
    }

    private func finish(_ outcome: State) {
        state = outcome
        task = nil
    }
}
