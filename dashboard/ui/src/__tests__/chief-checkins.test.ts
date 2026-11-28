import { describe, expect, test } from "bun:test";
import { checkInSummary, fmtClock, fmtDuration, paceLabel, PACES, toneColor, type CheckIn } from "../chiefCheckins";

// Local-time anchors so the HH:MM assertions hold in any timezone.
const at = (y: number, mo: number, d: number, h: number, mi: number) => new Date(y, mo, d, h, mi).getTime() / 1000;
const NOW = at(2026, 10, 28, 15, 5); // Sat 28 Nov 2026 15:05
const T1425 = at(2026, 10, 28, 14, 25);
const T1607 = at(2026, 10, 28, 16, 7);

const ci = (over: Partial<CheckIn> = {}): CheckIn => ({
  chiefKey: "ssv-shared/digital",
  state: "ok",
  lastCheckInAt: T1425,
  lastCheckInSource: "transcript",
  checkInRunningSince: null,
  dueAt: T1607,
  nextDueAt: T1607,
  overdueSec: 0,
  pace: "steady",
  sleepCheckins: false,
  schedule: "every 2h, 08:07-19:59, Mon-Sat",
  scheduleError: null,
  wakeEnabled: false,
  lastWake: null,
  evaluatedAt: NOW,
  ...over,
});

describe("checkInSummary", () => {
  test("ok → next + last", () => {
    expect(checkInSummary(ci(), NOW)).toEqual({ text: "Next 16:07 · last 14:25", tone: "ok" });
  });
  test("ok with no check-in yet", () => {
    expect(checkInSummary(ci({ lastCheckInAt: null }), NOW).text).toBe("Next 16:07 · no check-in yet");
  });
  test("due → warn", () => {
    expect(checkInSummary(ci({ state: "due" }), NOW)).toEqual({ text: "Due now · last 14:25", tone: "warn" });
  });
  test("overdue → danger with duration", () => {
    expect(checkInSummary(ci({ state: "overdue", overdueSec: 2400 }), NOW)).toEqual({
      text: "Overdue 40m · last 14:25",
      tone: "danger",
    });
    expect(checkInSummary(ci({ state: "overdue", overdueSec: 4800 }), NOW).text).toBe("Overdue 1h 20m · last 14:25");
  });
  test("running beats the timer", () => {
    expect(checkInSummary(ci({ state: "overdue", overdueSec: 600, checkInRunningSince: T1425 }), NOW)).toEqual({
      text: "Running since 14:25",
      tone: "ok",
    });
  });
  test("quiet / gone / no-schedule / null are muted", () => {
    expect(checkInSummary(ci({ state: "quiet" }), NOW)).toEqual({ text: "Quiet — no check-ins", tone: "muted" });
    expect(checkInSummary(ci({ state: "gone" }), NOW)).toEqual({ text: "Chief session gone", tone: "muted" });
    expect(checkInSummary(ci({ state: "no-schedule" }), NOW)).toEqual({ text: "No schedule", tone: "muted" });
    expect(checkInSummary(null, NOW)).toEqual({ text: "No schedule", tone: "muted" });
  });
  test("error shows the reason", () => {
    expect(checkInSummary(ci({ state: "error", scheduleError: "bad cron" }), NOW)).toEqual({
      text: "Schedule error: bad cron",
      tone: "danger",
    });
  });
  test("weekday shown when not today", () => {
    const fri = at(2026, 10, 27, 18, 0);
    expect(checkInSummary(ci({ lastCheckInAt: fri }), NOW).text).toBe("Next 16:07 · last Fri 18:00");
  });
});

describe("helpers", () => {
  test("pace labels", () => {
    expect(paceLabel("rush")).toBe("Rush");
    expect(paceLabel("steady")).toBe("Steady");
    expect(paceLabel("pace-out")).toBe("Pace out");
    expect(paceLabel("quiet")).toBe("Quiet");
    expect(PACES.map((p) => p.value)).toEqual(["rush", "steady", "pace-out", "quiet"]);
  });
  test("fmtClock / fmtDuration / toneColor", () => {
    expect(fmtClock(T1425, NOW)).toBe("14:25");
    expect(fmtDuration(59)).toBe("1m");
    expect(fmtDuration(3 * 3600)).toBe("3h");
    expect(fmtDuration(52 * 3600)).toBe("2d 4h");
    expect(toneColor("danger")).toBe("red");
    expect(toneColor("muted")).toBe("gray");
  });
});
