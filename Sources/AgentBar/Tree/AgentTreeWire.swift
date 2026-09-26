import Foundation

// Wire types for `agentTree` (present on `GET /api/agent-tree` and, with the same shape, as the
// `agentTree` field of `/api/state` and every SSE event). Same lenient style as `DashboardPayload`:
// every field optional, a bad entry costs only itself (`AgentTreeMapper` drops what it can't use).

struct AgentTreeWirePayload: Decodable {
    let generatedAt: String?
    let chiefs: [AgentTreeWireChief]
    let unassigned: [AgentTreeWireAgent]
    let parentGone: [AgentTreeWireAgent]

    private enum CodingKeys: String, CodingKey { case generatedAt, chiefs, unassigned, parentGone }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = container.lenient(.generatedAt)
        chiefs = (container.lenient(.chiefs) as LenientArray<AgentTreeWireChief>?)?.elements ?? []
        unassigned = (container.lenient(.unassigned) as LenientArray<AgentTreeWireAgent>?)?.elements ?? []
        parentGone = (container.lenient(.parentGone) as LenientArray<AgentTreeWireAgent>?)?.elements ?? []
    }
}

/// A worker, in `chiefs[].children`, `unassigned`, or `parentGone`.
struct AgentTreeWireAgent: Decodable {
    let id: String?
    let label: String?
    let project: String?
    let projectRoot: String?
    let machine: String?
    let paneId: String?
    let alive: Bool?
    let status: String?
    let crossProject: Bool?
    /// Present only on a `parentGone` entry.
    let lostParent: AgentTreeWireLostParent?

    private enum CodingKeys: String, CodingKey {
        case id, label, project, projectRoot, machine, paneId, alive, status, crossProject, lostParent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(.id)
        label = container.lenient(.label)
        project = container.lenient(.project)
        projectRoot = container.lenient(.projectRoot)
        machine = container.lenient(.machine)
        paneId = container.lenient(.paneId)
        alive = container.lenient(.alive)
        status = container.lenient(.status)
        crossProject = container.lenient(.crossProject)
        lostParent = container.lenient(.lostParent)
    }
}

struct AgentTreeWireLostParent: Decodable {
    let id: String?
    let label: String?

    private enum CodingKeys: String, CodingKey { case id, label }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(.id)
        label = container.lenient(.label)
    }
}

struct AgentTreeWireChief: Decodable {
    let id: String?
    let label: String?
    let project: String?
    let projectRoot: String?
    let machine: String?
    let paneId: String?
    let alive: Bool?
    let isChiefMode: Bool?
    let status: String?
    let children: [AgentTreeWireAgent]

    private enum CodingKeys: String, CodingKey {
        case id, label, project, projectRoot, machine, paneId, alive, isChiefMode, status, children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lenient(.id)
        label = container.lenient(.label)
        project = container.lenient(.project)
        projectRoot = container.lenient(.projectRoot)
        machine = container.lenient(.machine)
        paneId = container.lenient(.paneId)
        alive = container.lenient(.alive)
        isChiefMode = container.lenient(.isChiefMode)
        status = container.lenient(.status)
        children = (container.lenient(.children) as LenientArray<AgentTreeWireAgent>?)?.elements ?? []
    }
}
