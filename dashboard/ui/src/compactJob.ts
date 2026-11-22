import { LOGGED_OUT_ERROR } from "./api";

/** "/compact with a temporary Sonnet switch" — the web side of the shared
 *  contract (dashboard/AGENTS.md "Compact on Sonnet"; Swift AgentBar reads
 *  the same rules). The server runs the job; this file only parses the
 *  draft, calls the three endpoints and words the progress line. */

/** Composer input rule (identical in Swift): leading blank / whitespace-only
 *  lines are skipped; then the first line, trimmed, is `/compact` or starts
 *  with `/compact ` (case-sensitive). The rest of that line = instructions;
 *  the lines after it = the follow-up message. */
export interface CompactDraft {
  instructions?: string;
  followUp?: string;
}

const COMMAND = "/compact";

// Swift parity (Sources/AgentBar/Message/Compact/CompactDraft.swift,
// MessageDraftValidator.sanitized, TerminalSafeText — branch
// feat/compact-agentbar). Mirror exactly; the tests share the Swift cases.
/** Foundation `CharacterSet.newlines`: LF, VT, FF, CR, NEL, LS, PS. */
const NEWLINES = /[\n\u000B\f\r\u0085\u2028\u2029]/;
/** Foundation `CharacterSet.whitespaces` (Unicode Zs + tab) at either end. */
const EDGE_SPACES = /^[\t\p{Zs}]+|[\t\p{Zs}]+$/gu;

function trimSpaces(s: string): string {
  return s.replace(EDGE_SPACES, "");
}

/** `TerminalSafeText.withoutControlCharacters`: tab -> space; every other
 *  control character (Unicode Cc) dropped unless it is whitespace (the line
 *  breaks LF/VT/FF/CR/NEL stay for the caller to collapse). */
function withoutControlCharacters(s: string): string {
  let out = "";
  for (const ch of s) {
    const cp = ch.codePointAt(0) ?? 0;
    if (cp === 0x09) out += " ";
    else if (cp <= 0x1f || (cp >= 0x7f && cp <= 0x9f)) {
      if ((cp >= 0x0a && cp <= 0x0d) || cp === 0x85) out += ch;
    } else out += ch;
  }
  return out;
}

/** `MessageDraftValidator.sanitized`: the text as it will be sent — control
 *  characters dropped, every line trimmed, blank lines dropped, the rest
 *  joined with one space (the server refuses newlines: in a terminal they
 *  are the submit key). Spaces inside a line are kept. */
export function sanitizedMessage(raw: string): string {
  return withoutControlCharacters(raw)
    .split(NEWLINES)
    .map(trimSpaces)
    .filter((line) => line.length > 0)
    .join(" ");
}

export function parseCompactDraft(draft: string): CompactDraft | null {
  const lines = draft.split(NEWLINES);
  // Leading blank / whitespace-only lines are skipped (Swift does the same).
  while (lines.length > 1 && trimSpaces(lines[0]) === "") lines.shift();
  const [firstLine, ...rest] = lines;
  const first = trimSpaces(firstLine);
  if (first !== COMMAND && !first.startsWith(COMMAND + " ")) return null;
  const out: CompactDraft = {};
  const instructions = sanitizedMessage(first.slice(COMMAND.length));
  if (instructions) out.instructions = instructions;
  const followUp = sanitizedMessage(rest.join("\n"));
  if (followUp) out.followUp = followUp;
  return out;
}

/** A plain multi-line draft goes out as one line (same as Swift's send). */
export function flattenMessage(draft: string): string {
  return sanitizedMessage(draft);
}

/** The line under the box while a `/compact` draft is typed (Swift
 *  `CompactDraft.hint`, worded for the web: Shift+Enter on a keyboard, the
 *  ↵ button on the phone). null for any other draft. */
export function compactHint(draft: string, phone: boolean): string | null {
  const parsed = parseCompactDraft(draft);
  if (!parsed) return null;
  return parsed.followUp === undefined
    ? `Compacts on Sonnet, then restores the model. ${phone ? "↵" : "Shift+Enter"} adds a message to send after.`
    : "Compacts on Sonnet, restores the model, then sends the lines below as one message.";
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
  /** The queued follow-up text (additive 2026-11-22): offered back to the
   *  draft when `followUpSent` is false. Absent on an older dashboard. */
  followUp?: string | null;
  /** The /model picker may be open (additive, QA2 2026-11-22): the server
   *  refuses answers/permissions for the pane only while this is true. */
  inPicker?: boolean;
}

/** The job's follow-up when it exists and did NOT go out (resend offer). */
export function unsentFollowUp(job: CompactJob): string | null {
  return isCompactTerminal(job) && job.followUpSent === false && job.followUp ? job.followUp : null;
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
      if (job.modelRestored === false)
        parts.push(`Model NOT restored: still on Sonnet (switch back to ${model} with /model)`);
      if (job.followUpSent) parts.push("message sent");
      else if (job.followUpSent === false) parts.push("Your queued message was NOT sent");
      return parts.join(" · ");
    }
  }
}
