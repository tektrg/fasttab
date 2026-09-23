import Foundation
import Testing
@testable import AgentBar

/// `POST /api/worker` over the wire. Every test goes through a scripted transport: nothing here
/// can reach a real dashboard or actually create a worktree/pane.
struct WorkerRequestTests {
    private let endpoint = DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4799")!)

    private func makeSource(_ transport: ScriptedDashboardTransport) -> DashboardStatusSource {
        DashboardStatusSource(endpoint: endpoint, transport: transport)
    }

    private func reply(_ json: String, status: Int = 200) -> ScriptedDashboardTransport {
        ScriptedDashboardTransport { _ in .body(Data(json.utf8), statusCode: status) }
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func aWorkerCreationIsAPostWithRepoAliasSlugAndTask() throws {
        let request = endpoint.workerRequest(repoAlias: "fe", slug: "login-fix-ab12", task: "Fix the login timeout")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/worker")
        #expect(request.timeoutInterval == DashboardEndpoint.workerCreationTimeoutSeconds)
        #expect(DashboardEndpoint.workerCreationTimeoutSeconds >= 240)   // worktree(180s) + tab-label(30s) + herdr(30s)
        let json = try body(of: request)
        #expect(json["repoAlias"] as? String == "fe")
        #expect(json["slug"] as? String == "login-fix-ab12")
        #expect(json["task"] as? String == "Fix the login timeout")
        #expect(Set(json.keys) == ["repoAlias", "slug", "task"])
    }

    @Test func aSuccessfulCreationReturnsThePaneWorktreeAndBranch() async {
        let outcome = await makeSource(reply(#"{"ok": true, "paneId": "p1", "worktreePath": "/x/fe-slug", "branch": "wt/slug"}"#))
            .createWorker(repoAlias: "fe", slug: "slug", task: "do it")
        #expect(outcome == .created(WorkerCreationResult(paneId: "p1", worktreePath: "/x/fe-slug", branch: "wt/slug")))
    }

    @Test func aRefusalCarriesTheServersWordsVerbatim() async {
        let outcome = await makeSource(reply(#"{"ok": false, "error": "unknown repoAlias"}"#))
            .createWorker(repoAlias: "bogus", slug: "slug", task: "do it")
        #expect(outcome == .failed("unknown repoAlias"))
    }

    @Test func aTrueReplyMissingAPromisedFieldIsAFailureNeverAPartialSuccess() async {
        let outcome = await makeSource(reply(#"{"ok": true, "paneId": "p1"}"#))
            .createWorker(repoAlias: "fe", slug: "slug", task: "do it")
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
    }

    @Test func aReplyWithNoUsableAnswerIsAFailureNotASuccess() async {
        let outcome = await makeSource(reply("{}")).createWorker(repoAlias: "fe", slug: "slug", task: "do it")
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
    }

    @Test func aNonOkHttpStatusIsAFailure() async {
        let outcome = await makeSource(reply(#"{"error":"boom"}"#, status: 500))
            .createWorker(repoAlias: "fe", slug: "slug", task: "do it")
        guard case .failed(let words) = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(words.contains("HTTP 500"))
    }

    @Test func aTimeoutSaysItMayHaveBeenCreatedAnyway() async {
        let transport = ThrowingWorkerTransport(URLError(.timedOut))
        let outcome = await DashboardStatusSource(endpoint: endpoint, transport: transport)
            .createWorker(repoAlias: "fe", slug: "slug", task: "do it")
        guard case .failed(let words) = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(words.contains("may have been created anyway"))
        #expect(transport.callCount == 1)   // never retried
    }

    @Test func anUnreachableDashboardMeansNothingWasCreated() async {
        let transport = ThrowingWorkerTransport(URLError(.cannotConnectToHost))
        let outcome = await DashboardStatusSource(endpoint: endpoint, transport: transport)
            .createWorker(repoAlias: "fe", slug: "slug", task: "do it")
        guard case .failed(let words) = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(words.contains("Nothing was created"))
    }

    private final class ThrowingWorkerTransport: DashboardTransport, @unchecked Sendable {
        private let error: Error
        private let lock = NSLock()
        private var calls = 0
        init(_ error: Error) { self.error = error }
        var callCount: Int { lock.withLock { calls } }
        func response(for request: URLRequest) async throws -> (body: Data, statusCode: Int) {
            lock.withLock { calls += 1 }
            throw error
        }
        func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }
}
