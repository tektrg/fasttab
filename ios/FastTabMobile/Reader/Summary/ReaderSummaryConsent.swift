import Foundation

/// The one-time "your article text leaves the phone" agreement. Nothing is sent before it is given.
struct ReaderSummaryConsent: Sendable {
    static let defaultsKey = "FastTabMobile.readerSummaryConsentV1"

    var defaults: UserDefaults = .standard

    var isGranted: Bool { defaults.bool(forKey: Self.defaultsKey) }
    func grant() { defaults.set(true, forKey: Self.defaultsKey) }
    func revoke() { defaults.removeObject(forKey: Self.defaultsKey) }

    static let title = "Summarize with AI?"
    /// Apple requires saying what is sent, to whom, before sending.
    static let message = "To write a summary, FastTab sends this article's text to our server, which passes it to an AI model provider (through OpenRouter). It is not used to train models, and the summary is saved only on this iPhone. Only articles you choose to summarize are sent."
}
