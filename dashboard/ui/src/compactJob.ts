import { LOGGED_OUT_ERROR } from "./api";

/** "/compact with a temporary Sonnet switch" — the web side of the shared
 *  contract (dashboard/AGENTS.md "Compact on Sonnet"; Swift AgentBar reads
 *  the same rules). The server runs the job; this file only parses the
 *  draft, calls the three endpoints and words the progress line. */

/** Composer input rule (identical in Swift): the draft's first line, trimmed,
 *  is `/compact` or starts with `/compact ` (case-sensitive). The rest of
 *  line 1 = instructions; lines 2..n = the follow-up message. */
export interface CompactDraft {
  instructions?: string;
  followUp?: string;
}

const LINE_BREAK = /\r\n|\r|\n/;

export function parseCompactDraft(draft: string): CompactDraft | null {
  const [first, ...rest] = draft.split(LINE_BREAK);
  const head = first.trim();
  if (head !== "/compact" && !head.startsWith("/compact ")) return null;
  const out: CompactDraft = {};
  const instructions = head.slice("/compact".length).trim();
  if (instructions) out.instructions = instructions;
  const followUp = rest.join("\n").trim().replace(/\n/g, " ");
  if (followUp) out.followUp = followUp;
  return out;
}

/** A plain multi-line draft goes out as one line: newlines become spaces
 *  (the server refuses newlines — in a terminal they are the submit key). */
export function flattenMessage(draft: string): string {
  return draft.split(LINE_BREAK).join(" ").trim();
}

export type CompactState =
  | "waitingIdle"
  | "switchingModel"
  | "compacting"
  | "restoringModel"
  | "sendingFollowUp"
  | "done"
  | "failed";

export interface CompactJob {
  id: string;
  rowId: string;
  state: CompactState;
  originalModel: string | null;
  switchSkipped: boolean;
  skipReason: string | null;
  compactOk: boolean | null;
  modelRestored: boolean | null;
  followUpSent: boolean | null;
  error: string | null;
  failedStep: string | null;
  createdAt: number;
  updatedAt: number;
}

export function isCompactTerminal(job: CompactJob): boolean {
  return job.state === "done" || job.state === "failed";
}

/** Clients poll GET every ~1.5 s while the job is not terminal (contract).
 *  Mutable so tests can poll fast. */
export const compactPolling = { intervalMs: 1500 };

export interface CompactStartResult {
  ok: boolean;
  status: number;
  job?: CompactJob;
  error?: string;
}

export async function startCompact(rowId: string, draft: CompactDraft): Promise<CompactStartResult> {
  try {
    const r = await fetch("/api/session/compact", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ rowId, actor: "po", ...draft }),
    });
    if (r.status === 401) return { ok: false, status: 401, error: LOGGED_OUT_ERROR };
    const data = (await r.json()) as Partial<CompactStartResult>;
    return { ok: !!data.ok, status: r.status ?? (data.ok ? 202 : 400), job: data.job ?? undefined, error: data.error };
  } catch (e) {
    return { ok: false, status: 0, error: String(e) };
  }
}

function jobOf(data: unknown): CompactJob | null {
  const job = (data as { job?: CompactJob | null } | null)?.job;
  return job && typeof job.id === "string" && typeof job.state === "string" ? job : null;
}

export async function fetchCompactJob(id: string): Promise<CompactJob | null> {
  try {
    const r = await fetch(`/api/session/compact/${encodeURIComponent(id)}`);
    return jobOf(await r.json());
  } catch {
    return null;
  }
}

/** The row's active job, else its newest finished one (< 30 min), else null. */
export async function fetchCompactForRow(rowId: string): Promise<CompactJob | null> {
  try {
    const r = await fetch(`/api/session/compact?rowId=${encodeURIComponent(rowId)}`);
    return jobOf(await r.json());
  } catch {
    return null;
  }
}

/** One plain line for the progress row: waiting for agent → switching to
 *  Sonnet → compacting → restoring model → sending message → done/failed. */
export function describeCompactJob(job: CompactJob): string {
  const model = job.originalModel ?? "the original model";
  switch (job.state) {
    case "waitingIdle":
      return "Compact: waiting for the agent to finish its turn…";
    case "switchingModel":
      return "Compact: switching to Sonnet…";
    case "compacting":
      return job.switchSkipped
        ? `Compact: compacting on ${job.originalModel ?? "the current model"}…`
        : "Compact: compacting on Sonnet…";
    case "restoringModel":
      return `Compact: restoring ${model}…`;
    case "sendingFollowUp":
      return "Compact: sending your message…";
    case "done": {
      const parts = ["Compact done"];
      if (job.switchSkipped && job.skipReason) parts.push(job.skipReason);
      else if (job.modelRestored) parts.push(`back on ${model}`);
      if (job.followUpSent) parts.push("message sent");
      return parts.join(" · ");
    }
    case "failed": {
      const parts = [`Compact failed: ${job.error ?? "unknown error"}`];
      if (job.modelRestored === false) parts.push(`model NOT restored to ${model} — check the session`);
      if (job.followUpSent) parts.push("message sent");
      else if (job.followUpSent === false) parts.push("message NOT sent");
      return parts.join(" · ");
    }
  }
}
