import Foundation

/// Keeps a blocked agent's answerable question steady while the dashboard's
/// view of it flaps. One pane's row can be reported three ways within seconds:
/// the parsed picker (answerable), the hook's early preview with no options yet,
/// and a plain "blocked" row while its screen sweep has not confirmed the picker.
/// Read as-is, the Answer button would come and go. Once a question has been
/// seen answerable it stays that until the agent stops being blocked, or shows
/// a different question; the dashboard still re-checks the pane before typing.
struct BlockerMemory {
    /// How long a "blocked, screen unconfirmed" report may stand in for a question just seen.
    static let unconfirmedGraceSeconds: TimeInterval = 45

    private struct Sighting {
        let question: AnswerableQuestion
        let at: Date
    }

    private var sightings: [String: Sighting] = [:]

    /// `agents` with each blocked agent's blocker steadied. Forgets agents no longer blocked.
    mutating func steadied(_ agents: [AgentSnapshot], now: Date) -> [AgentSnapshot] {
        var remembered: [String: Sighting] = [:]
        let result = agents.map { agent -> AgentSnapshot in
            guard let blocker = agent.blocker else { return agent }
            switch blocker {
            case .question(let question):
                remembered[agent.id] = Sighting(question: question, at: now)
            case .questionLoading(let previewed):
                guard let seen = sightings[agent.id], previewed.map(seen.question.identity.isSameQuestion) ?? true else { break }
                remembered[agent.id] = seen
                return agent.withBlocker(.question(seen.question))
            case .permission:
                guard let seen = sightings[agent.id], now.timeIntervalSince(seen.at) <= Self.unconfirmedGraceSeconds else { break }
                remembered[agent.id] = seen
                return agent.withBlocker(.question(seen.question))
            case .questionNotAnswerable:
                break
            }
            return agent
        }
        sightings = remembered
        return result
    }

    mutating func reset() {
        sightings = [:]
    }
}

extension AgentSnapshot {
    func withBlocker(_ blocker: AgentBlocker?) -> AgentSnapshot {
        var copy = self
        copy.blocker = blocker
        return copy
    }
}
