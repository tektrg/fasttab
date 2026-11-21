import Foundation
import Testing
@testable import AgentBar

/// A multi-question form on a row that runs on another machine (the Air, Oracle): there is no transcript on this
/// Mac, so the card asks the dashboard (`GET /api/session/latest` → `pendingQuestion`) and shows every question
/// at once, like a local row. Any failure leaves today's single question scraped from the pane.
@MainActor
struct RemoteQuestionFormTests {
    private static let airPane = "air-m1:w8:p3"

    /// The first two questions of the real 3-question form: a 2-question call.
    private static func twoQuestionForm() -> PendingQuestionForm {
        let full = FormFixtures.form()
        return PendingQuestionForm(toolUseId: full.toolUseId, questions: Array(full.questions.prefix(2)))
    }

    private final class LocalReads: @unchecked Sendable {
        private let lock = NSLock()
        private var sessions: [String] = []
        func record(_ session: String) { lock.withLock { sessions.append(session) } }
        var all: [String] { lock.withLock { sessions } }
    }

    @MainActor private struct Rig {
        let model: AnswerCardModel
        let terminal: FakeFormTerminal
        let localReads: LocalReads
        let form: PendingQuestionForm

        /// Blocked on tab `tab` of the form; on the Air unless `paneId` says otherwise. The row id is the agent id ("a").
        func agent(tab: Int = 0, paneId: String = RemoteQuestionFormTests.airPane) -> AgentSnapshot {
            let question = PaneQuestionReader.question(in: FormFixtures.screen(form, tab: tab))!
            return AnswerFixtures.blockedAgent("a", blocker: .question(question), paneId: paneId)
        }
    }

    /// `localForm` is what this Mac's transcript holds; `dashboardForm` what the dashboard serves for the row.
    private func makeRig(localForm: PendingQuestionForm? = nil, dashboardForm: PendingQuestionForm?) -> Rig {
        let form = Self.twoQuestionForm()
        let localReads = LocalReads()
        let model = AnswerCardModel(
            loadSessionContext: { _ in .empty },
            loadPendingForm: { session in
                localReads.record(session)
                return localForm
            }
        )
        let terminal = FakeFormTerminal(form: form)
        terminal.serveDashboardForm(dashboardForm)
        model.statusSource = terminal
        return Rig(model: model, terminal: terminal, localReads: localReads, form: form)
    }

    @Test func aRemoteRowWithATwoQuestionFormOpensAsTheWholeForm() async {
        let rig = makeRig(dashboardForm: Self.twoQuestionForm())
        #expect(rig.model.open(rig.agent()))
        await waitUntil { rig.model.card?.form != nil }
        #expect(rig.model.card?.form?.form == rig.form)
        #expect(rig.model.card?.form?.form.questions.map(\.question) == rig.form.questions.map(\.question))
        #expect(rig.model.card?.hintMode == .form)
        #expect(rig.terminal.dashboardFormReads == ["a"])
        #expect(rig.localReads.all.isEmpty)
    }

    @Test func aRemoteRowOnItsSecondTabAlsoOpensAsTheForm() async {
        let rig = makeRig(dashboardForm: Self.twoQuestionForm())
        #expect(rig.model.open(rig.agent(tab: 1)))
        await waitUntil { rig.model.card?.form != nil }
        #expect(rig.model.card?.form?.form.questions.count == 2)
    }

    @Test func aFailedOrEmptyDashboardReadKeepsTheScrapedSingleQuestion() async {
        let rig = makeRig(dashboardForm: nil)
        #expect(rig.model.open(rig.agent()))
        await settleTasks()
        #expect(rig.terminal.dashboardFormReads == ["a"])
        #expect(rig.model.card?.form == nil)
        #expect(rig.model.card?.hintMode == .singleSelect)
        #expect(rig.model.card?.state.question.identity == PaneQuestionReader.question(in: FormFixtures.screen(rig.form, tab: 0))?.identity)
    }

    @Test func aRemoteRowNeverFallsBackToThisMacsTranscript() async {
        // Even if a same-named session on this Mac held a form, a remote row's form comes only from the dashboard.
        let rig = makeRig(localForm: Self.twoQuestionForm(), dashboardForm: nil)
        #expect(rig.model.open(rig.agent()))
        await settleTasks()
        #expect(rig.localReads.all.isEmpty)
        #expect(rig.model.card?.form == nil)
    }

    @Test func aStatusSourceWithoutTheReadKeepsTheScrapedQuestion() async {
        // A source that predates `pendingForm` answers nil through the protocol's default.
        let model = AnswerCardModel(loadSessionContext: { _ in .empty }, loadPendingForm: { _ in nil })
        model.statusSource = AnswerFakeSource()
        let form = Self.twoQuestionForm()
        let question = PaneQuestionReader.question(in: FormFixtures.screen(form, tab: 0))!
        #expect(model.open(AnswerFixtures.blockedAgent("a", blocker: .question(question), paneId: Self.airPane)))
        await settleTasks()
        #expect(model.card != nil && model.card?.form == nil)
    }

