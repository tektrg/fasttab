/**
 * "/compact with a temporary Sonnet switch" — web side: the shared composer
 * input rule (parseCompactDraft, identical in Swift), plain multi-line
 * flattening, and the Composer's compact flow (POST, poll, progress line,
 * existing job on open). fetch is stubbed per URL; the server's own job
 * logic is covered by dashboard/tests/test_compact_jobs.py.
 */
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { Composer } from "../components/Composer";
import { theme } from "../theme";
import type { BoardRow } from "../types";
import {
  compactHint,
  compactPolling,
  describeCompactJob,
  flattenMessage,
  parseCompactDraft,
  sanitizedMessage,
  type CompactJob,
} from "../compactJob";

/** Same cases as the Swift `CompactDraftTests` (origin/feat/compact-agentbar,
 *  Tests/AgentBarTests/Compact/CompactDraftTests.swift) — one row each. `null`
 *  = not a compact draft; `{}` fields omitted = Swift nil. */
const SWIFT_COMPACT_CASES: [string, string, { instructions?: string; followUp?: string } | null][] = [
  ["bare", "/compact", {}],
  ["instructions", "/compact keep the plan", { instructions: "keep the plan" }],
  ["follow-up", "/compact\nnow run the tests", { followUp: "now run the tests" }],
  ["follow-up after trailing spaces", "/compact   \nnow run the tests", { followUp: "now run the tests" }],
  ["both", "/compact keep the plan\nnow run the tests", { instructions: "keep the plan", followUp: "now run the tests" }],
  ["trimmed everywhere", "   /compact   keep the plan   \n   go on   \n  ", { instructions: "keep the plan", followUp: "go on" }],
  ["padded bare", "  /compact  ", {}],
  ["blank follow-up lines", "/compact\n   \n  ", {}],
  ["multi-line follow-up flattened", "/compact\nfirst line\n\n  second line  \nthird", { followUp: "first line second line third" }],
  ["CRLF", "/compact x\r\na\r\nb", { instructions: "x", followUp: "a b" }],
  ["longer word", "/compactx", null],
  ["/compacting", "/compacting now", null],
  ["longer word + line 2", "/compactx\nhello", null],
  ["later line", "hello\n/compact", null],
  ["blank first line", "\n/compact", null],
  ["empty", "", null],
  ["prose", "please compact", null],
  ["case-sensitive", "/Compact", null],
  ["other command", "/clear", null],
  ["no slash", "compact", null],
];

/** Same cases as the Swift `MessageDraftValidatorTests` sanitizing rows
 *  (`MessageDraftValidator.sanitized` = what a plain message sends). */
const SWIFT_SANITIZED_CASES: [string, string][] = [
  ["  fix the login bug  ", "fix the login bug"],
  ["", ""],
  ["   \n \n\t ", ""],
  ["first\nsecond", "first second"],
  ["first\r\nsecond\rthird", "first second third"],
  ["first  \n\n\n  second\n", "first second"],
  ["a\u2028b", "a b"],
  ["\n/compact\nkeep the plan\n", "/compact keep the plan"],
  ["look at src/main.swift", "look at src/main.swift"],
  // TerminalSafeText: tab -> space, other control characters dropped, NEL is a line break.
  ["a\tb", "a b"],
  ["esc\u001b[2mdim", "esc[2mdim"],
  ["bell\u0007 and del\u007f", "bell and del"],
  ["a\u0085b", "a b"],
  ["  keep  inner  spaces  ", "keep  inner  spaces"],
];

describe("Swift parity (CompactDraft.parse + MessageDraftValidator.sanitized)", () => {
  for (const [name, draft, want] of SWIFT_COMPACT_CASES) {
    test(`parse: ${name}`, () => {
      expect(parseCompactDraft(draft)).toEqual(want);
    });
  }
  for (const [raw, want] of SWIFT_SANITIZED_CASES) {
    test(`sanitized: ${JSON.stringify(raw)}`, () => {
      expect(sanitizedMessage(raw)).toBe(want);
      expect(flattenMessage(raw)).toBe(want);
    });
  }
  test("control characters never reach instructions or follow-up", () => {
    expect(parseCompactDraft("/compact keep\u001b it\nthen\u0003 go")).toEqual({ instructions: "keep it", followUp: "then go" });
  });
  test("the hint says how to add the follow-up (desktop vs phone)", () => {
    expect(compactHint("/compact", false)).toContain("Shift+Enter");
    expect(compactHint("/compact", true)).toContain("↵");
    expect(compactHint("/compact\nthen this", false)).toContain("then sends");
    expect(compactHint("hello", false)).toBeNull();
  });
});

