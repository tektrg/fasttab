// Shared STATE badge class (hook-state vocabulary: blocked/working/idle).
export function stClassOf(s: string | null): string {
  if (s === "blocked") return "st-blocked";
  if (s === "working") return "st-working";
  if (s === "idle") return "st-idle";
  return "st-unknown";
}

// Screen-classifier vocabulary (classify_pane states) -> badge class. One
// place, so a new classifier state cannot render unstyled in some tables only.
export function screenClassOf(s: string | null): string {
  if (s === "NEEDS_HUMAN" || s === "CRASHED" || s === "NEEDS_LOGIN") return "st-blocked";
  if (s === "ACTIVE") return "st-working";
  // Turn ended but the worker is waiting on its own monitor/agent: calm, not idle.
  if (s === "WAITING_ON_BACKGROUND") return "st-parked";
  if (s === "WAITING") return "st-idle";
  return "st-unknown";
}
