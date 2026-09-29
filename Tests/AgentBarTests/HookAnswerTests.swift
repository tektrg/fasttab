import Foundation
import Testing
@testable import AgentBar

/// The hook answer bridge: a Claude session's prompt (status-only row or herdr pane), held by the
/// dashboard's `PermissionRequest` hook bridge, answered from AgentBar by request id (no pane).
enum HookFixtures {
    typealias S = StatusOnlyFixtures

    static let questionRequest = """
    {"requestId": "req_q1", "kind": "question", "toolName": "AskUserQuestion", "createdAt": 1700000000, "sinceSec": 4,
     "questions": [{"question": "Which fruit?", "header": "Fruit", "multiSelect": false,
                    "options": [{"label": "Apple", "description": "Red"}, {"label": "Pear", "description": "Green"}]}]}
    """

    static let formRequest = """
    {"requestId": "req_f1", "kind": "question", "toolName": "AskUserQuestion",
     "questions": [{"question": "Which fruit?", "header": "Fruit", "multiSelect": false,
                    "options": [{"label": "Apple", "description": ""}, {"label": "Pear", "description": ""}]},
                   {"question": "Which toppings?", "header": "Toppings", "multiSelect": true,
                    "options": [{"label": "Cream"}, {"label": "Nuts"}, {"label": "Honey"}]}]}
    """

    static let permissionRequest = """
    {"requestId": "req_p1", "kind": "permission", "toolName": "Bash",
     "permission": {"title": "Allow Bash?", "detail": "python3 -c \\"print('x')\\"",
                    "suggestions": [{"index": 0, "label": "Always allow `python3 -c ...` in this project"},
                                    {"index": 1, "label": "Always allow reading /tmp"}]}}
    """

    static func needsYou(hookRequest: String?, session: String = S.desktopSession) -> String {
        """
        {"kind": "blocked", "paneId": null, "detail": "Permission: Bash", "agentSession": "\(session)",
         "source": "claude-desktop", "sinceSec": 12, "hookRequest": \(hookRequest ?? "null")}
        """
    }

    static func mapped(_ hookRequest: String?) throws -> AgentSnapshot? {
        try S.snapshot(agents: [S.desktopRow()], needsYou: [needsYou(hookRequest: hookRequest)]).agents.first
    }

    static func request(_ json: String) -> HookRequest? {
        HookRequest(try? JSONDecoder().decode(DashboardHookRequest.self, from: Data(json.utf8)))
    }

    /// A herdr pane row in Needs you (screen says a plain prompt), with or without a held hook request.
    static func herdrMapped(_ hookRequest: String?) throws -> AgentSnapshot? {
        let herdrRow = """
        {"paneId": "w1:p1", "label": "h", "cwd": "/p", "hookState": "blocked", "hasHookData": true,
         "agentSession": "s-herdr", "rowId": "s-herdr", "screenState": "blocked"}
        """
        let entry = """
        {"kind": "blocked", "paneId": "w1:p1", "detail": "Input needed", "sinceSec": 3, "hookRequest": \(hookRequest ?? "null")}
        """
        return try S.snapshot(agents: [herdrRow], needsYou: [entry]).agents.first
    }

    /// A status-only agent in Needs you whose prompt the hook bridge holds.
    static func agent(_ json: String, id: String = S.desktopSession) -> AgentSnapshot {
        var agent = S.desktopAgent(id)
        agent.hookRequest = request(json)
        agent.blocker = agent.hookRequest?.blocker
        return agent
    }
}

/// Records hook answers (and any pane call, which must never happen); replies are scripted.
final class HookFakeSource: AgentStatusSource, @unchecked Sendable {
    struct Sent: Equatable {
        let requestId: String
        let answer: HookAnswer
    }

    let updates = AsyncStream<StatusSnapshot> { _ in }
    private let lock = NSLock()
    private var sentAnswers: [Sent] = []
    private var paneCalls = 0
    var reply: HookAnswerOutcome = .sent

    var sent: [Sent] { lock.withLock { sentAnswers } }
    var paneCallCount: Int { lock.withLock { paneCalls } }