describe("parseCompactDraft (contract composer rule)", () => {
  test("bare /compact", () => {
    expect(parseCompactDraft("/compact")).toEqual({});
    expect(parseCompactDraft("  /compact  ")).toEqual({});
  });
  test("line 1 after /compact = instructions", () => {
    expect(parseCompactDraft("/compact keep the test plan ")).toEqual({ instructions: "keep the test plan" });
  });
  test("lines 2..n = followUp, newlines flattened to spaces", () => {
    expect(parseCompactDraft("/compact\nline one\nline two")).toEqual({ followUp: "line one line two" });
    expect(parseCompactDraft("/compact focus on auth\r\n  then fix the bug  \n")).toEqual({
      instructions: "focus on auth",
      followUp: "then fix the bug",
    });
  });
  test("empty follow-up lines are omitted", () => {
    expect(parseCompactDraft("/compact x\n\n  \n")).toEqual({ instructions: "x" });
  });
  test("anything else is a plain message", () => {
    for (const draft of ["/compactx", "/Compact", "hello /compact", "hi\n/compact", "/clear", ""]) {
      expect(parseCompactDraft(draft)).toBeNull();
    }
  });
  test("plain drafts flatten newlines to spaces", () => {
    expect(flattenMessage("first\nsecond\r\nthird ")).toBe("first second third");
  });
});

function job(over: Partial<CompactJob> = {}): CompactJob {
  return {
    id: "cj-0123456789abcdef",
    rowId: "r1",
    state: "waitingIdle",
    originalModel: "Opus 5.5",
    switchSkipped: false,
    skipReason: null,
    compactOk: null,
    modelRestored: null,
    followUpSent: null,
    error: null,
    failedStep: null,
    createdAt: 1,
    updatedAt: 1,
    followUp: null,
    ...over,
  };
}

describe("describeCompactJob", () => {
  test("one line per step", () => {
    expect(describeCompactJob(job())).toContain("waiting for the agent");
    expect(describeCompactJob(job({ state: "switchingModel" }))).toContain("switching to Sonnet");
    expect(describeCompactJob(job({ state: "compacting" }))).toContain("compacting on Sonnet");
    expect(describeCompactJob(job({ state: "restoringModel" }))).toContain("restoring Opus 5.5");
    expect(describeCompactJob(job({ state: "sendingFollowUp" }))).toContain("sending your message");
    expect(describeCompactJob(job({ state: "done", modelRestored: true, followUpSent: true }))).toBe(
      "Compact done · back on Opus 5.5 · message sent",
    );
  });
  test("skip reason and failures are explicit", () => {
    expect(
      describeCompactJob(job({ state: "compacting", switchSkipped: true, originalModel: "trung/claude-opus-5-5" })),
    ).toContain("compacting on trung/claude-opus-5-5");
    expect(
      describeCompactJob(
        job({ state: "done", switchSkipped: true, skipReason: "custom model: compacting on current model" }),
      ),
    ).toBe("Compact done · custom model: compacting on current model");
    expect(
      describeCompactJob(
        job({ state: "failed", error: "compaction did not finish within 5 min", modelRestored: false, followUpSent: true }),
      ),
    ).toBe(
      "Compact failed: compaction did not finish within 5 min · Model NOT restored: still on Sonnet (switch back to Opus 5.5 with /model) · message sent",
    );
  });
  test("an unsent follow-up is said loudly", () => {
    expect(
      describeCompactJob(job({ state: "failed", error: "dashboard restarted", followUp: "go on", followUpSent: false })),
    ).toBe("Compact failed: dashboard restarted · Your queued message was NOT sent");
  });
});

// ---------------------------------------------------------------- Composer

function boardRow(rowId: string): BoardRow {
  return {
    rowKind: "session",
    rowId,
    status: "live",
    derived: {
      paneId: "w8:pX",
      paneIdSanitized: "w8-pX",
      label: rowId,
      cwd: null,
      focused: false,
      hookState: "idle",
      hookSinceSec: 1,
      herdrStatus: "idle",
      disagree: false,
      hasHookData: true,
      screenState: "WAITING",
    },
    values: { "derived:label": `label-${rowId}` },
  };
}

interface Call {
  url: string;
  method: string;
  body: unknown;
}

const realFetch = globalThis.fetch;
const realInterval = compactPolling.intervalMs;
beforeEach(() => {
  compactPolling.intervalMs = 15;
});
afterEach(() => {
  globalThis.fetch = realFetch;
  compactPolling.intervalMs = realInterval;
});

/** `onRow`: GET ?rowId= answer; `post`: POST compact answer (+status);
 *  `polls`: successive GET /<id> jobs (the last one repeats). */
