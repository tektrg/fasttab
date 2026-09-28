import type { AgentRow, BoardRow } from "./types";
import { messagesViaInbox } from "./openInClaude";

/** Which rows the phone lets you message, and which take Compact/Clear.
 *  The server re-checks every send; these only decide what is shown. */

/** A prompt (question picker, permission box, hook-held prompt) is waiting
 *  on the user: free text or a slash command would land in it. */
export function isBlockedOnYou(row: AgentRow): boolean {
  return (
    !!row.hookRequest ||
    !!row.screenQuestion ||
    !!row.screenPermission ||
    row.screenState === "NEEDS_HUMAN" ||
    row.hookState === "blocked"
  );
}

/** Why no message may go to this row (non-Claude pane), else null. */
export function messageRefusal(row: AgentRow): string | null {
  return row.messageRefusal ?? null;
}

/** The caption shown instead of the message box on such a row. */
export function blindAgentCaption(agentKind: string | null | undefined): string {
  const tool = agentKind && agentKind !== "claude" ? agentKind : "this agent";
  return `Messages are off for ${tool}: its prompts are invisible to the dashboard, so a message could answer a question nobody saw. Use its terminal.`;
}

/** There is a route (a pane, or a Desktop/CLI inbox) and the server's
 *  non-Claude gate does not refuse it. */
export function canMessage(row: AgentRow): boolean {
  return (!!row.paneId || messagesViaInbox(row)) && !messageRefusal(row);
}

/** AgentBar's `RowButtons.takesQuickCommands`: a live Claude herdr pane with
 *  hook data (typed into a real terminal, never an inbox), not asking the
 *  user anything. The same gate for Compact and Clear. */
export function takesQuickCommands(row: BoardRow): boolean {
  const d = row.derived;
  return (
    row.status !== "ended" &&
    !!d.paneId &&
    d.messageVia !== "inbox" &&
    d.hasHookData &&
    !messageRefusal(d) &&
    !isBlockedOnYou(d)
  );
}
