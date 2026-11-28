/** Chief check-ins — pure model for the per-chief check-in timer the dashboard
 *  server exposes (`GET /api/chief/checkins`, `POST /api/chief/settings`,
 *  server/lib/chief_timer.py). No React, no fetch here: the card
 *  (components/ChiefCheckinsCard.tsx) renders what these return. */

export type CheckInState = "ok" | "due" | "overdue" | "quiet" | "gone" | "no-schedule" | "error";
export type ChiefPace = "rush" | "steady" | "pace-out" | "quiet";
export type CheckInTone = "ok" | "warn" | "danger" | "muted";

export interface ChiefLastWake {
  dueAt: number | null;
  attempts: number;
  result: "sending" | "delivered" | "failed" | "deferred";
  reason: string | null;
  at: number | null;
}

export interface CheckIn {
  chiefKey: string;
  state: CheckInState;
  lastCheckInAt: number | null;
  lastCheckInSource: "transcript" | "pass" | null;
  checkInRunningSince: number | null;
  dueAt: number | null;
  nextDueAt: number | null;
  overdueSec: number;
  pace: ChiefPace;
  sleepCheckins: boolean;
  schedule: string;
  scheduleError: string | null;
  wakeEnabled: boolean;
  lastWake: ChiefLastWake | null;
  evaluatedAt: number;
}

export interface ChiefEntry {
  key: string;
  name: string;
  project: string;
  label: string;
  rowId: string | null;
  desktopSessionId: string;
  briefPath: string | null;
  workerCount: number;
  checkIn: CheckIn | null;
}

export const PACES: { value: ChiefPace; label: string }[] = [
  { value: "rush", label: "Rush" },
  { value: "steady", label: "Steady" },
  { value: "pace-out", label: "Pace out" },
  { value: "quiet", label: "Quiet" },
];

export function paceLabel(pace: ChiefPace | string | null | undefined): string {
  return PACES.find((p) => p.value === pace)?.label ?? "Steady";
}

/** "14:25" today, "Mon 14:25" on any other day (local time). */
export function fmtClock(epochSec: number, nowSec: number): string {
  const d = new Date(epochSec * 1000);
  const now = new Date(nowSec * 1000);
  const hm = `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  const sameDay =
    d.getFullYear() === now.getFullYear() && d.getMonth() === now.getMonth() && d.getDate() === now.getDate();
  return sameDay ? hm : `${d.toLocaleDateString("en-US", { weekday: "short" })} ${hm}`;
}

/** "40m", "1h 20m", "3h", "2d 4h". */
export function fmtDuration(sec: number): string {
  const m = Math.max(0, Math.round(sec / 60));
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return m % 60 ? `${h}h ${m % 60}m` : `${h}h`;
  const d = Math.floor(h / 24);
  return h % 24 ? `${d}d ${h % 24}h` : `${d}d`;
}

export interface CheckInSummary {
  text: string;
  tone: CheckInTone;
}

/** One-line status badge for a chief's check-in timer. */
export function checkInSummary(c: CheckIn | null | undefined, nowSec: number): CheckInSummary {
  if (!c) return { text: "No schedule", tone: "muted" };
  const last = c.lastCheckInAt != null ? `last ${fmtClock(c.lastCheckInAt, nowSec)}` : "no check-in yet";
  switch (c.state) {
    case "gone":
      return { text: "Chief session gone", tone: "muted" };
    case "no-schedule":
      return { text: "No schedule", tone: "muted" };
    case "quiet":
      return { text: "Quiet — no check-ins", tone: "muted" };
    case "error":
      return { text: c.scheduleError ? `Schedule error: ${c.scheduleError}` : "Schedule error", tone: "danger" };
  }
  // ok / due / overdue: a check-in in progress beats the timer.
  if (c.checkInRunningSince != null) {
    return { text: `Running since ${fmtClock(c.checkInRunningSince, nowSec)}`, tone: "ok" };
  }
  if (c.state === "overdue") return { text: `Overdue ${fmtDuration(c.overdueSec)} · ${last}`, tone: "danger" };
  if (c.state === "due") return { text: `Due now · ${last}`, tone: "warn" };
  const next = c.nextDueAt ?? c.dueAt;
  return { text: next != null ? `Next ${fmtClock(next, nowSec)} · ${last}` : `Up to date · ${last}`, tone: "ok" };
}

/** Mantine colour for a tone. */
export function toneColor(tone: CheckInTone): string {
  return tone === "ok" ? "teal" : tone === "warn" ? "yellow" : tone === "danger" ? "red" : "gray";
}

/** Plain-English line for the last automatic wake, or null when none. */
export function lastWakeText(w: ChiefLastWake | null | undefined, nowSec: number): string | null {
  if (!w) return null;
  const when = w.at != null ? ` ${fmtClock(w.at, nowSec)}` : "";
  const why = w.reason ? ` — ${w.reason}` : "";
  return `Last wake${when}: ${w.result}${why}`;
}

export const TRACKED_ONLY_NOTE = "Tracked only — the chief's own schedule wakes it";
