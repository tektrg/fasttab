import Foundation

/// One agent Jev can route a message to: an id it must echo back verbatim, and a short text
/// description of the agent (label/project/status) that becomes its `criteria` entry in the
/// Decisions request. Built from the shown agent rows, never from the raw dashboard payload.
struct RouteCandidate: Equatable, Sendable {
    let agentID: String
    let summary: String
}