    func focus(paneId: String) async -> FocusResult { .success }
    func paneScreen(paneId: String) async -> PaneScreenResult {
        lock.withLock { paneCalls += 1 }
        return .failure("no pane")
    }
    func perform(_ kind: SessionActionKind, rowId: String, confirmed: Bool) async -> SessionActionOutcome { .failed("unused") }
    func answer(paneId: String, choice: AnswerChoice, question: QuestionIdentity) async -> AnswerResult {
        lock.withLock { paneCalls += 1 }
        return .failed("pane path used")
    }
    func permission(paneId: String, choice: PermissionChoice, permission: PermissionPrompt) async -> PermissionResult {
        lock.withLock { paneCalls += 1 }
        return .failed("pane path used")
    }
    func answerHookRequest(requestId: String, answer: HookAnswer) async -> HookAnswerOutcome {
        lock.withLock { sentAnswers.append(Sent(requestId: requestId, answer: answer)) }
        return reply
    }
}

struct HookRequestMappingTests {
    typealias H = HookFixtures

    @Test func aHookQuestionMakesTheStatusOnlyRowAnswerable() throws {
        let row = try #require(try H.mapped(H.questionRequest))
        #expect(row.section == .needsYou)
        #expect(row.hookRequest?.requestId == "req_q1")
        guard case .question(let question)? = row.blockedOnYou else { Issue.record("no question blocker"); return }
        #expect(question.title == "Fruit")
        #expect(question.question == "Which fruit?")
        #expect(question.options.map(\.label) == ["Apple", "Pear", HookRequest.otherOptionLabel])
        #expect(question.options.map(\.index) == [1, 2, 3])
        #expect(question.options.last?.isOther == true)
        #expect(row.statusText == "Fruit: Which fruit?")
        #expect(row.paneId == nil)
    }

    @Test func aHookPermissionIsReviewableWithOneRowPerSuggestion() throws {
        let row = try #require(try H.mapped(H.permissionRequest))
        guard case .permissionReview(let prompt)? = row.blockedOnYou else { Issue.record("no review blocker"); return }
        #expect(prompt.tool == "Bash")
        #expect(prompt.title == "Allow Bash?")
        #expect(prompt.detail == "python3 -c \"print('x')\"")
        #expect(prompt.choices == [.allow, .allowAlwaysSuggestion(0), .allowAlwaysSuggestion(1), .deny])
        #expect(prompt.option(for: .allowAlwaysSuggestion(1))?.label == "Always allow reading /tmp")
        #expect(prompt.option(for: .allowAlways) == nil)
    }

    @Test func withoutAHookRequestTheRowIsTheSameGenericNeedsYouAsBefore() throws {
        let row = try #require(try H.mapped(nil))
        #expect(row.section == .needsYou)
        #expect(row.blocker == nil)
        #expect(row.hookRequest == nil)
        #expect(RowButtons.available(for: row).map(\.button) == [.peek, .park, .openInClaude])   // a Desktop row
    }

    @Test func anUnusableHookRequestIsIgnored() throws {
        let unsafeId = H.questionRequest.replacingOccurrences(of: "req_q1", with: "../state")
        #expect(try H.mapped(unsafeId)?.blocker == nil)
        #expect(try H.mapped(#"{"requestId": "r1", "kind": "mystery"}"#)?.blocker == nil)
        #expect(try H.mapped(#"{"requestId": "r1", "kind": "question", "questions": []}"#)?.blocker == nil)
        #expect(try H.mapped(#"{"requestId": 7, "kind": "question"}"#)?.blocker == nil)
        #expect(try H.mapped(#""not an object""#)?.blocker == nil)
        let duplicateTexts = H.formRequest.replacingOccurrences(of: "Which toppings?", with: "Which fruit?")
        #expect(try H.mapped(duplicateTexts)?.blocker == nil)
    }

    @Test func aHerdrRowTakesAHookRequestOverItsScreen() throws {
        let row = try #require(try H.herdrMapped(H.questionRequest))
        #expect(row.host == .herdr)
        #expect(row.paneId == "w1:p1")
        #expect(row.hookRequest?.requestId == "req_q1")
        guard case .question(let question)? = row.blocker else { Issue.record("no hook question blocker"); return }
        #expect(question.question == "Which fruit?")
    }

    @Test func aHerdrRowWithoutAHookRequestKeepsItsScreenBlocker() throws {
        let row = try #require(try H.herdrMapped(nil))
        #expect(row.hookRequest == nil)
        #expect(row.blocker == .permission)
    }
}

struct HookRowButtonTests {
    typealias H = HookFixtures

