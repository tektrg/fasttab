/** Pure logic behind the phone shell (tabs, Inbox, Agents) — no React/DOM, so
 *  counts, filters, grouping and empty-state copy are unit-tested directly. */
import type { BoardRow, NeedsYouRow, SleepingSession } from "../../types";
import { rowLabel } from "../../sessionActions";
import type { UiStatus } from "../../ui/status";
import type { SearchableAgent } from "../../agentMatch";
import { folderBasename, type FolderGroupable } from "./folderGrouping";

export type PhoneTab = "inbox" | "agents" | "settings";

// ── Inbox ────────────────────────────────────────────────────────────────

const NEEDSYOU_RANK: Record<NeedsYouRow["kind"], number> = { blocked: 0, question: 1, "feed-broken": 2 };

/** Blocked first (a permission prompt can't wait), then questions, then feed
 *  outage notices. Stable otherwise. */
export function sortNeedsYou(rows: NeedsYouRow[]): NeedsYouRow[] {
  return [...rows].sort((a, b) => NEEDSYOU_RANK[a.kind] - NEEDSYOU_RANK[b.kind]);
}

export interface InboxGroups {
  questions: NeedsYouRow[];
  blocked: NeedsYouRow[];
  /** Feed outage notices: shown, but not an agent waiting on you. */
  feed: NeedsYouRow[];
}

export function groupInbox(rows: NeedsYouRow[]): InboxGroups {
  const sorted = sortNeedsYou(rows);
  return {
    questions: sorted.filter((n) => n.kind === "question"),
    blocked: sorted.filter((n) => n.kind === "blocked"),
    feed: sorted.filter((n) => n.kind === "feed-broken"),
  };
}

/** Inbox tab badge: agents waiting on you = blocked + questions. */
export function inboxBadgeCount(rows: NeedsYouRow[]): number {
  return rows.filter((n) => n.kind === "blocked" || n.kind === "question").length;
}

export function emptyInboxText(workingCount: number): string {
  if (workingCount <= 0) return "Nothing needs you.";
  return `Nothing needs you. ${workingCount} ${workingCount === 1 ? "agent" : "agents"} working.`;
}

export function needsYouUiStatus(kind: NeedsYouRow["kind"]): UiStatus {
  return kind === "blocked" ? "need" : kind === "question" ? "ask" : "warn";
}

export function needsYouSearchable(n: NeedsYouRow): SearchableAgent {
  return { name: n.label, machine: n.machine || "local", status: n.detail, latestLine: n.detail };
}

export function initialsOf(name: string): string {
  const words = name.split(/[^A-Za-z0-9]+/).filter(Boolean);
  if (words.length >= 2) return (words[0][0] + words[1][0]).toUpperCase();
  return (words[0] ?? name).slice(0, 2).toUpperCase() || "?";
}

// ── Agents ───────────────────────────────────────────────────────────────

export type Bucket = "working" | "parked" | "ended" | "sleeping";
export type AgentFilter = "all" | "working" | "parked" | "sleeping" | "folder";

export interface PhoneAgent extends FolderGroupable {
  /** Board row behind it; null for a sleeping session the board doesn't list. */
  row: BoardRow | null;
  sleeping: SleepingSession | null;
  name: string;
  subtitle: string;
  ageSec: number | null;
  bucket: Bucket;
  ui: UiStatus;
}

const BUCKET_UI: Record<Bucket, UiStatus> = { working: "run", parked: "park", ended: "end", sleeping: "sleep" };

function rowStatusText(row: BoardRow): string {
  const fromValues = row.values["derived:state"];
  if (typeof fromValues === "string" && fromValues) return fromValues;
  return row.derived.screenState || row.derived.hookState || "—";
}

export function agentSearchable(a: PhoneAgent): SearchableAgent {
  return {
    name: a.name,
    machine: a.machine,
    project: a.cwd,
    status: a.bucket,
    latestLine: a.subtitle,
  };
}

/** Board rows + sleeping sessions -> the Agents tab's rows. A pane already
 *  shown in the Inbox (`needsYouPanes`) is left out. An ended board row that
 *  is a sleeping Desktop session (same Claude session id) becomes ONE
 *  sleeping row that still opens the sheet (it can be woken by a message). */
