import type { HookAnswer, HookRequest } from "./types";

/** Said to Claude with a denial (the server default names AgentBar). */
export const WEB_DENY: HookAnswer = { behavior: "deny", message: "The user denied this from the dashboard web UI." };

/** What an inline Yes/No pair on an Inbox row would send. `null` = no inline
 *  buttons: open the sheet and read the whole prompt first. */
export type QuickAnswerKind =
  | { kind: "yesno"; question: string; yes: string; no: string }
  | { kind: "permission" };

const YES = new Set(["yes", "y", "yes please", "yeah", "yep", "true", "ok", "okay", "approve", "allow", "proceed", "continue", "confirm", "go ahead"]);
const NO = new Set(["no", "n", "nope", "no thanks", "false", "deny", "reject", "cancel", "decline", "stop", "abort"]);

/** The only tools whose permission may be approved without reading it: pure
 *  reads inside the workspace. The inbox row shows just "Permission: <tool>",
 *  never the command, path, diff or MCP arguments, so anything that writes,
 *  runs, fetches, delegates, approves a plan or is MCP/unknown opens the sheet. */
const READ_ONLY_TOOLS = new Set(["Read", "Glob", "Grep", "LS", "NotebookRead"]);

const normalize = (label: string) => label.trim().toLowerCase().replace(/[^a-z ]/g, "").replace(/\s+/g, " ");

/** Pure: is this pending prompt safe to answer with one tap?
 *  - question: exactly ONE single-select question with exactly two options,
 *    one affirmative and one negative (in either order);
 *  - permission: Claude, a read-only tool (allowlist), no "don't ask again"
 *    rule suggestions.
 *  Everything else (multi-question, multi-select, 3+ options, free-form
 *  options, permission with a saved-rule option) returns null. */
export function quickAnswerKind(request: HookRequest | null | undefined): QuickAnswerKind | null {
  if (!request) return null;
  if (request.kind === "permission") {
    const permission = request.permission;
    if (!permission || permission.suggestions.length > 0) return null;
    // OpenCode / Codex tool names and answer semantics differ: sheet only.
    if (request.tool || !READ_ONLY_TOOLS.has(request.toolName ?? "")) return null;
    return { kind: "permission" };
  }
  const questions = request.questions ?? [];
  if (questions.length !== 1) return null;
  const [q] = questions;
  if (q.multiSelect || q.options.length !== 2) return null;
  const [a, b] = q.options.map((o) => normalize(o.label));
  const yesIndex = YES.has(a) && NO.has(b) ? 0 : YES.has(b) && NO.has(a) ? 1 : -1;
  if (yesIndex < 0) return null;
  return {
    kind: "yesno",
    question: q.question,
    yes: q.options[yesIndex].label,
    no: q.options[1 - yesIndex].label,
  };
}

/** The exact body the answer POST carries for a tap. */
export function quickAnswerBody(kind: QuickAnswerKind, choice: "yes" | "no"): HookAnswer {
  if (kind.kind === "permission") return choice === "yes" ? { behavior: "allow" } : WEB_DENY;
  return { behavior: "allow", answers: { [kind.question]: choice === "yes" ? kind.yes : kind.no } };
}

/** Toast text naming what was sent. */
export function quickAnswerToast(kind: QuickAnswerKind, choice: "yes" | "no"): string {
  const label = kind.kind === "permission" ? (choice === "yes" ? "Allowed" : "Denied") : choice === "yes" ? kind.yes : kind.no;
  return kind.kind === "permission" ? `${label} once` : `Answered "${label}"`;
}
