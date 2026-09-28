import type { AgentRow } from "./types";

/** The only deep link Claude.app is known to accept for an existing session
 *  (server/lib/claude_sessions.py DESKTOP_CONTINUE_URL). */
const DESKTOP_CONTINUE_PREFIX = "claude://code/continue?session=";
/** A phone has no Claude.app for claude:// and the session's own Remote
 *  Control URL isn't recorded anywhere local, so it gets the generic page. */
export const CLAUDE_CODE_WEB_URL = "https://claude.ai/code";

export const INBOX_CAPTION = "Arrives as an agent message — can't approve permissions";

export interface OpenInClaudeLink {
  href: string;
  label: string;
  title: string;
}

export function isPhoneUserAgent(userAgent: string): boolean {
  return /iPhone|iPad|iPod|Android/i.test(userAgent);
}

/** "Open in Claude" for a Claude Desktop row: its claude:// link on a Mac
 *  browser, the generic claude.ai/code page on a phone. null for any other
 *  row (herdr panes, CLI sessions, a link that isn't Claude's own shape). */
export function openInClaudeLink(
  row: Pick<AgentRow, "openUrl"> | null | undefined,
  userAgent: string,
): OpenInClaudeLink | null {
  const url = row?.openUrl;
  if (!url || !url.startsWith(DESKTOP_CONTINUE_PREFIX)) return null;
  if (isPhoneUserAgent(userAgent)) {
    return {
      href: CLAUDE_CODE_WEB_URL,
      label: "Open claude.ai/code",
      title: "Opens Claude Code on the web — find this session there (no direct link to it from a phone)",
    };
  }
  return { href: url, label: "Open in Claude", title: "Opens this session in the Claude app on this Mac" };
}

export const WAKE_CAPTION = "Asleep — sending wakes it in Claude on the Mac first";

/** True when a message to this row goes through the session inbox — a live
 *  one, or a sleeping Claude Desktop session the server wakes first ("wake"). */
export function messagesViaInbox(row: Pick<AgentRow, "messageVia" | "paneId"> | null | undefined): boolean {
  return !row?.paneId && (row?.messageVia === "inbox" || row?.messageVia === "wake");
}

/** An ENDED row that is a sleeping Claude Desktop session: messageable,
 *  the server wakes it first (server/lib/desktop_wake.py). */
export function wakesToMessage(row: { status?: string; derived?: Pick<AgentRow, "messageVia" | "paneId"> } | null | undefined): boolean {
  return row?.status === "ended" && !row.derived?.paneId && row.derived?.messageVia === "wake";
}
