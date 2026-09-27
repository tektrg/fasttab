import Foundation

// Wire types for the chief dashboard's `GET /api/state` object (also each SSE
// event). Only the fields AgentBar reads are declared; everything else is
// ignored, and every field is optional so a schema drift degrades one value
// instead of failing the whole payload.

struct DashboardPayload: Decodable {
    let serverTimeTs: Double?
    /// The entries of `feeds` that read as feeds. `feeds` is also where a multi-machine dashboard
    /// keeps `machines` / `machinesConfigError`: an entry that is not a feed costs only itself.
    let feeds: [String: DashboardFeed]
    /// Names present in `feeds` whose value could not be read as a feed (null, not an object).
    let unreadableFeedNames: Set<String>
    let agents: [DashboardAgent]
    let needsYou: [DashboardNeedsYou]
    let boardRows: [DashboardBoardRow]?
    /// Claude Desktop sessions with no running process (`computed.sleepingSessions`); empty from
    /// an older dashboard. See `SleepingSessionMapper`.
    let sleepingSessions: [DashboardSleepingSession]
    /// Who-reports-to-whom, when this dashboard computes it. Nil when the key is absent, null, or
    /// unreadable — all three read as "feature unavailable" (`AgentTreeMapper`, `AgentTreeModel`),
    /// never as an error: an older dashboard simply predates this field.
    let agentTree: AgentTreeWirePayload?

    fileprivate enum CodingKeys: String, CodingKey { case serverTimeTs, feeds, computed, board, agentTree }
    private enum ComputedKeys: String, CodingKey { case agents, needsYou, sleepingSessions }
    private enum BoardKeys: String, CodingKey { case rows }

    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: CodingKeys.self)
        serverTimeTs = root.lenient(.serverTimeTs)
        agentTree = root.lenient(.agentTree)
        (feeds, unreadableFeedNames) = Self.readFeeds(root)
        if let computed = try? root.nestedContainer(keyedBy: ComputedKeys.self, forKey: .computed) {
            agents = (computed.lenient(.agents) as LenientArray<DashboardAgent>?)?.elements ?? []
            needsYou = (computed.lenient(.needsYou) as LenientArray<DashboardNeedsYou>?)?.elements ?? []
            sleepingSessions = (computed.lenient(.sleepingSessions) as LenientArray<DashboardSleepingSession>?)?.elements ?? []
        } else {
            agents = []
            needsYou = []
            sleepingSessions = []
        }
        if let board = try? root.nestedContainer(keyedBy: BoardKeys.self, forKey: .board) {
            boardRows = (board.lenient(.rows) as LenientArray<DashboardBoardRow>?)?.elements
        } else {
            boardRows = nil
        }
    }
}

extension DashboardPayload {
    /// Reads `feeds` entry by entry: one odd value (a null, a scalar) never costs the others.
    fileprivate static func readFeeds(_ root: KeyedDecodingContainer<CodingKeys>) -> ([String: DashboardFeed], Set<String>) {
        guard let container = try? root.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .feeds) else { return ([:], []) }
        var feeds: [String: DashboardFeed] = [:]
        var unreadable: Set<String> = []
        for key in container.allKeys {
            if let feed = try? container.decode(DashboardFeed.self, forKey: key) {
                feeds[key.stringValue] = feed
            } else {
                unreadable.insert(key.stringValue)
            }
        }
        return (feeds, unreadable)
    }
}

/// A coding key for objects whose keys are data (feed names), not a fixed set.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
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
    /// "herdr" | "claude-desktop" | "claude-cli"; absent from an older dashboard (= herdr).
    let source: String?
    /// A Claude Desktop row: `claude://code/continue?session=…`.
    let openUrl: String?
    /// A Claude CLI row running in tmux: "session:@w.%p".
    let tmuxTarget: String?
    /// A status-only row's pending hook-bridge prompt (also on its `needsYou` entry).
    let hookRequest: DashboardHookRequest?

    private enum CodingKeys: String, CodingKey {
        case paneId, label, cwd, hookState, hookSinceSec, hasHookData, residue
        case agentSession, hookReason, screenState, screenSignal, screenQuestion, rowId, actions
        case source, openUrl, tmuxTarget, hookRequest
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
        source = container.lenient(.source)
        openUrl = container.lenient(.openUrl)
        tmuxTarget = container.lenient(.tmuxTarget)
        hookRequest = container.lenient(.hookRequest)
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
    /// On a "blocked" row: the plain permission box, once the dashboard has parsed it
    /// (always sent, null when it has not; absent from an older dashboard).
    let permission: DashboardPermission?
    /// A status-only (pane-less) row's Claude session id: how it is matched to its agent row.
    let agentSession: String?
    /// A status-only entry's prompt held by the dashboard's hook bridge (oldest pending one per session).
    let hookRequest: DashboardHookRequest?

    private enum CodingKeys: String, CodingKey {
        case kind, paneId, detail, sinceSec, question, questionPreview, permission, agentSession, hookRequest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = container.lenient(.kind)
        paneId = container.lenient(.paneId)
        detail = container.lenient(.detail)
        sinceSec = container.lenient(.sinceSec)
        question = container.lenient(.question)
        questionPreview = container.lenient(.questionPreview)
        permission = container.lenient(.permission)
        agentSession = container.lenient(.agentSession)
        hookRequest = container.lenient(.hookRequest)
    }
}

/// A parsed permission box (`classify_pane.parse_permission_block`). Also the shape of
/// `next` in a permission reply. Strings are kept exactly as sent: the dashboard compares
/// them verbatim when a decision comes back.
struct DashboardPermission: Decodable {
    let tool: String?
    let detail: String?
    let title: String?
    let options: [Option]
    let cursorIndex: Int?
    /// "plan" on a plan-approval box (Claude's plan mode); absent on a tool-permission box.
    let kind: String?
    /// A plan box: the plan file named in the box's footer, verbatim (`~` unexpanded); null when absent.
    let planPath: String?

    struct Option: Decodable {
        let index: Int?
        let label: String?

        private enum CodingKeys: String, CodingKey { case index, label }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            index = container.lenient(.index)
            label = container.lenient(.label)
        }
    }

    private enum CodingKeys: String, CodingKey { case tool, detail, title, options, cursorIndex, kind, planPath }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tool = container.lenient(.tool)
        detail = container.lenient(.detail)
        title = container.lenient(.title)
        cursorIndex = container.lenient(.cursorIndex)
        kind = container.lenient(.kind)
        planPath = container.lenient(.planPath)
        options = (container.lenient(.options) as LenientArray<Option>?)?.elements ?? []
    }

    /// The prompt this describes; nil unless it is whole (a tool, a detail, a title and two or more numbered options).
    /// A plan box (`kind == "plan"`) has no detail (null): it is whole with a tool, a title and its options.
    var prompt: PermissionPrompt? {
        let isPlan = kind == "plan"
        guard let tool, !tool.isEmpty, let title, !title.isEmpty, let detail = isPlan ? "" : detail else { return nil }
        let parsed = options.compactMap { option -> PermissionPrompt.Option? in
            guard let index = option.index, let label = option.label else { return nil }
            return PermissionPrompt.Option(index: index, label: label)
        }
        guard parsed.count == options.count, parsed.count >= 2 else { return nil }
        return PermissionPrompt(
            tool: tool, detail: detail, title: title, options: parsed, cursorIndex: cursorIndex,
            kind: isPlan ? .plan : .tool, planPath: isPlan ? planPath : nil
        )
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
