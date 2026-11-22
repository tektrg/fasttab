import Foundation
import Testing
@testable import AgentBar

/// `/api/session/compact` over the wire: request shapes, `Job` decoding and reply mapping. Scripted transport only.
struct CompactRequestTests {
    private let endpoint = DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4799")!)

    private func makeSource(_ json: String, status: Int = 200) -> (DashboardStatusSource, ScriptedDashboardTransport) {
        let transport = ScriptedDashboardTransport { _ in .body(Data(json.utf8), statusCode: status) }
        return (DashboardStatusSource(endpoint: endpoint, transport: transport), transport)
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The contract's full `Job`, as the dashboard sends it (plus a field this build does not know).
    static let fullJobJSON = """
    {"id": "c-1", "rowId": "row-a", "state": "restoringModel", "originalModel": "Opus 5.5",
     "switchSkipped": false, "skipReason": null, "compactOk": true, "modelRestored": null,
     "followUpSent": null, "error": null, "failedStep": null,
     "createdAt": 1763800000.5, "updatedAt": 1763800012.25, "someNewField": [1, 2]}
    """

    // MARK: - Job decoding

    @Test func aFullJobDecodes() throws {
        let job = try JSONDecoder().decode(CompactJob.self, from: Data(Self.fullJobJSON.utf8))
        #expect(job == CompactJob(id: "c-1", rowId: "row-a", state: .restoringModel, originalModel: "Opus 5.5",
                                  compactOk: true, createdAt: 1763800000.5, updatedAt: 1763800012.25))
    }

    @Test func aMinimalJobWithNullsAndOddValuesDecodes() throws {
        let json = #"{"id": "c-2", "rowId": "r", "state": "failed", "originalModel": null, "switchSkipped": "yes", "error": "  boom ", "failedStep": "", "followUpSent": true, "createdAt": null}"#
        let job = try JSONDecoder().decode(CompactJob.self, from: Data(json.utf8))
        #expect(job.state == .failed && job.originalModel == nil && !job.switchSkipped)
        #expect(job.error == "boom" && job.failedStep == nil && job.followUpSent == true && job.createdAt == 0)
    }

    @Test func everyContractStateDecodesAndAnUnknownOneIsKept() throws {
        let states = ["waitingIdle", "switchingModel", "compacting", "restoringModel", "sendingFollowUp", "done", "failed"]
        for raw in states {
            let job = try JSONDecoder().decode(CompactJob.self, from: Data(#"{"id":"i","rowId":"r","state":"\#(raw)"}"#.utf8))
            #expect(job.state != .unknown(raw), "\(raw)")
            #expect(job.isTerminal == (raw == "done" || raw == "failed"))
        }
        let odd = try JSONDecoder().decode(CompactJob.self, from: Data(#"{"id":"i","rowId":"r","state":"verifying"}"#.utf8))
        #expect(odd.state == .unknown("verifying") && !odd.isTerminal)
    }

    @Test func aJobWithoutIdOrStateIsUnreadable() {
        #expect((try? JSONDecoder().decode(CompactJob.self, from: Data(#"{"rowId":"r","state":"done"}"#.utf8))) == nil)
        #expect((try? JSONDecoder().decode(CompactJob.self, from: Data(#"{"id":"i","rowId":"r"}"#.utf8))) == nil)
    }

    // MARK: - Requests

    @Test func aStartIsAPostWithOnlyTheFieldsThereAre() throws {
        let bare = endpoint.compactStartRequest(rowId: "row-a", actor: "po", instructions: nil, followUp: nil)
        #expect(bare.httpMethod == "POST" && bare.url?.path == "/api/session/compact")
        #expect(bare.value(forHTTPHeaderField: DashboardEndpoint.clientHeaderName) == DashboardEndpoint.clientHeaderValue)
        #expect(Set(try body(of: bare).keys) == ["rowId", "actor"])
        let full = try body(of: endpoint.compactStartRequest(rowId: "row-a", actor: "po", instructions: "keep plan", followUp: "go on"))
        #expect(full["rowId"] as? String == "row-a" && full["actor"] as? String == "po")
        #expect(full["instructions"] as? String == "keep plan" && full["followUp"] as? String == "go on")
    }

    @Test func readsAreGetsByRowOrById() {
        let byRow = endpoint.compactJobRequest(rowId: "row a")
        #expect(byRow.httpMethod == nil || byRow.httpMethod == "GET")
        #expect(byRow.url?.path == "/api/session/compact")
        #expect(URLComponents(url: byRow.url!, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "rowId", value: "row a")])
        #expect(endpoint.compactJobRequest(id: "c-1").url?.path == "/api/session/compact/c-1")
    }

    // MARK: - Replies

    @Test func a202IsStarted() async {
        let (source, transport) = makeSource(#"{"ok": true, "job": \#(Self.fullJobJSON)}"#, status: 202)
        let outcome = await source.startCompact(rowId: "row-a", actor: "po", instructions: "x", followUp: nil)
        guard case .started(let job) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(job.id == "c-1")
        #expect(transport.requests.count == 1)
    }

    @Test func a409AdoptsTheActiveJob() async {
        let (source, _) = makeSource(#"{"ok": false, "error": "job-active", "job": \#(Self.fullJobJSON)}"#, status: 409)
        let outcome = await source.startCompact(rowId: "row-a", actor: "po", instructions: nil, followUp: nil)
        guard case .alreadyRunning(let job) = outcome else { Issue.record("got \(outcome)"); return }
        #expect(job.id == "c-1")
    }

    @Test func a400Or404RefusalCarriesTheServersWords() async {
        let (bad, _) = makeSource(#"{"ok": false, "error": "row is not a Claude pane"}"#, status: 400)
        #expect(await bad.startCompact(rowId: "r", actor: "po", instructions: nil, followUp: nil) == .failed("row is not a Claude pane"))
        let (unknown, _) = makeSource(#"{"ok": false, "error": "unknown row"}"#, status: 404)
        #expect(await unknown.startCompact(rowId: "r", actor: "po", instructions: nil, followUp: nil) == .failed("unknown row"))
    }

    @Test func anOlderDashboardWithoutTheRouteSaysRestartIt() async {
        let (old, _) = makeSource(#"{"error": "not found"}"#, status: 404)
        #expect(await old.startCompact(rowId: "r", actor: "po", instructions: nil, followUp: nil) == .failed(DashboardCompactResponse.missingEndpointReason))
        // …and a read on it is simply "no job" (the card opens quietly).
        #expect(await old.compactJob(rowId: "r") == .none)
    }

    @Test func anUnreadable2xxStartMayHaveStarted() async {
        let (source, _) = makeSource(#"{"ok": true}"#, status: 202)
        guard case .uncertain = await source.startCompact(rowId: "r", actor: "po", instructions: nil, followUp: nil) else {
            Issue.record("expected uncertain"); return
        }
    }

    @Test func aReadByRowIsTheJobOrNone() async throws {
        let expected = try JSONDecoder().decode(CompactJob.self, from: Data(Self.fullJobJSON.utf8))
        let (withJob, transport) = makeSource(#"{"ok": true, "job": \#(Self.fullJobJSON)}"#)
        let read = await withJob.compactJob(rowId: "row-a")
        #expect(read == .job(expected))
        #expect(transport.requests.first?.url?.query == "rowId=row-a")
        let (none, _) = makeSource(#"{"ok": true, "job": null}"#)
        #expect(await none.compactJob(rowId: "row-a") == .none)
    }

    @Test func aReadByUnknownIdIsNone() async {
        let (source, _) = makeSource(#"{"ok": false, "error": "unknown job"}"#, status: 404)
        #expect(await source.compactJob(id: "gone") == .none)
    }

    @Test func anUnreadableJobIsAFailedReadNeverNone() async {
        let (source, _) = makeSource(#"{"ok": true, "job": {"state": "done"}}"#)
        guard case .failed = await source.compactJob(id: "c-1") else { Issue.record("expected failed"); return }
    }

    @Test func anUnreachableDashboardIsAFailedReadAndANotStartedStart() async {
        let transport = ScriptedDashboardTransport { _ in .fail }
        let source = DashboardStatusSource(endpoint: endpoint, transport: transport)
        guard case .failed = await source.compactJob(id: "c-1") else { Issue.record("expected failed read"); return }
        guard case .failed(let words) = await source.startCompact(rowId: "r", actor: "po", instructions: nil, followUp: nil) else {
            Issue.record("expected failed start"); return
        }
        #expect(words.contains("Nothing was started"))
    }
}
