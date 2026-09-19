import Foundation
import Testing
@testable import AgentBar

@Suite(.timeLimit(.minutes(1)))
struct DashboardStatusSourceTests {
    /// Fast timings so retries and polls take milliseconds; `downAfter` is per test.
    private func timings(downAfterFailureSeconds: TimeInterval = 0) -> DashboardStatusSource.Timings {
        .init(pollIntervalSeconds: 0.005, pollFallbackSeconds: 0.05, initialRetryPauseSeconds: 0.005,
              maxRetryPauseSeconds: 0.02, downAfterFailureSeconds: downAfterFailureSeconds)
    }

    private func makeSource(
        _ transport: ScriptedDashboardTransport, downAfterFailureSeconds: TimeInterval = 0
    ) -> DashboardStatusSource {
        DashboardStatusSource(
            endpoint: DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4711")!),
            transport: transport,
            timings: timings(downAfterFailureSeconds: downAfterFailureSeconds)
        )
    }

    private func sseChunks(of fixture: String, splitEvery chunkSize: Int = 4096) -> [Data] {
        let framed = Data("data: ".utf8) + compactJSON(fixture) + Data("\n\n".utf8)
        return stride(from: 0, to: framed.count, by: chunkSize).map {
            framed.subdata(in: $0..<min($0 + chunkSize, framed.count))
        }
    }