    @Test func aDashboardFormForADifferentQuestionIsNotAdopted() async {
        // The pane has moved on to a new question: the form served is for one that is gone.
        let stale = PendingQuestionForm(toolUseId: "toolu_old", questions: Self.twoQuestionForm().questions.map {
            FormQuestion(header: $0.header, question: "Earlier: \($0.question)", isMultiSelect: false, options: $0.options)
        })
        let rig = makeRig(dashboardForm: stale)
        #expect(rig.model.open(rig.agent()))
        await settleTasks()
        #expect(rig.terminal.dashboardFormReads == ["a"])
        #expect(rig.model.card?.form == nil)
    }

    @Test func aDashboardFormOfOneQuestionIsTheOrdinaryCard() async {
        let single = PendingQuestionForm(toolUseId: "t", questions: [Self.twoQuestionForm().questions[0]])
        let rig = makeRig(dashboardForm: single)
        #expect(rig.model.open(rig.agent()))
        await settleTasks()
        #expect(rig.model.card?.form == nil)
    }

    @Test func aLocalRowStillReadsThisMacsTranscriptAndNeverTheDashboard() async {
        let rig = makeRig(localForm: Self.twoQuestionForm(), dashboardForm: Self.twoQuestionForm())
        #expect(rig.model.open(rig.agent(paneId: "w1:a")))
        await waitUntil { rig.model.card?.form != nil }
        #expect(rig.model.card?.form?.form == rig.form)
        #expect(rig.localReads.all == ["session-1"])
        #expect(rig.terminal.dashboardFormReads.isEmpty)
    }

    @Test func aLocalRowWithoutASessionStillNeverLooksForAForm() async {
        let rig = makeRig(localForm: Self.twoQuestionForm(), dashboardForm: Self.twoQuestionForm())
        let question = PaneQuestionReader.question(in: FormFixtures.screen(rig.form, tab: 0))!
        #expect(rig.model.open(AnswerFixtures.blockedAgent("a", blocker: .question(question), sessionId: nil, paneId: "w1:a")))
        await settleTasks()
        #expect(rig.localReads.all.isEmpty && rig.terminal.dashboardFormReads.isEmpty)
        #expect(rig.model.card?.form == nil)
    }

    // MARK: - The pure choice

    @Test func readPendingFormAsksOnlyTheChosenSide() async {
        let form = Self.twoQuestionForm()
        let terminal = FakeFormTerminal(form: form)
        terminal.serveDashboardForm(form)
        let local = await LatestMessageSource.readPendingForm(
            .localTranscript, sessionId: "sess", readLocal: { _ in nil }, status: terminal)
        #expect(local == nil)
        #expect(terminal.dashboardFormReads.isEmpty)
        let remote = await LatestMessageSource.readPendingForm(
            .dashboard(rowId: "s-air"), sessionId: nil, readLocal: { _ in form }, status: terminal)
        #expect(remote == form)
        #expect(terminal.dashboardFormReads == ["s-air"])
        let noSource = await LatestMessageSource.readPendingForm(
            .dashboard(rowId: "s-air"), sessionId: "sess", readLocal: { _ in form }, status: nil)
        #expect(noSource == nil)
    }
}

/// Decoding `pendingQuestion` from `GET /api/session/latest`, and `DashboardStatusSource.pendingForm`.
@Suite(.timeLimit(.minutes(1)))
struct SessionLatestPendingQuestionTests {
    private static let fullReply = """
    {"ok": true, "rowId": "s-air", "machine": "air-m1", "latestMessage": "Two things first.",
     "pendingQuestion": {"toolUseId": "toolu_1", "questions": [
       {"question": "Which database?", "header": "Database", "isMultiSelect": false,
        "options": [{"label": "SQLite", "description": "Local file"}, {"label": "Postgres", "description": "Server"}]},
       {"question": "Which extras?", "header": "Extras", "isMultiSelect": true,
        "options": [{"label": "Search"}, {"label": "Sync", "description": "Across Macs"}]}
     ]}}
    """

    private func decode(_ json: String) throws -> DashboardSessionLatestResponse {
        try JSONDecoder().decode(DashboardSessionLatestResponse.self, from: Data(json.utf8))
    }

