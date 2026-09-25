import Foundation

/// Asks Jev (OpenRouter's `~typesafe/jev-latest` Decisions "choice" primitive) which candidate
/// should receive `text`. Implementations own their own timeout; callers should not add another.
/// `candidates.isEmpty` must return `.none` without a network call.
protocol JevRoutingClient: Sendable {
    func route(text: String, candidates: [RouteCandidate]) async -> RouteOutcome
}
