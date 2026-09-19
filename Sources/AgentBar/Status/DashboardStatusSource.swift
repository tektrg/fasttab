import Foundation

/// Reads agent status from the chief dashboard: prefers its SSE stream, falls
/// back to polling `/api/state` while the stream is unavailable, and publishes
/// a `.down` snapshot once neither has worked for `Timings.downAfterFailureSeconds`.
actor DashboardStatusSource: AgentStatusSource {
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