export function buildAgents(
  rows: BoardRow[],
  needsYouPanes: ReadonlySet<string>,
  sleeping: SleepingSession[],
  nowTs: number,
): PhoneAgent[] {
  const sleepingByRowId = new Map<string, SleepingSession>();
  for (const s of sleeping) if (s.cliSessionId) sleepingByRowId.set(s.cliSessionId, s);
  const used = new Set<string>();
  const out: PhoneAgent[] = [];

  for (const r of rows) {
    if (needsYouPanes.has(r.derived.paneId ?? "")) continue;
    const ended = r.status === "ended";
    const asleep = ended ? sleepingByRowId.get(r.rowId) ?? null : null;
    if (asleep) used.add(r.rowId);
    const bucket: Bucket = asleep ? "sleeping" : ended ? "ended" : r.archived ? "parked" : "working";
    const line = String(r.values["derived:lastline"] ?? "").trim();
    const machine = r.derived.machine || "local";
    const text = ended ? r.endedNote || "ended" : line || rowStatusText(r);
    out.push({
      row: r,
      sleeping: asleep,
      rowId: r.rowId,
      name: rowLabel(r),
      subtitle: machine !== "local" ? `${machine} · ${text}` : text,
      ageSec: asleep ? Math.max(0, nowTs - asleep.lastActiveTs) : r.derived.hookSinceSec ?? null,
      cwd: r.derived.cwd ?? null,
      machine,
      needsYouKind: null,
      bucket,
      ui: BUCKET_UI[bucket],
    });
  }
  for (const s of sleeping) {
    if (s.cliSessionId && used.has(s.cliSessionId)) continue;
    out.push({
      row: null,
      sleeping: s,
      rowId: s.cliSessionId ?? s.desktopSessionId,
      name: s.label,
      subtitle: s.cwd ? `Desktop · ${folderBasename(s.cwd)}` : "Desktop",
      ageSec: Math.max(0, nowTs - s.lastActiveTs),
      cwd: s.cwd,
      machine: "local",
      needsYouKind: null,
      bucket: "sleeping",
      ui: "sleep",
    });
  }
  return out;
}

export interface FilterCounts {
  all: number;
  working: number;
  parked: number;
  sleeping: number;
}

export function filterCounts(agents: PhoneAgent[]): FilterCounts {
  const n = (b: Bucket) => agents.filter((a) => a.bucket === b).length;
  return { all: agents.length, working: n("working"), parked: n("parked"), sleeping: n("sleeping") };
}

export interface AgentSection {
  bucket: Bucket;
  title: string;
  rows: PhoneAgent[];
}

const SECTION_ORDER: [Bucket, string][] = [
  ["working", "Working"],
  ["parked", "Parked"],
  ["ended", "Ended"],
  ["sleeping", "Sleeping"],
];

/** Status sections for a filter chip; empty sections are dropped. Folder mode
 *  is grouped elsewhere (`groupByFolder`), so it gets no sections here. */
export function agentSections(agents: PhoneAgent[], filter: AgentFilter): AgentSection[] {
  if (filter === "folder") return [];
  return SECTION_ORDER.filter(([b]) => filter === "all" || filter === b)
    .map(([bucket, title]) => ({ bucket, title, rows: agents.filter((a) => a.bucket === bucket) }))
    .filter((s) => s.rows.length > 0);
}

export function agentsEmptyText(filter: AgentFilter, searching: boolean): string {
  if (searching) return "No agents match.";
  switch (filter) {
    case "working": return "No agents working.";
    case "parked": return "Nothing parked.";
    case "sleeping": return "No sleeping sessions.";
    default: return "No agents yet.";
  }
}

// ── Row sheet ────────────────────────────────────────────────────────────

/** Status badge for the sheet header, from the row alone (the sheet is also
 *  opened from the Agents tab, where no Needs-you entry is at hand). */
export function sheetStatus(row: BoardRow, asleep: boolean): UiStatus {
  if (row.status === "ended") return asleep ? "sleep" : "end";
  if (row.derived.screenPermission) return "need";
  if (row.derived.screenQuestion) return "ask";
  return row.archived ? "park" : "run";
}

export type SheetTab = "activity" | "terminal" | "plan";

/** Tabs the sheet offers: Terminal needs a live pane, Plan only exists while
 *  a plan approval is pending. */
export function sheetTabs(row: BoardRow): SheetTab[] {
  const tabs: SheetTab[] = ["activity"];
  if (row.status !== "ended" && row.derived.paneId) tabs.push("terminal");
  if (hasPendingPlan(row)) tabs.push("plan");
  return tabs;
}

export function hasPendingPlan(row: BoardRow): boolean {
  return row.status !== "ended" && !!row.derived.paneId && row.derived.screenPermission?.kind === "plan";
}

/** A pending plan opens on its own tab: it is the thing waiting on you. */
export function defaultSheetTab(row: BoardRow): SheetTab {
  return hasPendingPlan(row) ? "plan" : "activity";
}

// ── Settings ─────────────────────────────────────────────────────────────

/** Names of the feeds currently broken (the dashboard's own health, not the
 *  phone's network). `machinesConfigError` and friends are not feeds. */
export function brokenFeeds(feeds: Record<string, unknown>): string[] {
  return Object.entries(feeds)
    .filter(([, f]) => !!f && typeof f === "object" && (f as { broken?: boolean }).broken === true)
    .map(([name]) => name);
}
