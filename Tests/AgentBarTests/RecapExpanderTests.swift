import Foundation
import Testing
@testable import AgentBar

/// A squeezed `※ recap` line gets its full text back from the transcript — only when it is provably the same recap.
@MainActor
struct RecapExpanderTests {
    typealias F = AgentListFixtures

    // The dashboard's own squeeze of `full` (first ~88 chars cut on a word, " … ", last ~58 from a word).
    nonisolated static let full = "The water-shelf retest is done: 3 of 5 old bugs are fixed, but merchandisers still can't produce an answer for Ops. "
        + "I filed DATA-425 to DATA-427 and added the hover-card issue to DATA-419; next is checking DATA-425 against DATA-382."
    nonisolated static let squeezed = "※ recap: The water-shelf retest is done: 3 of 5 old bugs are fixed, but merchandisers … to DATA-419; next is checking DATA-425 against DATA-382."
    nonisolated static let transcript = full + " (disable recaps in /config)"

    @Test func detectsASqueezedRecapOnly() {
        #expect(RecapText.isSqueezed(Self.squeezed))
        #expect(!RecapText.isSqueezed("※ recap: short and whole."))
        #expect(!RecapText.isSqueezed("Waiting … for you"))
    }

    @Test func aMatchingTranscriptRecapReplacesTheSqueezedText() {
        #expect(RecapText.expanded(squeezed: Self.squeezed, transcriptContent: Self.transcript) == "※ recap: " + Self.full)
    }

    @Test func aDifferentRecapIsNeverSubstituted() {
        let other = "We are shipping four Parklet features. The camera worker is fixing the shutter, so keep the phone unlocked. (disable recaps in /config)"
        #expect(RecapText.expanded(squeezed: Self.squeezed, transcriptContent: other) == nil)
    }

    @Test func theNewestAwaySummaryInATranscriptTailIsFound() throws {
        func line(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let older = try line(["type": "system", "subtype": "away_summary", "content": "older recap"])
        let newer = try line(["type": "system", "subtype": "away_summary", "content": Self.transcript])
        let noise = try line(["type": "assistant", "message": ["content": "mentions away_summary in prose"]])
        let data = Data([older, noise, newer, noise].joined(separator: "\n").utf8)
        #expect(SessionTranscriptReader.latestAwaySummary(in: data, chunkStartsAtFileStart: true) == Self.transcript)
        #expect(SessionTranscriptReader.latestAwaySummary(in: Data(noise.utf8), chunkStartsAtFileStart: true) == nil)
    }

    @Test func theExpanderSwapsTheTextOnceTheTranscriptIsRead() async throws {
        let expander = RecapExpander(load: { _ in Self.transcript })
        var changed = 0
        expander.onChange = { changed += 1 }
        var agent = F.agent("a", statusText: Self.squeezed)
        agent.sessionId = "sess-1"
        #expect(expander.expanded([agent]).first?.statusText == Self.squeezed)   // first look: still squeezed, read starts
        for _ in 0..<100 where changed == 0 { try await Task.sleep(for: .milliseconds(50)) }   // up to 5s under load
        #expect(changed == 1)
        #expect(expander.expanded([agent]).first?.statusText == "※ recap: " + Self.full)
    }

    @Test func aRowWithoutASessionOrAPlainStatusIsLeftAlone() {
        let expander = RecapExpander(load: { _ in Issue.record("must not read"); return nil })
        let plain = F.agent("a", statusText: "waiting")
        var noSession = F.agent("b", statusText: Self.squeezed)
        noSession.sessionId = nil
        #expect(expander.expanded([plain, noSession]).map(\.statusText) == ["waiting", Self.squeezed])
    }

    @Test func aMissingTranscriptIsNotReadAgainEverySecond() async throws {
        let counter = Counter()
        let expander = RecapExpander(retryAfter: 60, load: { _ in await counter.bump(); return nil })
        var agent = F.agent("a", statusText: Self.squeezed)
        agent.sessionId = "sess-remote"
        _ = expander.expanded([agent])
        for _ in 0..<100 where await counter.value == 0 { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(100))   // let the result be stored
        _ = expander.expanded([agent])
        _ = expander.expanded([agent])
        try await Task.sleep(for: .milliseconds(100))
        #expect(await counter.value == 1)
    }

    actor Counter {
        var value = 0
        func bump() { value += 1 }
    }
}
