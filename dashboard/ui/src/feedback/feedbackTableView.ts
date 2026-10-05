/** Adapter: theindie-api feedback threads -> the shared table engine
 *  (`@tektrg/table-core`). Desktop table and phone list both render the
 *  result of `evaluate()` on the same ViewSpec, so they never disagree.
 *
 *  Row id = thread id (stable). Owner fields (priority/notes/direction) are
 *  not in the API yet: they become fields only when some thread carries them
 *  (feature detection), so the view never shows empty columns for them. */
import { evaluate, type FieldDefinition, type FieldRoleMap, type FilterNode, type GroupNode, type SourceRow, type ViewSpec } from "@tektrg/table-core";

/** One thread as the dashboard proxy returns it (theindie-api `adminThreadJson`). */
export interface FeedbackThread {
  threadID: string;
  app: string;
  status: string;
  signedIn?: boolean;
  shippedInVersion?: string | null;
  lastMessageAt: number;
  lastAuthor?: string;
  createdAt?: number;
  /** Newest user message; present only on servers with `?scope=all` support. */
  lastUserMessage?: string | null;
  /** Proposed owner fields — rendered only when the server sends them. */
  priority?: string | null;
  notes?: string | null;
  direction?: string | null;
}

export const FEEDBACK_STATUSES = ["open", "resolved"] as const;
export const OWNER_FIELD_IDS = ["priority", "direction", "notes"] as const;
type OwnerFieldId = (typeof OWNER_FIELD_IDS)[number];

const APP_LABELS: Record<string, string> = { parklet: "Parklet", fasttab: "Fast Tab", "fast-tab": "Fast Tab" };
const TITLE_MAX_CHARS = 140;
const NO_MESSAGE_TITLE = "(no message text)";

export function appLabel(slug: string): string {
  return APP_LABELS[slug.toLowerCase()] ?? slug;
}

/** Owner fields any thread actually carries (non-undefined). */
export function detectOwnerFields(threads: FeedbackThread[]): OwnerFieldId[] {
  return OWNER_FIELD_IDS.filter((id) => threads.some((thread) => thread[id] !== undefined));
}

export function feedbackFields(threads: FeedbackThread[]): FieldDefinition[] {
  const apps = [...new Set(threads.map((thread) => appLabel(thread.app)))].sort();
  const ownerFields: FieldDefinition[] = detectOwnerFields(threads).map((id) => ({
    id,
    label: id[0].toUpperCase() + id.slice(1),
    type: "text",
  }));
  return [
    { id: "title", label: "Feedback", type: "text" },
    { id: "app", label: "App", type: "select", options: apps },
    { id: "status", label: "Status", type: "select", options: [...FEEDBACK_STATUSES] },
    { id: "lastActivityAt", label: "Last activity", type: "date" },
    { id: "waitingOnYou", label: "Waiting on you", type: "boolean" },
    { id: "shippedInVersion", label: "Shipped in", type: "text" },
    ...ownerFields,
  ];
}

export const FEEDBACK_DEFAULT_ROLES: FieldRoleMap = { title: "title", status: "status", date: "lastActivityAt" };

function threadTitle(thread: FeedbackThread): string {
  const text = (thread.lastUserMessage ?? "").replace(/\s+/g, " ").trim();
  if (!text) return NO_MESSAGE_TITLE;
  return text.length > TITLE_MAX_CHARS ? text.slice(0, TITLE_MAX_CHARS - 1) + "…" : text;
}

export function toFeedbackSourceRows(threads: FeedbackThread[]): SourceRow[] {
  return threads.map((thread) => {
    const row: SourceRow = {
      id: thread.threadID,
      title: threadTitle(thread),
      app: appLabel(thread.app),
      status: thread.status,
      lastActivityAt: Number.isFinite(thread.lastMessageAt) ? new Date(thread.lastMessageAt).toISOString() : null,
      waitingOnYou: thread.status === "open" && thread.lastAuthor === "user",
      shippedInVersion: thread.shippedInVersion ?? null,
    };
    for (const id of OWNER_FIELD_IDS) if (thread[id] !== undefined) row[id] = thread[id] ?? null;
    return row;
  });
}

/** What the user picks in the filter bar. Empty = no constraint. */
export interface FeedbackFilterInput {
  status: string;
  app: string;
  text: string;
}

export const DEFAULT_FEEDBACK_FILTER: FeedbackFilterInput = { status: "open", app: "", text: "" };

/** Default view: "Open, newest first", grouped by app (+ the user's filter). */
export function feedbackViewSpec(filter: FeedbackFilterInput, viewType: ViewSpec["viewType"] = "table"): ViewSpec {
  const conditions: FilterNode[] = [];
  if (filter.status) conditions.push({ kind: "condition", fieldId: "status", operator: "equals", value: filter.status });
  if (filter.app) conditions.push({ kind: "condition", fieldId: "app", operator: "equals", value: filter.app });
  const text = filter.text.trim();
  if (text) {
    conditions.push({ kind: "condition", fieldId: "title", operator: "contains", value: text });
  }
  return {
    specVersion: 1,
    viewType,
    filter: conditions.length ? { kind: "group", combinator: "and", children: conditions } : undefined,
    groupBy: [{ fieldId: "app", direction: "asc", collation: "natural" }],
    sort: [{ fieldId: "lastActivityAt", direction: "desc" }],
  };
}

export interface FeedbackGroup {
  app: string;
  rows: SourceRow[];
}

/** Rows -> app groups in engine order. Throws on an invalid spec (a bug). */
export function evaluateFeedback(threads: FeedbackThread[], filter: FeedbackFilterInput, viewType: ViewSpec["viewType"] = "table"): FeedbackGroup[] {
  const result = evaluate(feedbackViewSpec(filter, viewType), toFeedbackSourceRows(threads), feedbackFields(threads));
  if (!result.ok) throw new Error("feedback view spec invalid: " + JSON.stringify(result.errors));
  return result.groups.map((group: GroupNode) => ({ app: String(group.key ?? ""), rows: group.rows ?? [] }));
}