    /// SSE events are one line, so re-serialize the pretty fixture compactly.
    private func compactJSON(_ fixture: String) -> Data {
        let object = try! JSONSerialization.jsonObject(with: StatusFixtures.data(fixture))
        return try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Down

    @Test func unreachableDashboardPublishesDownNotAnEmptyList() async {
        let source = makeSource(ScriptedDashboardTransport { _ in .fail })
        let collector = SnapshotCollector(source.updates)
        await source.start()
        let sawDown = await collector.wait { $0.contains { $0.health.isDown } }
        await source.stop()
        #expect(sawDown)
        let first = collector.snapshots.first
        #expect(first?.agents.isEmpty == true)
        #expect(first?.health.isDown == true)
    }

    @Test func downIsPublishedOnceNotOnEveryRetry() async {
        let source = makeSource(ScriptedDashboardTransport { _ in .fail })
        let collector = SnapshotCollector(source.updates)
        await source.start()
        try? await Task.sleep(for: .milliseconds(200))   // many retries at 5-20ms
        await source.stop()
        #expect(collector.snapshots.count == 1)
    }

    @Test func aBriefBlipShorterThanTheGraceStaysQuiet() async {
        let source = makeSource(ScriptedDashboardTransport { _ in .fail }, downAfterFailureSeconds: 60)
        let collector = SnapshotCollector(source.updates)
        await source.start()
        try? await Task.sleep(for: .milliseconds(150))
        await source.stop()
        #expect(collector.snapshots.isEmpty)
    }

    @Test func httpErrorFromPollingIsDown() async {
        let source = makeSource(ScriptedDashboardTransport { _ in .body(Data("oops".utf8), statusCode: 500) })
        let collector = SnapshotCollector(source.updates)
        await source.start()
        let sawDown = await collector.wait { $0.contains { $0.health.isDown } }
        await source.stop()
        #expect(sawDown)
    }

    @Test func brokenFeedArrivingOverSSEIsDown() async {
        let transport = ScriptedDashboardTransport(streamChunks: sseChunks(of: "state-feed-broken")) { _ in .fail }
        let source = makeSource(transport)
        let collector = SnapshotCollector(source.updates)
        await source.start()
        let sawDown = await collector.wait { $0.contains { $0.health.isDown } }
        await source.stop()
        #expect(sawDown)
        #expect(collector.snapshots.first?.agents.isEmpty == true)
    }

    // MARK: - SSE and polling

    @Test func sseEventsSplitIntoSmallChunksBecomeSnapshots() async {
        let transport = ScriptedDashboardTransport(streamChunks: sseChunks(of: "state-healthy", splitEvery: 700)) { _ in .fail }
        let source = makeSource(transport)
        let collector = SnapshotCollector(source.updates)
        await source.start()
        let gotSnapshot = await collector.wait { $0.contains { $0.health == .ok } }
        await source.stop()
        #expect(gotSnapshot)
        let snapshot = collector.snapshots.first { $0.health == .ok }
        #expect(snapshot?.agents(in: .needsYou).count == 5)   // two real prompts + three finished
        #expect(snapshot?.agents(in: .ended).count == 12)   // the whole 72h; the list narrows it to the user's choice
    }

    @Test func pollingTakesOverWhenTheStreamCannotConnect() async {
        let stateBody = StatusFixtures.data("state-healthy")
        let transport = ScriptedDashboardTransport(streamChunks: nil) { request in
            request.url?.path == "/api/state" ? .body(stateBody) : .fail
        }
        let source = makeSource(transport)
        let collector = SnapshotCollector(source.updates)
        await source.start()
        let gotSnapshot = await collector.wait { $0.contains { $0.health == .ok } }
        await source.stop()
        #expect(gotSnapshot)
        #expect(transport.requests.contains { $0.url?.path == "/api/events" })   // tried SSE first
        #expect(transport.requests.contains { $0.url?.path == "/api/state" })
    }

    @Test func recoversFromDownWhenTheDashboardComesBack() async {
        let stateBody = StatusFixtures.data("state-healthy")
        let pollCount = LockedCounter()
        let transport = ScriptedDashboardTransport(streamChunks: nil) { _ in
            pollCount.increment() < 5 ? .fail : .body(stateBody)
        }
        let source = makeSource(transport)
        let collector = SnapshotCollector(source.updates)
        await source.start()
        let recovered = await collector.wait { $0.last?.health == .ok }
        await source.stop()
        #expect(recovered)
        #expect(collector.snapshots.first?.health.isDown == true)
    }

    // MARK: - Actions

    @Test func focusPostsThePaneIdAndReportsSuccess() async throws {
        let transport = ScriptedDashboardTransport { _ in .body(Data(#"{"ok": true, "paneId": "w1:p3"}"#.utf8)) }
        let result = await makeSource(transport).focus(paneId: "w1:p3")
        #expect(result == .success)
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/focus")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["paneId": "w1:p3"])
    }

    @Test func focusReportsTheDashboardsReasonOnFailure() async {
        let transport = ScriptedDashboardTransport { _ in
            .body(Data(#"{"ok": false, "error": "pane w1:p3 not found — likely closed"}"#.utf8))
        }
        let result = await makeSource(transport).focus(paneId: "w1:p3")
        #expect(result == .failure("pane w1:p3 not found — likely closed"))
    }

    @Test func focusFailsGracefullyWhenTheDashboardIsUnreachable() async {
        let result = await makeSource(ScriptedDashboardTransport { _ in .fail }).focus(paneId: "w1:p3")
        #expect(!result.succeeded)
        #expect(result.errorMessage != nil)
    }

    @Test func paneScreenReturnsLinesAndReadTime() async throws {
        let transport = ScriptedDashboardTransport { _ in
            .body(Data(#"{"ok": true, "paneId": "w1:p3", "lines": ["one", "two"], "readTs": 1789744498.5}"#.utf8))
        }
        let result = await makeSource(transport).paneScreen(paneId: "w1:p3")
        #expect(result == .screen(lines: ["one", "two"], readAt: Date(timeIntervalSince1970: 1_789_744_498.5)))
        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/api/pane/screen")
        #expect(request.url?.query?.contains("paneId=w1:p3") == true)
    }

    @Test func paneScreenFailureCarriesTheReason() async {
        let transport = ScriptedDashboardTransport { _ in
            .body(Data(#"{"ok": false, "error": "pane w1:p3 not found", "readTs": 1}"#.utf8))
        }
        #expect(await makeSource(transport).paneScreen(paneId: "w1:p3") == .failure("pane w1:p3 not found"))
    }

    @Test func paneScreenFailsGracefullyWhenUnreachable() async {
        let result = await makeSource(ScriptedDashboardTransport { _ in .fail }).paneScreen(paneId: "w1:p3")
        guard case .failure = result else {
            Issue.record("expected failure")
            return
        }
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Returns the count *before* incrementing.
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        defer { value += 1 }
        return value
    }
}