    @Test func aHookQuestionOffersAnswerAndAHookPermissionOffersReview() {
        #expect(RowButtons.available(for: H.agent(H.questionRequest)).map(\.button) == [.answer, .peek, .park])
        #expect(RowButtons.available(for: H.agent(H.permissionRequest)).map(\.button) == [.review, .peek, .park])
        #expect(RowButtons.isPressable(.answer, on: H.agent(H.questionRequest)))
        #expect(!RowButtons.isPressable(.message, on: H.agent(H.questionRequest)))
    }

    @Test func aSoleHookBlockerShowsItsCardAtTheCorner() {
        let row = H.agent(H.permissionRequest)
        let content = CornerTabContent.forArrivals([row], among: [row])
        #expect(content?.blockedCount == 1)
        #expect(content?.soleCardableAgentID == row.id)
    }
}

struct HookAnswerBodyTests {
    typealias H = HookFixtures

    private var fruit: FormQuestion { H.request(H.formRequest)!.questions[0] }
    private var toppings: FormQuestion { H.request(H.formRequest)!.questions[1] }

    @Test func aPickedOptionIsSentAsItsLabel() {
        #expect(HookAnswer.answering(fruit, with: .select([2]))?.answers == ["Which fruit?": "Pear"])
        #expect(HookAnswer.answering(fruit, with: .select([3])) == nil)   // the Other row is never selected
        #expect(HookAnswer.answering(fruit, with: .select([])) == nil)
    }

    @Test func multiSelectLabelsAreJoinedWithCommas() {
        #expect(HookAnswer.answering(toppings, with: .select([1, 3]))?.answers == ["Which toppings?": "Cream, Honey"])
    }

    @Test func otherTextIsSanitisedAndCapped() {
        let typed = "line one\nline\ttwo\u{1B}[A  end"
        #expect(HookAnswer.answering(fruit, with: .text(typed))?.answers == ["Which fruit?": "line one line two[A end"])
        let long = String(repeating: "a", count: 600)
        #expect(HookAnswer.answering(fruit, with: .text(long))?.answers?["Which fruit?"]?.count == 500)
        #expect(HookAnswer.answering(fruit, with: .text(" \n ")) == nil)
    }

    @Test func aFormSendsEveryAnswerAtOnce() {
        let answer = HookAnswer.answering([fruit, toppings], with: [.options([0]), .options([1, 2])])
        #expect(answer?.behavior == .allow)
        #expect(answer?.answers == ["Which fruit?": "Apple", "Which toppings?": "Nuts, Honey"])
        #expect(HookAnswer.answering([fruit, toppings], with: [.options([0])]) == nil)
        #expect(HookAnswer.answering([fruit, toppings], with: [.options([0]), .options([9])]) == nil)
    }

    @Test func permissionDecisionsMapToAllowDenyAndSuggestion() {
        #expect(HookAnswer.deciding(.allow).jsonObject as NSDictionary == ["behavior": "allow"])
        #expect(HookAnswer.deciding(.deny).jsonObject as NSDictionary == ["behavior": "deny", "message": HookAnswer.denialMessage])
        #expect(HookAnswer.deciding(.allowAlwaysSuggestion(1)).jsonObject as NSDictionary == ["behavior": "allow", "suggestionIndex": 1])
    }

    @Test func theRequestGoesToTheRequestsOwnAnswerPath() throws {
        let endpoint = DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:9")!)
        let answer = HookAnswer.answering(fruit, with: .select([1]))!
        let request = try #require(endpoint.hookAnswerRequest(requestId: "req_q1", answer: answer))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://127.0.0.1:9/api/hook/permission/req_q1/answer")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? NSDictionary
        #expect(body == ["behavior": "allow", "answers": ["Which fruit?": "Apple"]])
        #expect(endpoint.hookAnswerRequest(requestId: "a/b", answer: answer) == nil)
        #expect(endpoint.hookAnswerRequest(requestId: "", answer: answer) == nil)
    }

