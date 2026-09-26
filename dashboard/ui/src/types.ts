// Mirror of GET /api/state from scripts/chief-dashboard-server.py.
// Computed fields come from the pure view module; board fields come from the
// local custom-column store.

export interface FeedSnapshot {
  name: string;
  refreshIntervalSec: number;
  lastSuccessTs: number | null;
  lastAttemptTs: number | null;
  lastDurationSec: number | null;
  ageSec: number | null;
  broken: boolean;
  warming: boolean;
  error: string | null;
  data: unknown;
}

export type FeedName =
  | "hookCache"
  | "herdr"
  | "paneScreen"
  | "paneTick"
  | "board";

export const FEED_ORDER: FeedName[] = [
  "hookCache",
  "herdr",
  "paneScreen",
  "paneTick",
  "board",
];

export interface QuestionOption {
  index: number;
  label: string;
  /** Screen-scraped indented line(s) under the option, or hook-tool-input
   *  description. May be absent on older payloads. */
  desc?: string;
  /** Hook-preview copy uses this name for the same text. */
  description?: string;
  checked: boolean;
  other: boolean;
}

export interface PickerQuestion {
  title: string;
  question: string;
  multi: boolean;
  options: QuestionOption[];
  cursorIndex: number | null;
  otherIndex: number | null;
  hasSubmit: boolean;
  /** Claude's last prose above the picker box, for answer context. */
  context?: string;
}

export interface QuestionPreview {
  title: string;
  question: string;
  multi: boolean;
  options: { index: number; label: string; description?: string }[];
}

/** A pane STOPPED, waiting for a keystroke — nothing else reaches this list.
 *  `blocked` = permission prompt · `question` = AskUserQuestion picker ·
 *  `feed-broken` = the list cannot see and says so. */
export type NeedsYouKind = "blocked" | "question" | "feed-broken";

export interface NeedsYouRow {
  kind: NeedsYouKind;
  urgency: number;
  label: string;
  paneId: string | null;
  detail: string;
  sinceSec: number | null;
  identity: unknown;
  question?: PickerQuestion | null;
  // Phase 5: the hook's display-only copy of a just-opened picker (raw tool
  // input, never screen-parsed). Rendered as text with NO Confirm button —
  // the sweep's parsed `question` replaces it within one interval and stays
  // the only answerable one.
  questionPreview?: QuestionPreview | null;
}

export interface AgentRow {
  rowId?: string;
  paneId: string | null;
  paneIdSanitized: string | null;
  tabId?: string | null;
  workspaceId?: string | null;
  label: string;
  cwd: string | null;
  focused: boolean;
  hookState: string | null;
  hookSinceSec: number | null;
  hookReason?: string | null;
  herdrStatus: string | null;
  disagree: boolean;
  hasHookData: boolean;
  // Parked on its own monitor/agent for longer than the 2h ceiling: the row
  // stops reading as working. Server-computed; absent on older payloads.
  backgroundWaitExpired?: boolean;
  residue?: boolean;
  agentSession?: string | null;
  // Phase 2 (remote herdr): "local" or a configured remote machine name
  // (e.g. "air-m1"). Absent on very old cached payloads — render as local.
  machine?: string;
  // Set only on the SECOND (and later) row sharing an agentSession UUID
  // across machines — names the session id it duplicates. Both rows are
  // kept and shown; this is a flag, never a merge (R6).
  duplicateOfSession?: string | null;
  screenState: string | null;
  screenSignal?: string | null;
  screenQuestion?: PickerQuestion | null;
  // Phase 5/6: server-enriched on /api/state (and copied onto live board
  // rows). Optional — older payloads and stub agents omit them.
  memoryBytes?: number | null;
  actions?: Record<string, SessionActionState>;
  // Phase 8: % of the context window in use, parsed off the pane's status
  // line (null = unreadable, renders —). autocompactPct is the rare
  // "N% until auto-compact" countdown — a badge, not a column.
  contextPct?: number | null;
  autocompactPct?: number | null;
}

export type PropertyType =
  | "text"
  | "select"
  | "multi_select"
  | "number"
  | "checkbox"
  | "date";

export interface PropertyOption {
  id: string;
  name: string;
  color: string;
}

export interface BoardProperty {
  id: string;
  rowKind: string;
  name: string;
  type: PropertyType;
  options: PropertyOption[];
  source: "derived" | "stored";
  editable: boolean;
  position: number;
  width?: number | null;
}

export type BoardValue = string | number | boolean | string[] | null;

