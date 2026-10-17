/** Wrap_up buttons whose answer an agent may want confirmed in Desktop: the
 *  inbox labels every message "from another Claude session", so a consent
 *  action (commit, push, start a session…) may not be taken as the user's
 *  approval. Display hint only — sending is never blocked. Mirrors Swift
 *  `WrapUpQuestion.consentKeywords` (Sources/AgentBar/Status/WrapUpQuestion.swift). */
export const CONSENT_KEYWORDS = [
  // "session" (not "start") covers "start/launch a session" without flagging "Start slice 1".
  "launch", "session", "commit", "push", "merge", "deploy", "release", "approve", "delete",
] as const;

export const CONSENT_NOTE = "May need confirming in Desktop";

export function mayNeedConfirming(action: { label: string; message: string }): boolean {
  const words = `${action.label} ${action.message}`.toLowerCase().split(/[^a-z]+/);
  return words.some((w) => (CONSENT_KEYWORDS as readonly string[]).includes(w));
}
