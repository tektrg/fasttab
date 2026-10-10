/** Puts a transcript after what the user already typed. The draft is never
 *  replaced or trimmed away: only trailing spaces are folded into the one
 *  separating space. */
export function appendTranscript(draft: string, transcript: string): string {
  const spoken = transcript.trim();
  if (!spoken) return draft;
  if (draft.trim() === "") return spoken;
  return `${draft.replace(/\s+$/, "")} ${spoken}`;
}

/** m:ss for the recording timer / countdown. */
export function formatClock(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000));
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
}