    @Test func repliesAreReadVerbatim() {
        #expect(DashboardHookAnswerResponse.outcome(body: Data(#"{"ok": true}"#.utf8), statusCode: 200) == .sent)
        #expect(DashboardHookAnswerResponse.outcome(body: Data(#"{"error": "not pending"}"#.utf8), statusCode: 409) == .failed("not pending"))
        #expect(DashboardHookAnswerResponse.outcome(body: Data(), statusCode: 404) == .failed(DashboardHookAnswerResponse.goneMessage))
        // The dashboard's real 404 bodies read as the plain-words message, not "unknown request".
        #expect(DashboardHookAnswerResponse.outcome(body: Data(#"{"ok": false, "error": "unknown request"}"#.utf8), statusCode: 404)
            == .failed(DashboardHookAnswerResponse.goneMessage))
        #expect(DashboardHookAnswerResponse.outcome(body: Data(#"{"error": "not found"}"#.utf8), statusCode: 404)
            == .failed(DashboardHookAnswerResponse.goneMessage))
        #expect(DashboardHookAnswerResponse.outcome(body: Data(#"{"ok": false}"#.utf8), statusCode: 200)
            == .failed("The dashboard refused the answer (HTTP 200)."))
    }

    @Test func theDashboardSourcePostsOnceAndReportsTheReply() async throws {
        let transport = ScriptedDashboardTransport { _ in .body(Data(#"{"error": "already answered"}"#.utf8), statusCode: 409) }
        let source = DashboardStatusSource(endpoint: DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:9")!), transport: transport)
        let outcome = await source.answerHookRequest(requestId: "req_p1", answer: .deciding(.allow))
        #expect(outcome == .failed("already answered"))
        #expect(transport.requests.map { $0.url?.path } == ["/api/hook/permission/req_p1/answer"])
    }
}

@MainActor
struct HookAnswerCardTests {
    typealias H = HookFixtures

    private func answerModel(_ source: HookFakeSource, notices: @escaping (String) -> Void = { _ in }) -> AnswerCardModel {
        let model = AnswerCardModel(loadSessionContext: { _ in .empty }, loadPendingForm: { _ in nil })
        model.statusSource = source
        model.onNotice = notices
        return model
    }

    @Test func aSingleQuestionIsAnsweredByIdWithoutReadingAPane() async {
        let source = HookFakeSource()
        let model = answerModel(source)
        let agent = H.agent(H.questionRequest)
        #expect(model.open(agent))
        #expect(model.card?.form == nil)
        model.handle(.digit(2))
        await waitUntil { source.sent.count == 1 }
        #expect(source.sent == [.init(requestId: "req_q1", answer: HookAnswer(
            behavior: .allow, answers: ["Which fruit?": "Pear"], suggestionIndex: nil, message: nil))])
        #expect(source.paneCallCount == 0)
        #expect(model.card == nil)
    }

    @Test func aHerdrPanesHookQuestionIsAnsweredByIdNeverThroughThePane() async throws {
        let source = HookFakeSource()
        let model = answerModel(source)
        #expect(model.open(try #require(try H.herdrMapped(H.questionRequest))))
        #expect(model.card?.paneId == "")
        model.handle(.digit(1))
        await waitUntil { source.sent.count == 1 }
        #expect(source.sent.first?.requestId == "req_q1")
        #expect(source.paneCallCount == 0)
    }

    @Test func theOtherRowSendsTypedText() async {
        let source = HookFakeSource()
        let model = answerModel(source)
        model.open(H.agent(H.questionRequest))
        model.handle(.digit(3))
        model.setOtherText("Mango, please")
        model.handle(.enter)
        await waitUntil { source.sent.count == 1 }
        #expect(source.sent.first?.answer.answers == ["Which fruit?": "Mango, please"])
    }

    @Test func severalQuestionsOpenAsOneFormAndGoInOneRequest() async {
        let source = HookFakeSource()
        let model = answerModel(source)
        model.open(H.agent(H.formRequest))
        #expect(model.card?.form?.form.questions.count == 2)
        model.clickFormRow(1, of: 0)
        model.clickFormRow(0, of: 1)
        model.clickFormRow(2, of: 1)
        model.handle(.send)
        await waitUntil { source.sent.count == 1 }
        #expect(source.sent.first?.answer.answers == ["Which fruit?": "Pear", "Which toppings?": "Cream, Honey"])
        #expect(source.paneCallCount == 0)
        await settleTasks()
        #expect(source.sent.count == 1)
    }

    @Test func aRefusalIsShownVerbatimAndNeverRetried() async {
        let source = HookFakeSource()
        source.reply = .failed("Request is not pending (answered in Claude).")
        var notices: [String] = []
        let model = answerModel(source) { notices.append($0) }
        model.open(H.agent(H.questionRequest))
        model.handle(.digit(1))
        await waitUntil { !notices.isEmpty }
        #expect(notices == ["Answer not sent: Request is not pending (answered in Claude)."])
        await settleTasks()
        #expect(source.sent.count == 1)
    }

    @Test func aDifferentRequestClosesTheCard() {
        let model = answerModel(HookFakeSource())
        let agent = H.agent(H.questionRequest)
        model.open(agent)
        model.reconcile(with: [agent])
        #expect(model.card != nil)
        let next = H.agent(H.questionRequest.replacingOccurrences(of: "req_q1", with: "req_q2"))
        model.reconcile(with: [next])
        #expect(model.card == nil)
    }
}

