/**
 * The prompt sheet (a Claude Desktop / CLI session waiting outside herdr)
 * shows the agent's last message above the question, as AgentBar's answer
 * card does — and nothing extra when there is no transcript to read.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { PromptSheet } from "../components/phone/PromptSheet";
import { theme } from "../theme";
import type { HookRequest, NeedsYouRow } from "../types";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
  document.body.innerHTML = "";
});

const QUESTION: HookRequest = {
  requestId: "hp1-abc",
  kind: "question",
  toolName: "AskUserQuestion",
  questions: [{
    question: "Which refresh?", header: "Live refresh", multiSelect: false,
    options: [{ label: "Poll", description: "" }, { label: "Push", description: "" }],
  }],
};

function row(extra: Partial<NeedsYouRow> = {}): NeedsYouRow {
  return {
    kind: "blocked", urgency: 1, label: "desk session", paneId: null, detail: "Input needed",
    sinceSec: 30, identity: null, source: "claude-desktop", agentSession: "sess-1",
    hookRequest: QUESTION, machine: "local", ...extra,
  };
}

/** Records every URL fetched; /api/session/latest answers with `latest`. */
function stubLatest(latest: unknown) {
  const urls: string[] = [];
  globalThis.fetch = (async (url: unknown) => {
    urls.push(String(url));
    const reply = String(url).startsWith("/api/session/latest") ? latest : {};
    return { ok: true, status: 200, json: async () => reply } as Response;
  }) as typeof fetch;
  return urls;
}

async function mountSheet(r: NeedsYouRow) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => {
    root.render(
      <MantineProvider theme={theme}>
        <PromptSheet row={r} onClose={() => {}} onToast={() => {}} />
      </MantineProvider>,
    );
  });
  await act(async () => {
    for (let i = 0; i < 6; i++) await Promise.resolve();
  });
  return () => act(() => root.unmount());
}

describe("PromptSheet last message", () => {
  test("shows the session's last message above the question", async () => {
    const urls = stubLatest({ ok: true, rowId: "sess-1", latestMessage: "Board **built** — pick a refresh", pendingQuestion: null });
    const unmount = await mountSheet(row());
    expect(urls).toContain("/api/session/latest?rowId=sess-1");
    const block = document.querySelector(".latest-message");
    expect(block?.textContent).toContain("Board built");
    const text = document.body.textContent ?? "";
    expect(text.indexOf("Board built")).toBeLessThan(text.indexOf("Which refresh?"));
    unmount();
  });

  test("no transcript: nothing extra, the question still shows", async () => {
    stubLatest({ ok: false, error: "row sess-1 has no Claude session transcript" });
    const unmount = await mountSheet(row());
    expect(document.querySelector(".latest-message")).toBe(null);
    expect(document.body.textContent).toContain("Which refresh?");
    unmount();
  });

  test("an OpenCode / Codex prompt reads no Claude transcript", async () => {
    const urls = stubLatest({ ok: true, latestMessage: "should not show", pendingQuestion: null });
    const unmount = await mountSheet(row({ paneId: "w1:p3", hookRequest: { ...QUESTION, tool: "opencode" } }));
    expect(urls.some((u) => u.startsWith("/api/session/latest"))).toBe(false);
    expect(document.querySelector(".latest-message")).toBe(null);
    unmount();
  });
});

// happy-dom does no layout, so pin the rule: the sheet body is a flex column,
// and a scrolling block that may shrink was squashed to one line above a
// long question card (seen live 2026-10-01).
test("the last-message scroll box never shrinks in the sheet's flex column", () => {
  const phoneCss = readFileSync(join(import.meta.dir, "../components/phone/phone.css"), "utf8");
  expect(phoneCss).toMatch(/\.phone-block\.latest-message\s*\{[^}]*flex-shrink:\s*0[^}]*\}/);
});