    @Test func aFullPendingQuestionMapsOntoTheForm() throws {
        let reply = try decode(Self.fullReply)
        #expect(reply.ok == true)
        #expect(reply.latestMessage == "Two things first.")
        let form = try #require(reply.pendingQuestion)
        #expect(form.toolUseId == "toolu_1")
        #expect(form.questions == [
            FormQuestion(header: "Database", question: "Which database?", isMultiSelect: false,
                         options: [.init(label: "SQLite", description: "Local file"), .init(label: "Postgres", description: "Server")]),
            FormQuestion(header: "Extras", question: "Which extras?", isMultiSelect: true,
                         options: [.init(label: "Search", description: ""), .init(label: "Sync", description: "Across Macs")])
        ])
    }

    @Test func anAbsentOrNullPendingQuestionIsNil() throws {
        let absent = try decode(#"{"ok": true, "latestMessage": "hi"}"#)
        #expect(absent.pendingQuestion == nil && absent.latestMessage == "hi")
        let null = try decode(#"{"ok": true, "latestMessage": null, "pendingQuestion": null}"#)
        #expect(null.pendingQuestion == nil && null.latestMessage == nil && null.ok == true)
    }

    @Test func missingOptionalFieldsTakeDefaults() throws {
        let reply = try decode("""
        {"ok": true, "pendingQuestion": {"toolUseId": "t", "questions": [{"question": "Q?", "options": [{"label": "A"}]}]}}
        """)
        #expect(reply.pendingQuestion?.questions == [
            FormQuestion(header: "", question: "Q?", isMultiSelect: false, options: [.init(label: "A", description: "")])
        ])
    }

    @Test func anUnreadablePendingQuestionIsNilButNeverCostsTheMessage() throws {
        let shapes = [
            #"{"toolUseId": "t", "questions": [{"question": "Q?", "options": []}]}"#,
            #"{"toolUseId": "t", "questions": [{"question": "  ", "options": [{"label": "A"}]}]}"#,
            #"{"toolUseId": "t", "questions": [{"question": "Q?", "options": [{"label": ""}]}]}"#,
            #"{"toolUseId": "t", "questions": [{"options": [{"label": "A"}]}]}"#,
            #"{"toolUseId": "", "questions": [{"question": "Q?", "options": [{"label": "A"}]}]}"#,
            #"{"toolUseId": "t", "questions": []}"#,
            #"{"questions": [{"question": "Q?", "options": [{"label": "A"}]}]}"#,
            #""a string""#,
            #"[1, 2]"#
        ]
        for shape in shapes {
            let reply = try decode(#"{"ok": true, "latestMessage": "kept", "pendingQuestion": \#(shape)}"#)
            #expect(reply.pendingQuestion == nil, "\(shape)")
            #expect(reply.latestMessage == "kept", "\(shape)")
        }
    }

    // MARK: - DashboardStatusSource

    private func makeSource(_ transport: any DashboardTransport) -> DashboardStatusSource {
        DashboardStatusSource(endpoint: DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4711")!), transport: transport)
    }

    @Test func pendingFormAsksSessionLatestForTheRow() async throws {
        let transport = ScriptedDashboardTransport { _ in .body(Data(Self.fullReply.utf8)) }
        let form = await makeSource(transport).pendingForm(rowId: "s-air")
        #expect(form?.questions.count == 2)
        let request = try #require(transport.requests.first)
        #expect(request.url?.path == "/api/session/latest")
        #expect(request.url?.query == "rowId=s-air")
    }

    @Test func pendingFormIsNilOnAnyFailure() async {
        let refused = ScriptedDashboardTransport { _ in .body(Data(#"{"ok": false, "error": "row s-air is not live"}"#.utf8)) }
        #expect(await makeSource(refused).pendingForm(rowId: "s-air") == nil)
        let serverError = ScriptedDashboardTransport { _ in .body(Data(Self.fullReply.utf8), statusCode: 500) }
        #expect(await makeSource(serverError).pendingForm(rowId: "s-air") == nil)
        let unreachable = ScriptedDashboardTransport { _ in .fail }
        #expect(await makeSource(unreachable).pendingForm(rowId: "s-air") == nil)
        let garbage = ScriptedDashboardTransport { _ in .body(Data("oops".utf8)) }
        #expect(await makeSource(garbage).pendingForm(rowId: "s-air") == nil)
    }

    @Test func theMessageAndTheFormAskedTogetherShareOneRead() async throws {
        let transport = HeldDashboardTransport(body: Data(Self.fullReply.utf8))
        let source = makeSource(transport)
        let message = Task { await source.latestMessage(rowId: "s-air") }
        await transport.waitForRequests(1)
        let form = Task { await source.pendingForm(rowId: "s-air") }
        // Let the second ask reach the source while the first read is still out.
        try await Task.sleep(for: .milliseconds(200))
        transport.release()
        #expect(await message.value == "Two things first.")
        #expect(await form.value?.toolUseId == "toolu_1")
        #expect(transport.requestCount == 1)
        // Once it is back, a later ask reads afresh.
        #expect(await source.pendingForm(rowId: "s-air")?.toolUseId == "toolu_1")
        #expect(transport.requestCount == 2)
    }
}

/// Holds every reply until `release()`.
private final class HeldDashboardTransport: DashboardTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let body: Data
    private var count = 0
    private var released = false

    init(body: Data) { self.body = body }

    var requestCount: Int { lock.withLock { count } }
    func release() { lock.withLock { released = true } }

    func waitForRequests(_ wanted: Int) async {
        var polls = 0
        while requestCount < wanted, polls < 2500 {
            polls += 1
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func response(for request: URLRequest) async throws -> (body: Data, statusCode: Int) {
        lock.withLock { count += 1 }
        while !lock.withLock({ released }) { try await Task.sleep(for: .milliseconds(2)) }
        return (body, 200)
    }

    func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish(throwing: URLError(.cannotConnectToHost)) }
    }
}