function stubFetch(opts: { onRow?: CompactJob | null; post?: { status: number; body: unknown }; polls?: CompactJob[] }) {
  const calls: Call[] = [];
  const polls = [...(opts.polls ?? [])];
  globalThis.fetch = (async (url: unknown, init?: { method?: string; body?: string }) => {
    const u = String(url);
    let body: unknown = null;
    try {
      body = init?.body ? JSON.parse(init.body) : null;
    } catch {
      /* not JSON */
    }
    calls.push({ url: u, method: init?.method ?? "GET", body });
    let status = 200;
    let answer: unknown = { ok: true };
    if (u.startsWith("/api/session/compact?rowId=")) answer = { ok: true, job: opts.onRow ?? null };
    else if (u === "/api/session/compact" && init?.method === "POST") {
      status = opts.post?.status ?? 202;
      answer = opts.post?.body ?? { ok: true, job: job() };
    } else if (u.startsWith("/api/session/compact/")) {
      const next = polls.length > 1 ? polls.shift() : polls[0];
      answer = next ? { ok: true, job: next } : { ok: false, error: "unknown job" };
    }
    return { status, json: async () => answer };
  }) as typeof fetch;
  return calls;
}

function mount(rows: BoardRow[], onToast: (msg: string, ok: boolean) => void = () => {}, phone = false) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => {
    root.render(
      <MantineProvider theme={theme}>
        <Composer rows={rows} onToast={onToast} phone={phone} />
      </MantineProvider>,
    );
  });
  return { host, unmount: () => act(() => root.unmount()) };
}

function box(host: HTMLElement) {
  return host.querySelector("textarea") as HTMLTextAreaElement;
}

function typeInto(host: HTMLElement, value: string) {
  const input = box(host);
  act(() => {
    input.focus();
    Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, "value")!.set!.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

async function key(host: HTMLElement, init: KeyboardEventInit) {
  await act(async () => {
    box(host).dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init }));
  });
}

async function settle(ms = 0) {
  await act(async () => {
    await new Promise((r) => setTimeout(r, ms));
  });
}

function progress(host: HTMLElement) {
  return host.querySelector(".composer-compact-progress")?.textContent ?? null;
}

