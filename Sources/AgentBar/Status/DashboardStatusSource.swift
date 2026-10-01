import Foundation

/// Reads agent status from the chief dashboard: prefers its SSE stream, falls
/// back to polling `/api/state` while the stream is unavailable, and publishes
/// a `.down` snapshot once neither has worked for `Timings.downAfterFailureSeconds`.
actor DashboardStatusSource: AgentStatusSource, AgentTreeEditing, PersonaDirectorySource {
    struct Timings: Sendable {
        /// Poll cadence while SSE is unavailable (the dashboard refreshes every ~2s).
        var pollIntervalSeconds: TimeInterval
        /// How long to poll before trying the SSE stream again.
        var pollFallbackSeconds: TimeInterval
        /// Retry pause after a failure; doubles up to `maxRetryPauseSeconds`.
        var initialRetryPauseSeconds: TimeInterval
        var maxRetryPauseSeconds: TimeInterval
        /// Continuous failure this long before showing "down" (rides out a blip).
        var downAfterFailureSeconds: TimeInterval

        static let standard = Timings(
            pollIntervalSeconds: 3,
            pollFallbackSeconds: 30,
            initialRetryPauseSeconds: 1,
            maxRetryPauseSeconds: 15,
            downAfterFailureSeconds: 6
        )
    }

    nonisolated let updates: AsyncStream<StatusSnapshot>
    private let updatesContinuation: AsyncStream<StatusSnapshot>.Continuation
    private let endpoint: DashboardEndpoint
    private let transport: DashboardTransport
    private let timings: Timings
    private let now: @Sendable () -> Date

    private var runTask: Task<Void, Never>?
    private var failingSince: Date?
    private var lastPublished: StatusSnapshot?

    init(
        endpoint: DashboardEndpoint = .configured(),
        transport: DashboardTransport = URLSessionDashboardTransport(),
        timings: Timings = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        (updates, updatesContinuation) = AsyncStream.makeStream(of: StatusSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        self.endpoint = endpoint
        self.transport = transport
        self.timings = timings
        self.now = now
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { await self.runUntilCancelled() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        updatesContinuation.finish()
    }

    // MARK: - Actions

    func focus(paneId: String) async -> FocusResult {
        do {
            let (body, _) = try await transport.response(for: endpoint.focusRequest(paneId: paneId))
            let reply = try JSONDecoder().decode(DashboardFocusResponse.self, from: body)
            return reply.ok == true ? .success : .failure(reply.error ?? "The dashboard could not focus that agent.")
        } catch {
            return .failure("Can't reach the status dashboard.")
        }
    }

    func paneScreen(paneId: String) async -> PaneScreenResult {
        do {
            let (body, _) = try await transport.response(for: endpoint.paneScreenRequest(paneId: paneId))
            let reply = try JSONDecoder().decode(DashboardPaneScreenResponse.self, from: body)
            guard reply.ok == true, let lines = reply.lines else {
                return .failure(reply.error ?? "The dashboard could not read that pane.")
            }
            return .screen(lines: lines, readAt: reply.readTs.map(Date.init(timeIntervalSince1970:)) ?? now())
        } catch {
            return .failure("Can't reach the status dashboard.")
        }
    }

    func answer(paneId: String, choice: AnswerChoice, question: QuestionIdentity) async -> AnswerResult {
        do {
            let request = endpoint.answerRequest(paneId: paneId, choice: choice, question: question)
            let (body, _) = try await transport.response(for: request)
            let reply = try JSONDecoder().decode(DashboardAnswerResponse.self, from: body)
            return reply.result ?? .failed("The dashboard sent an unreadable reply. Check the agent's terminal.")
        } catch is DecodingError {
            return .failed("The dashboard sent an unreadable reply. Check the agent's terminal.")
        } catch let error as URLError where error.code == .timedOut {
            // The answer may have gone through: never say it did not.
            return .failed("The dashboard took too long to answer. Check the agent's terminal: the answer may have gone through.")
        } catch {
            return .failed("Can't reach the status dashboard.")
        }
    }

    func permission(paneId: String, choice: PermissionChoice, permission: PermissionPrompt) async -> PermissionResult {
        await permissionResult(for: endpoint.permissionRequest(paneId: paneId, choice: choice, permission: permission))
    }

    func selectPlanOption(paneId: String, index: Int, text: String?, permission: PermissionPrompt) async -> PermissionResult {
        await permissionResult(for: endpoint.planSelectRequest(paneId: paneId, index: index, text: text, permission: permission))
    }

    private func permissionResult(for request: URLRequest) async -> PermissionResult {
        do {
            let (body, statusCode) = try await transport.response(for: request)
            return DashboardPermissionResponse.result(body: body, statusCode: statusCode)
        } catch let error as URLError where error.code == .timedOut {
            // The key may have been pressed: never say it was not.
            return .failed("The dashboard took too long to answer. Check the agent's terminal: the decision may have gone through.")
        } catch {
            return .failed("Can't reach the status dashboard.")
        }
    }

    func answerHookRequest(requestId: String, answer: HookAnswer) async -> HookAnswerOutcome {
        guard let request = endpoint.hookAnswerRequest(requestId: requestId, answer: answer) else {
            return .failed("The dashboard gave this prompt an id AgentBar can't address.")
        }
        do {
            let (body, statusCode) = try await transport.response(for: request)
            return DashboardHookAnswerResponse.outcome(body: body, statusCode: statusCode)
        } catch let error as URLError where error.code == .timedOut {
            return .failed("The dashboard took too long to answer. Check the session in Claude: the answer may have gone through.")
        } catch {
            return .failed("Can't reach the status dashboard.")
        }
    }

    func perform(_ kind: SessionActionKind, rowId: String, confirmed: Bool) async -> SessionActionOutcome {
        do {
            let request = endpoint.sessionActionRequest(kind, rowId: rowId, confirmed: confirmed)
            let (body, _) = try await transport.response(for: request)
            let reply = try JSONDecoder().decode(DashboardSessionActionResponse.self, from: body)
            return reply.outcome ?? .failed("The dashboard refused to \(kind.verb) that agent.")
        } catch is DecodingError {
            return .failed("The dashboard sent an unreadable reply. Check whether the \(kind.verb) worked.")
        } catch let error as URLError where error.code == .timedOut {
            // The request may have gone through: never say it did not.
            return .failed("The dashboard took too long to answer. Check whether the \(kind.verb) worked.")
        } catch {
            return .failed("Can't reach the status dashboard.")
        }
    }

    func sendMessage(rowId: String, text: String, confirmed: Bool) async -> MessageSendOutcome {
        await sendMessage(rowId: rowId, text: text, confirmed: confirmed, attachments: [])
    }

    func uploadImage(_ image: MessageImage) async -> Result<String, ImageUploadFailure> {
        do {
            let (body, statusCode) = try await transport.response(for: endpoint.imageUploadRequest(image))
            let reply = try? JSONDecoder().decode(DashboardImageUploadResponse.self, from: body)
            if statusCode == 404 { return .failure(ImageUploadFailure(reason: "This dashboard can't take images yet (restart it).")) }
            if let id = reply?.id, reply?.ok == true { return .success(id) }
            return .failure(ImageUploadFailure(reason: reply?.error ?? "The dashboard refused the image."))
        } catch {
            return .failure(ImageUploadFailure(reason: "Can't reach the status dashboard to upload the image."))
        }
    }

    func sendMessage(rowId: String, text: String, confirmed: Bool, attachments: [String]) async -> MessageSendOutcome {
        do {
            let request = endpoint.messageRequest(rowId: rowId, text: text, confirmed: confirmed, attachments: attachments)
            let (body, _) = try await transport.response(for: request)
            let reply = try JSONDecoder().decode(DashboardSessionActionResponse.self, from: body)
            return reply.messageOutcome ?? .failed("The dashboard refused the message.")
        } catch is DecodingError {
            return .uncertain("The dashboard sent an unreadable reply. Check the agent's terminal: the message may have gone through.")
        } catch let error as URLError where error.code == .timedOut {
            return .uncertain("The dashboard took too long to answer. Check the agent's terminal: the message may have gone through.")
        } catch {
            return .failed("Can't reach the status dashboard. Nothing was sent.")
        }
    }

    /// `GET /api/personas`. Nil on anything but a clean 2xx + decode — a slow/dead dashboard reads
    /// exactly like "no personas offered", so `AgentPanelModel.startRouting` falls back to
    /// sessions only, silently (no footer notice: this runs on every routing start, not a
    /// user-initiated action).
    func fetchPersonas() async -> [Persona]? {
        do {
            let (body, statusCode) = try await transport.response(for: endpoint.personasRequest)
            guard (200..<300).contains(statusCode) else { return nil }
            return try? JSONDecoder().decode([Persona].self, from: body)
        } catch {
            return nil
        }
    }

    /// `POST /api/persona/start`. Every failure — unreadable reply, timeout, unreachable dashboard
    /// — becomes `.failed`, never `.uncertain`: the spec calls for showing the error and never
    /// auto-retrying, with no "it may have gone through" framing (unlike `sendMessage`, this isn't
    /// a plain retry-safe pane write; the caller decides what to do next, if anything).
    func startPersona(_ name: String, text: String, fresh: Bool, machine: String?) async -> PersonaStartOutcome {
        do {
            let request = endpoint.personaStartRequest(persona: name, text: text, fresh: fresh, machine: machine)
            let (body, statusCode) = try await transport.response(for: request)
            // A dashboard without the endpoint answers a bare `{"error": "not found"}` 404.
            if statusCode == 404 { return .failed(DashboardPersonaStartResponse.endpointMissingMessage) }
            let reply = try JSONDecoder().decode(DashboardPersonaStartResponse.self, from: body)
            return reply.outcome ?? .failed("The dashboard sent an unreadable reply. Check whether \(name) started.")
        } catch is DecodingError {
            return .failed("The dashboard sent an unreadable reply. Check whether \(name) started.")
        } catch let error as URLError where error.code == .timedOut {
            return .failed("The dashboard took too long to answer. Check whether \(name) started.")
        } catch {
            return .failed("Can't reach the status dashboard.")
        }
    }

    func attachToTree(child: String, parent: String, confirmCrossProject: Bool) async -> AttachOutcome {
        do {
            let request = endpoint.agentTreeAttachRequest(child: child, parent: parent, confirmCrossProject: confirmCrossProject)
            let (body, _) = try await transport.response(for: request)
            let reply = try JSONDecoder().decode(DashboardAttachResponse.self, from: body)
            return reply.outcome
        } catch is DecodingError {
            return .failed("The dashboard sent an unreadable reply.")
        } catch let error as URLError where error.code == .timedOut {
            // The attach may have gone through: never say it did not.
            return .failed("The dashboard took too long to answer. Check the tree: it may have gone through.")
        } catch {
            return .failed("Can't reach the status dashboard.")
        }
    }

    func detachFromTree(child: String) async -> DetachOutcome {
        do {
            let (body, _) = try await transport.response(for: endpoint.agentTreeDetachRequest(child: child))
            let reply = try JSONDecoder().decode(DashboardDetachResponse.self, from: body)
            return reply.outcome
        } catch is DecodingError {
            return .failed("The dashboard sent an unreadable reply.")
        } catch let error as URLError where error.code == .timedOut {
            return .failed("The dashboard took too long to answer. Check the tree: it may have gone through.")
        } catch {
            return .failed("Can't reach the status dashboard.")
        }
    }

    // MARK: - Update loop

    private func runUntilCancelled() async {
        var retryPause = timings.initialRetryPauseSeconds
        while !Task.isCancelled {
            let receivedSnapshot = await consumeEventStream()
            if Task.isCancelled { return }
            if receivedSnapshot {
                // Stream dropped after working: reconnect promptly.
                retryPause = timings.initialRetryPauseSeconds
                await sleep(seconds: retryPause)
            } else {
                await pollUntilStreamShouldBeRetried(retryPause: &retryPause)
            }
        }
    }

    /// True if at least one usable snapshot arrived before the stream ended.
    private func consumeEventStream() async -> Bool {
        var parser = ServerSentEventParser()
        var receivedSnapshot = false
        do {
            for try await chunk in transport.stream(for: endpoint.eventsRequest) {
                for eventData in parser.feed(chunk) {
                    if publishSnapshot(fromJSON: Data(eventData.utf8)) { receivedSnapshot = true }
                }
            }
        } catch {
            // Fall through: the caller polls, and reports "down" if that fails too.
        }
        return receivedSnapshot
    }

    private func pollUntilStreamShouldBeRetried(retryPause: inout TimeInterval) async {
        let pollingStartedAt = now()
        repeat {
            if await pollOnce() {
                retryPause = timings.initialRetryPauseSeconds
                await sleep(seconds: timings.pollIntervalSeconds)
            } else {
                await sleep(seconds: retryPause)
                retryPause = min(retryPause * 2, timings.maxRetryPauseSeconds)
            }
        } while !Task.isCancelled && now().timeIntervalSince(pollingStartedAt) < timings.pollFallbackSeconds
    }

    private func pollOnce() async -> Bool {
        do {
            let (body, statusCode) = try await transport.response(for: endpoint.stateRequest)
            guard (200..<300).contains(statusCode) else {
                recordFailure(reason: "The status dashboard answered with an error (HTTP \(statusCode)).")
                return false
            }
            guard publishSnapshot(fromJSON: body) else {
                recordFailure(reason: "The status dashboard sent an unreadable reply.")
                return false
            }
            return true
        } catch {
            recordFailure(reason: "Can't reach the status dashboard at \(endpoint.baseURL.absoluteString).")
            return false
        }
    }

    // MARK: - Publishing

    /// False when `json` is not a dashboard payload.
    private func publishSnapshot(fromJSON json: Data) -> Bool {
        guard let snapshot = try? StatusSnapshotBuilder.snapshot(fromJSON: json, fetchedAt: now()) else { return false }
        failingSince = nil
        publish(snapshot)
        return true
    }

    /// Publishes `.down` only once the failure has lasted `downAfterFailureSeconds`.
    private func recordFailure(reason: String) {
        let failureStart = failingSince ?? now()
        failingSince = failureStart
        guard now().timeIntervalSince(failureStart) >= timings.downAfterFailureSeconds else { return }
        publish(.down(reason: reason, at: now()))
    }

    private func publish(_ snapshot: StatusSnapshot) {
        if snapshot.health.isDown, lastPublished?.health == snapshot.health { return }  // no repeat "down"
        lastPublished = snapshot
        updatesContinuation.yield(snapshot)
    }

    private func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

/// `POST /api/attachments/image` reply.
struct DashboardImageUploadResponse: Decodable {
    let ok: Bool?
    let id: String?
    let error: String?
}