@MainActor
struct HookPermissionCardTests {
    typealias H = HookFixtures

    private func permissionModel(_ source: HookFakeSource, notices: @escaping (String) -> Void = { _ in }) -> PermissionCardModel {
        let model = PermissionCardModel(loadSessionContext: { _ in .empty })
        model.statusSource = source
        model.onNotice = notices
        return model
    }

    @Test func opensReadyWithoutReadingAPane() async {
        let source = HookFakeSource()
        let model = permissionModel(source)
        #expect(model.open(H.agent(H.permissionRequest)))
        #expect(model.card?.state.phase == .ready)
        #expect(model.card?.state.choices == [.allow, .allowAlwaysSuggestion(0), .allowAlwaysSuggestion(1), .deny])
        await settleTasks()
        #expect(source.paneCallCount == 0)
    }

    @Test func aHerdrPanesHookPermissionIsDecidedByIdNeverThroughThePane() async throws {
        let source = HookFakeSource()
        let model = permissionModel(source)
        #expect(model.open(try #require(try H.herdrMapped(H.permissionRequest))))
        #expect(model.card?.paneId == "")
        #expect(model.card?.state.phase == .ready)
        model.handle(.digit(1))
        model.pressSend()
        await waitUntil { source.sent.count == 1 }
        #expect(source.sent.last == .init(requestId: "req_p1", answer: .deciding(.allow)))
        #expect(source.paneCallCount == 0)
    }

    @Test func allowOnceAndDenyAreSentById() async {
        let source = HookFakeSource()
        let model = permissionModel(source)
        model.open(H.agent(H.permissionRequest))
        model.handle(.digit(1))
        model.pressSend()
        await waitUntil { source.sent.count == 1 }
        #expect(source.sent.last == .init(requestId: "req_p1", answer: .deciding(.allow)))

        let other = H.agent(H.permissionRequest.replacingOccurrences(of: "req_p1", with: "req_p2"), id: "other")
        model.open(other)
        model.clickChoice(.deny)
        model.pressSend()
        await waitUntil { source.sent.count == 2 }
        #expect(source.sent.last?.answer.behavior == .deny)
        #expect(source.paneCallCount == 0)
    }

    @Test func alwaysAllowASuggestionTakesASecondPress() async {
        let source = HookFakeSource()
        let model = permissionModel(source)
        model.open(H.agent(H.permissionRequest))
        model.clickChoice(.allowAlwaysSuggestion(1))
        // A suggestion may be a mode switch or a directory, not a rule: never titled "Allow always".
        #expect(model.card?.state.actionTitle == "Allow + change permissions")
        model.pressSend()
        #expect(model.card?.state.isConfirmingAlways == true)
        #expect(model.card?.state.actionTitle == "Confirm permission change")
        #expect(PermissionCardView.confirmAlwaysText(model.card!.state) == "Always allow reading /tmp")
        await settleTasks()
        #expect(source.sent.isEmpty)
        model.pressSend()
        await waitUntil { source.sent.count == 1 }
        #expect(source.sent.first?.answer == HookAnswer(behavior: .allow, answers: nil, suggestionIndex: 1, message: nil))
    }

    @Test func aRefusalIsShownVerbatim() async {
        let source = HookFakeSource()
        source.reply = .failed("not pending")
        var notices: [String] = []
        let model = permissionModel(source) { notices.append($0) }
        model.open(H.agent(H.permissionRequest))
        model.clickChoice(.allow)
        model.pressSend()
        await waitUntil { !notices.isEmpty }
        #expect(notices == ["Approval not sent: not pending"])
    }
}