describe("Composer: multi-line + compact", () => {
  test("Shift+Enter never sends; Enter sends a plain draft as one line", async () => {
    const calls = stubFetch({});
    const { host, unmount } = mount([boardRow("r1")]);
    typeInto(host, "first line\nsecond line");
    const shift = new KeyboardEvent("keydown", { key: "Enter", shiftKey: true, bubbles: true, cancelable: true });
    await act(async () => {
      box(host).dispatchEvent(shift);
    });
    expect(shift.defaultPrevented).toBe(false); // the textarea inserts the newline
    expect(calls.filter((c) => c.method === "POST")).toEqual([]);
    await key(host, { key: "Enter" });
    await settle();
    const posts = calls.filter((c) => c.method === "POST");
    expect(posts.map((c) => c.url)).toEqual(["/api/session/message"]);
    expect((posts[0].body as { text: string }).text).toBe("first line second line");
    unmount();
  });

  test("a /compact draft starts a job, polls, and shows each step to done", async () => {
    const calls = stubFetch({
      post: { status: 202, body: { ok: true, job: job() } },
      polls: [
        job({ state: "switchingModel" }),
        job({ state: "compacting" }),
        job({ state: "restoringModel", compactOk: true }),
        job({ state: "sendingFollowUp", compactOk: true, modelRestored: true }),
        job({ state: "done", compactOk: true, modelRestored: true, followUpSent: true }),
      ],
    });
    const { host, unmount } = mount([boardRow("r1")]);
    typeInto(host, "/compact keep the plan\nthen run the tests\nand report");
    await key(host, { key: "Enter" });
    await settle();
    const posts = calls.filter((c) => c.method === "POST");
    expect(posts.map((c) => c.url)).toEqual(["/api/session/compact"]);
    expect(posts[0].body).toEqual({
      rowId: "r1",
      actor: "po",
      instructions: "keep the plan",
      followUp: "then run the tests and report",
    });
    expect(box(host).value).toBe("");
    expect(progress(host)).toContain("waiting for the agent");
    const seen = new Set<string>();
    for (let i = 0; i < 40 && !(progress(host) ?? "").startsWith("Compact done"); i++) {
      await settle(20);
      seen.add(progress(host) ?? "");
    }
    expect([...seen].some((s) => s.includes("switching to Sonnet") || s.includes("compacting"))).toBe(true);
    expect(progress(host)).toBe("Compact done · back on Opus 5.5 · message sent×");
    const pollsBefore = calls.filter((c) => c.url.startsWith("/api/session/compact/")).length;
    await settle(80);
    expect(calls.filter((c) => c.url.startsWith("/api/session/compact/")).length).toBe(pollsBefore); // stopped
    unmount();
  });

  test("a failed job shows the error in red", async () => {
    stubFetch({
      polls: [job({ state: "failed", error: "you typed into the session", failedStep: "compacting", modelRestored: true })],
    });
    const { host, unmount } = mount([boardRow("r1")]);
    typeInto(host, "/compact");
    await key(host, { key: "Enter" });
    for (let i = 0; i < 20 && !(progress(host) ?? "").includes("failed"); i++) await settle(20);
    expect(progress(host)).toContain("Compact failed: you typed into the session");
    expect(host.querySelector(".composer-compact-progress")!.getAttribute("data-state")).toBe("failed");
    unmount();
  });

  test("opening the composer shows the row's running job", async () => {
    const calls = stubFetch({ onRow: job({ state: "compacting" }), polls: [job({ state: "compacting" })] });
    const { host, unmount } = mount([boardRow("r1")]);
    await settle(5);
    expect(calls[0].url).toBe("/api/session/compact?rowId=r1");
    expect(progress(host)).toBe("Compact: compacting on Sonnet…");
    unmount();
  });

  test("409 job-active: says so, shows the running job, and the draft (follow-up too) comes back", async () => {
    const toasts: string[] = [];
    stubFetch({
      post: { status: 409, body: { ok: false, error: "job-active", job: job({ state: "compacting" }) } },
      polls: [job({ state: "compacting" })],
    });
    const { host, unmount } = mount([boardRow("r1")], (t) => toasts.push(t));
    typeInto(host, "/compact keep it\nthen go on");
    await key(host, { key: "Enter" });
    await settle();
    expect(toasts).toContain("a compact is already running for label-r1");
    expect(progress(host)).toContain("compacting");
    expect(box(host).value).toBe("/compact keep it\nthen go on");
    unmount();
  });

  test("a network failure on the POST puts the draft back", async () => {
    const toasts: string[] = [];
    globalThis.fetch = (async () => {
      throw new Error("offline");
    }) as unknown as typeof fetch;
    const { host, unmount } = mount([boardRow("r1")], (t) => toasts.push(t));
    typeInto(host, "/compact\nqueued line");
    await key(host, { key: "Enter" });
    await settle();
    expect(box(host).value).toBe("/compact\nqueued line");
    expect(toasts.some((t) => t.includes("label-r1") && t.includes("offline"))).toBe(true);
    unmount();
  });

  test("a failed job whose follow-up was NOT sent offers to put it back in the draft", async () => {
    stubFetch({
      onRow: job({
        state: "failed",
        error: "dashboard restarted",
        followUp: "carry on with step 3",
        followUpSent: false,
        modelRestored: false,
      }),
    });
    const { host, unmount } = mount([boardRow("r1")]);
    await settle(5);
    expect(progress(host)).toContain("Your queued message was NOT sent");
    expect(progress(host)).toContain("Model NOT restored: still on Sonnet");
    const restore = host.querySelector("[aria-label='put the queued message back in the box']") as HTMLButtonElement;
    expect(restore).not.toBeNull();
    await act(async () => {
      restore.click();
    });
    expect(box(host).value).toBe("carry on with step 3");
    unmount();
  });

  test("phone: a newline button appears for a /compact draft and adds line 2", async () => {
    stubFetch({});
    const { host, unmount } = mount([boardRow("r1")], () => {}, true);
    const newline = () => host.querySelector("[aria-label='new line: message to send after the compact']") as HTMLButtonElement | null;
    typeInto(host, "hello");
    expect(newline()).toBeNull(); // plain drafts: newlines are flattened anyway
    typeInto(host, "/compact");
    expect(newline()).not.toBeNull();
    expect(host.querySelector(".composer-compact-hint")?.textContent).toContain("↵");
    await act(async () => {
      newline()!.click();
    });
    expect(box(host).value).toBe("/compact\n");
    typeInto(host, "/compact\nthen go");
    expect(host.querySelector(".composer-compact-hint")?.textContent).toContain("then sends");
    unmount();
  });

  test("a refusal (400) puts the draft back in the box", async () => {
    const toasts: string[] = [];
    stubFetch({ post: { status: 400, body: { ok: false, error: "row r1 is not a Claude pane" } } });
    const { host, unmount } = mount([boardRow("r1")], (t) => toasts.push(t));
    typeInto(host, "/compact\nfollow up");
    await key(host, { key: "Enter" });
    await settle();
    expect(toasts).toContain("compact refused for label-r1: row r1 is not a Claude pane");
    expect(box(host).value).toBe("/compact\nfollow up");
    expect(progress(host)).toBeNull();
    unmount();
  });
});
