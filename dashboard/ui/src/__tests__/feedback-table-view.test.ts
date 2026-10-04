import { describe, expect, test } from "bun:test";
import { validateSpec } from "@indie/table-core";
import {
  DEFAULT_FEEDBACK_FILTER,
  FEEDBACK_DEFAULT_ROLES,
  detectOwnerFields,
  evaluateFeedback,
  feedbackFields,
  feedbackViewSpec,
  toFeedbackSourceRows,
  type FeedbackThread,
} from "../feedback/feedbackTableView";

const T0 = Date.parse("2026-10-01T00:00:00Z");
function thread(over: Partial<FeedbackThread> & { threadID: string }): FeedbackThread {
  return { app: "parklet", status: "open", lastMessageAt: T0, lastAuthor: "user", lastUserMessage: "hi", ...over };
}

const THREADS = [
  thread({ threadID: "a", lastMessageAt: T0 + 1000, lastUserMessage: "Không đồng bộ được" }),
  thread({ threadID: "b", app: "fasttab", lastMessageAt: T0 + 3000, lastUserMessage: "Crash on launch" }),
  thread({ threadID: "c", lastMessageAt: T0 + 5000, status: "resolved", lastAuthor: "creator" }),
  thread({ threadID: "d", lastMessageAt: T0 + 4000, lastUserMessage: null }),
];

describe("feedback adapter", () => {
  test("row id = thread id; roles map title/status/date", () => {
    const [row] = toFeedbackSourceRows([THREADS[0]]);
    expect(row.id).toBe("a");
    expect(row[FEEDBACK_DEFAULT_ROLES.title!]).toBe("Không đồng bộ được");
    expect(row[FEEDBACK_DEFAULT_ROLES.status!]).toBe("open");
    expect(row[FEEDBACK_DEFAULT_ROLES.date!]).toBe(new Date(T0 + 1000).toISOString());
    expect(row.app).toBe("Parklet");
    expect(row.waitingOnYou).toBe(true);
  });
  test("missing message text gets a placeholder title", () => {
    expect(toFeedbackSourceRows([THREADS[3]])[0].title).toBe("(no message text)");
  });
  test("default spec is valid; app is a select of seen apps", () => {
    const fields = feedbackFields(THREADS);
    expect(validateSpec(feedbackViewSpec(DEFAULT_FEEDBACK_FILTER), fields)).toEqual([]);
    expect(validateSpec(feedbackViewSpec({ status: "resolved", app: "Fast Tab", text: "x" }, "card"), fields)).toEqual([]);
    expect(fields.find((f) => f.id === "app")).toEqual({ id: "app", label: "App", type: "select", options: ["Fast Tab", "Parklet"] });
  });
  test("owner fields appear only when the server sends them", () => {
    expect(detectOwnerFields(THREADS)).toEqual([]);
    expect(feedbackFields(THREADS).some((f) => f.id === "priority")).toBe(false);
    const withOwner = [...THREADS, thread({ threadID: "e", priority: "p1", notes: null })];
    expect(detectOwnerFields(withOwner)).toEqual(["priority", "notes"]);
    const row = toFeedbackSourceRows(withOwner).find((r) => r.id === "e")!;
    expect(row.priority).toBe("p1");
    expect(row.notes).toBeNull();
    expect("direction" in row).toBe(false);
  });
});

describe("feedback default view", () => {
  test("open only, grouped by app, newest first", () => {
    const groups = evaluateFeedback(THREADS, DEFAULT_FEEDBACK_FILTER);
    expect(groups.map((g) => [g.app, g.rows.map((r) => r.id)])).toEqual([
      ["Fast Tab", ["b"]],
      ["Parklet", ["d", "a"]],
    ]);
  });
  test("status and app filters", () => {
    expect(evaluateFeedback(THREADS, { status: "", app: "Parklet", text: "" }).flatMap((g) => g.rows.map((r) => r.id))).toEqual(["c", "d", "a"]);
    expect(evaluateFeedback(THREADS, { status: "resolved", app: "", text: "" }).flatMap((g) => g.rows.map((r) => r.id))).toEqual(["c"]);
  });
  test("text search folds Vietnamese accents and case", () => {
    expect(evaluateFeedback(THREADS, { status: "", app: "", text: "dong bo" }).flatMap((g) => g.rows.map((r) => r.id))).toEqual(["a"]);
    expect(evaluateFeedback(THREADS, { status: "", app: "", text: "CRASH" }).flatMap((g) => g.rows.map((r) => r.id))).toEqual(["b"]);
  });
  test("table and card views agree (desktop/phone parity)", () => {
    for (const filter of [DEFAULT_FEEDBACK_FILTER, { status: "", app: "", text: "" }, { status: "", app: "", text: "o" }]) {
      expect(evaluateFeedback(THREADS, filter, "card")).toEqual(evaluateFeedback(THREADS, filter, "table"));
    }
  });
  test("parity with a hand-written oracle on a shuffled fixture", () => {
    let seed = 7;
    const next = (n: number) => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n; };
    const apps = ["parklet", "fasttab"];
    const fixture = Array.from({ length: 60 }, (_, i) => thread({
      threadID: `t${i}`, app: apps[next(2)], status: next(3) ? "open" : "resolved", lastMessageAt: T0 + next(1000) * 1000 + i,
    }));
    const oracle = ["Fast Tab", "Parklet"].map((app) => [app, fixture
      .filter((t) => t.status === "open" && (t.app === "fasttab" ? "Fast Tab" : "Parklet") === app)
      .sort((x, y) => y.lastMessageAt - x.lastMessageAt).map((t) => t.threadID)]).filter(([, ids]) => ids.length);
    expect(evaluateFeedback(fixture, DEFAULT_FEEDBACK_FILTER).map((g) => [g.app, g.rows.map((r) => r.id)])).toEqual(oracle);
  });
});

describe("QA pass 1", () => {
  test("a thread with no/invalid lastMessageAt does not crash the tab", () => {
    const bad = thread({ threadID: "z", lastMessageAt: undefined as unknown as number });
    expect(() => evaluateFeedback([bad, THREADS[0]], DEFAULT_FEEDBACK_FILTER)).not.toThrow();
  });
  test("Vietnamese search ignores accents and case", () => {
    const ids = evaluateFeedback(THREADS, { ...DEFAULT_FEEDBACK_FILTER, text: "khong dong bo" }).flatMap((g) => g.rows.map((r) => r.id));
    expect(ids).toEqual(["a"]);
  });
  test("resolve guard: second submit while in flight is refused", async () => {
    const { createResolveGuard } = await import("../feedback/feedbackApi");
    const guard = createResolveGuard();
    expect(guard.start("a")).toBe(true);
    expect(guard.start("a")).toBe(false);
    guard.finish("a");
    expect(guard.start("a")).toBe(true);
  });
});