export interface BoardRow {
  rowKind: string;
  rowId: string;
  status?: "live" | "ended" | "active";
  endedTs?: number | null;
  derived: AgentRow;
  values: Record<string, BoardValue>;
  // Present on rows whose entity carries resolved links (work items).
  // Generic presence marker — renderers key off this, never off rowKind.
  links?: WorkItemLinks;
  // Phase 5/6: server-resolved ladder + archive entries, carried on live
  // rows (copied from the agents feed, never recomputed) and ended rows
  // (assessed from the pane feed). The UI renders them, never decides.
  actions?: Record<string, SessionActionState>;
  // Phase 6: board-only archive flag (hidden by default, never deleted).
  archived?: boolean;
  // Phase 8/9: carried top-level on live rows (see _annotate_live_rows —
  // the table reads /api/board, and Proof 2 checks these fields there).
  // Null = unreadable, renders —, never 0.
  contextPct?: number | null;
  autocompactPct?: number | null;
  // Lingering suffix, e.g. "ended · stopped by you".
  endedNote?: string;
}

export interface SessionActionState {
  enabled: boolean;
  needsConfirm: boolean;
  reason: string;
}

export interface WorkItemLinkTarget {
  id?: string;
  name?: string;
  label?: string;
  status?: string;
  source: "manual" | "authoritative" | "heuristic";
}

export interface WorkItemLinks {
  sessions: WorkItemLinkTarget[];
  branch: WorkItemLinkTarget | null;
  worktree: WorkItemLinkTarget | null;
}

export interface BoardState {
  rowKind: string;
  properties: BoardProperty[];
  rows: BoardRow[];
  view?: BoardView;
  groups?: BoardGroups;
  error?: string;
  feed?: {
    broken: boolean;
    warming: boolean;
    error: string | null;
    ageSec: number | null;
  };
}

export interface BoardGroup {
  key: string;
  rowIds: string[];
}

export interface BoardGroups {
  propertyId: string;
  editable: boolean;
  source: string;
  groups: BoardGroup[];
}

export type ViewLayout = "table" | "kanban";

export interface ViewColumn {
  propertyId: string;
  hidden: boolean;
  width?: number | null;
  /** Wrap long text onto multiple lines instead of one scrolling line. */
  wrap?: boolean | null;
  /** Pin the column to the left edge while scrolling sideways. */
  sticky?: boolean | null;
}

export interface ViewSort {
  propertyId: string;
  dir: "asc" | "desc";
}

export interface ViewFilter {
  propertyId: string;
  op: "is" | "is not" | "contains" | "is empty" | "is not empty" | ">" | "<";
  value?: unknown;
}

export interface BoardView {
  id: string;
  rowKind: string;
  name: string;
  layout: ViewLayout;
  columns: ViewColumn[];
  sort: ViewSort[];
  filters: ViewFilter[];
  groupBy: string | null;
  /** Kanban column sequence pins group keys; null = server order. */
  groupOrder?: string[] | null;
  position: number;
  createdTs: number;
  updatedTs: number;
}

export interface FullState {
  serverTimeTs: number;
  // Record<FeedName, ...> covers the named feeds; `machines` (per-machine
  // status summary, not a FeedSnapshot) and `machinesConfigError` (null when
  // there's no error — always present, so a broken dashboard-machines.json
  // is never indistinguishable from "no config file") ride alongside them.
  feeds: Record<FeedName, FeedSnapshot> & {
    machinesConfigError?: string | null;
  };
  computed: {
    needsYou: NeedsYouRow[];
    agents: AgentRow[];
    disagreementCount: number;
    residueCount: number;
  };
  board?: BoardState;
}

/** One entry in a row's reach history (GET /api/session/history). Covers
 *  both conversation (`message`) and the ladder verbs — the panel renders
 *  ladder entries as subordinate context, never as conversation. */
export type SessionHistoryAction =
  | "message"
  | "compact"
  | "stop"
  | "close"
  | "relaunch"
  | "archive"
  | "unarchive";

/** `queued` is a SUCCESS that lands when the worker's turn ends — never an
 *  invitation to re-send (that double-sends). `failed` never arrived. */
export type SessionHistoryStatus = "sent" | "queued" | "failed";

export interface SessionHistoryEntry {
  id: number;
  action: SessionHistoryAction;
  /** Unix seconds. */
  ts: number;
  actor: string;
  /** Null for ladder actions, which carry no body. */
  text: string | null;
  status: SessionHistoryStatus;
  reason?: string;
  /** The text is an 80-char stub recovered from before full text was
   *  stored — the UI must say so rather than pass a fragment off as the
   *  whole message. */
  truncated?: boolean;
}

export interface SessionHistoryResponse {
  ok: boolean;
  rowId?: string;
  entries?: SessionHistoryEntry[];
  error?: string;
}

/** GET /api/pane/screen — a SNAPSHOT, never a tail. The read costs ~2.5s
 *  server-side, so it is fired on demand only (open / Refresh). */
export interface PaneScreenResponse {
  ok: boolean;
  paneId?: string;
  lines?: string[];
  /** Unix seconds the pane was actually read. */
  readTs?: number;
  error?: string;
}

export type SelectChoice = { type: "select"; indices: number[] };
export type TextChoice = { type: "text"; value: string };
export type AnswerChoice = SelectChoice | TextChoice;
