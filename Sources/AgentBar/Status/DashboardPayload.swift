import Foundation

// Wire types for the chief dashboard's `GET /api/state` object (also each SSE
// event). Only the fields AgentBar reads are declared; everything else is
// ignored, and every field is optional so a schema drift degrades one value
// instead of failing the whole payload.

struct DashboardPayload: Decodable {
    let serverTimeTs: Double?
    let feeds: [String: DashboardFeed]
    let agents: [DashboardAgent]
    let needsYou: [DashboardNeedsYou]
    let boardRows: [DashboardBoardRow]?

    private enum CodingKeys: String, CodingKey { case serverTimeTs, feeds, computed, board }
    private enum ComputedKeys: String, CodingKey { case agents, needsYou }
    private enum BoardKeys: String, CodingKey { case rows }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        serverTimeTs = root.lenient(.serverTimeTs)
        feeds = root.lenient(.feeds) ?? [:]
        if let computed = try? root.nestedContainer(keyedBy: ComputedKeys.self, forKey: .computed) {
            agents = (computed.lenient(.agents) as LenientArray<DashboardAgent>?)?.elements ?? []
            needsYou = (computed.lenient(.needsYou) as LenientArray<DashboardNeedsYou>?)?.elements ?? []
        } else {
            agents = []
            needsYou = []
        }
        if let board = try? root.nestedContainer(keyedBy: BoardKeys.self, forKey: .board) {
            boardRows = (board.lenient(.rows) as LenientArray<DashboardBoardRow>?)?.elements
        } else {
            boardRows = nil
        }
    }
}

struct DashboardFeed: Decodable {
    let refreshIntervalSec: Double?
    let warming: Bool?
    let ageSec: Double?
    let broken: Bool?
    let error: String?

    private enum CodingKeys: String, CodingKey { case refreshIntervalSec, warming, ageSec, broken, error }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        refreshIntervalSec = container.lenient(.refreshIntervalSec)
        warming = container.lenient(.warming)
        ageSec = container.lenient(.ageSec)
        broken = container.lenient(.broken)
        error = container.lenient(.error)
    }
}

/// A parsed AskUserQuestion picker (`classify_pane.parse_question_block`). Also
/// the shape of `next` in an answer reply. Strings are kept exactly as sent:
/// the dashboard compares `title` and `question` verbatim when answering.
struct DashboardQuestion: Decodable {
    let title: String?
    let question: String?
    let multi: Bool?
    let options: [DashboardQuestionOption]
    /// Claude's last prose above the picker: a fallback for "what was I asked".
    let context: String?

    private enum CodingKeys: String, CodingKey { case title, question, multi, options, context }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = container.lenient(.title)
        question = container.lenient(.question)
        multi = container.lenient(.multi)
        context = container.lenient(.context)
        options = (container.lenient(.options) as LenientArray<DashboardQuestionOption>?)?.elements ?? []
    }
}

struct DashboardQuestionOption: Decodable {
    /// The number the picker shows; what a digit key selects.
    let index: Int?
    let label: String?
    let desc: String?
    let checked: Bool?
    /// The free-text row.
    let other: Bool?

    private enum CodingKeys: String, CodingKey { case index, label, desc, checked, other }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = container.lenient(.index)
        label = container.lenient(.label)
        desc = container.lenient(.desc)
        checked = container.lenient(.checked)
        other = container.lenient(.other)
    }
}

struct DashboardAgent: Decodable {
    let paneId: String?
    let label: String?
    let cwd: String?
    let hookState: String?
    let hookSinceSec: Double?
    let hasHookData: Bool?
    let residue: Bool?
    let agentSession: String?
    let hookReason: String?
    let screenState: String?
    let screenSignal: String?
    let screenQuestion: DashboardQuestion?
    let rowId: String?
    let actions: DashboardActions?

    private enum CodingKeys: String, CodingKey {
        case paneId, label, cwd, hookState, hookSinceSec, hasHookData, residue
        case agentSession, hookReason, screenState, screenSignal, screenQuestion, rowId, actions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paneId = container.lenient(.paneId)
        label = container.lenient(.label)
        cwd = container.lenient(.cwd)
        hookState = container.lenient(.hookState)
        hookSinceSec = container.lenient(.hookSinceSec)
        hasHookData = container.lenient(.hasHookData)
        residue = container.lenient(.residue)
        agentSession = container.lenient(.agentSession)
        hookReason = container.lenient(.hookReason)
        screenState = container.lenient(.screenState)
        screenSignal = container.lenient(.screenSignal)
        screenQuestion = container.lenient(.screenQuestion)
        rowId = container.lenient(.rowId)
        actions = container.lenient(.actions)
    }
}

struct DashboardNeedsYou: Decodable {
    /// "question" | "blocked" | "feed-broken" (the last has no pane).
    let kind: String?
    let paneId: String?
    let detail: String?
    let sinceSec: Double?
    /// Present on a "question" row once the screen sweep has parsed the picker;
    /// before that the row carries only a display preview (not decoded here).
    let question: DashboardQuestion?
    /// The hook's early look at a picker (title and question only here), before the sweep has parsed it.
    let questionPreview: DashboardQuestionPreview?

    private enum CodingKeys: String, CodingKey { case kind, paneId, detail, sinceSec, question, questionPreview }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = container.lenient(.kind)
        paneId = container.lenient(.paneId)
        detail = container.lenient(.detail)
        sinceSec = container.lenient(.sinceSec)
        question = container.lenient(.question)
        questionPreview = container.lenient(.questionPreview)
    }
}

/// A "question" row's display-only preview: which question, no options yet.
struct DashboardQuestionPreview: Decodable {
    let title: String?
    let question: String?

    private enum CodingKeys: String, CodingKey { case title, question }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = container.lenient(.title)
        question = container.lenient(.question)
    }

    var identity: QuestionIdentity? {
        guard let title, let question else { return nil }
        return QuestionIdentity(title: title, question: question)
    }
}

struct DashboardBoardRow: Decodable {
    let rowId: String?
    /// "live" | "ended"
    let status: String?
    let archived: Bool?
    let endedTs: Double?
    let endedNote: String?
    let label: String?
    let paneId: String?
    /// `values["derived:push"]`: "" or e.g. "3 ahead — not pushed".
    let pushText: String?
    let cwd: String?
    /// Server-resolved stop/close availability. On an ended row, `close` is
    /// enabled while the pane still exists (the agent was stopped, the pane was not).
    let actions: DashboardActions?

    private enum CodingKeys: String, CodingKey {
        case rowId, status, archived, endedTs, endedNote, derived, values, actions
    }
    private enum DerivedKeys: String, CodingKey { case label, paneId }
    private enum ValueKeys: String, CodingKey {
        case push = "derived:push"
        case cwd = "derived:cwd"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rowId = container.lenient(.rowId)
        status = container.lenient(.status)
        archived = container.lenient(.archived)
        endedTs = container.lenient(.endedTs)
        endedNote = container.lenient(.endedNote)
        actions = container.lenient(.actions)
        if let derived = try? container.nestedContainer(keyedBy: DerivedKeys.self, forKey: .derived) {
            label = derived.lenient(.label)
            paneId = derived.lenient(.paneId)
        } else {
            label = nil
            paneId = nil
        }
        if let values = try? container.nestedContainer(keyedBy: ValueKeys.self, forKey: .values) {
            pushText = values.lenient(.push)
            cwd = values.lenient(.cwd)
        } else {
            pushText = nil
            cwd = nil
        }
    }
}
