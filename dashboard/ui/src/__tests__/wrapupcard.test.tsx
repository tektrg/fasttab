/**
 * Claude Desktop's end-of-turn question (wrap_up box) on a pane-less Needs
 * You row: one button per action; a click sends that action's message to
 * the session inbox (POST /api/session/message, rowId = session id), once.
 * Detection itself is server-side (tests/test_transcript_wrap_up.py).
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { PanelessPrompt } from "../components/HookRequestCard";
import { alertFor } from "../alerts";
import { theme } from "../theme";
import type { NeedsYouRow } from "../types";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
  document.body.innerHTML = "";
});

function stubFetch(body: unknown = { ok: true, state: "message sent" }) {
  const calls: { url: string; body: any }[] = [];
  globalThis.fetch = (async (url: unknown, init?: { body?: string }) => {
    calls.push({ url: String(url), body: init?.body ? JSON.parse(init.body) : null });
    return { ok: true, status: 200, json: async () => body } as Response;
  }) as typeof fetch;
  return calls;
}

function mount(node: React.ReactNode) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => root.render(<MantineProvider theme={theme}>{node}</MantineProvider>));
  return host;
}

const row: NeedsYouRow = {
  kind: "blocked", urgency: 1, label: "ssv-bi", paneId: null, detail: "Start slice 1?", sinceSec: 4,
  identity: "s-1", source: "claude-desktop", agentSession: "s-1",
  wrapUpQuestion: {
    ask: "Start building DATA-314 with slice 1?", recap: "Plan ready.",
    actions: [{ label: "Start slice 1", message: "Start DATA-314 slice 1 now." },
              { label: "Adjust plan first", message: "Adjust plan first" }],
  },
};

const buttons = (host: HTMLElement) => [...host.querySelectorAll("button")] as HTMLButtonElement[];

describe("WrapUpCard", () => {
  test("shows the ask and one button per action", () => {
    const host = mount(<PanelessPrompt row={row} onToast={() => {}} />);
    expect(host.textContent).toContain("Start building DATA-314 with slice 1?");
    expect(buttons(host).map((b) => b.textContent)).toEqual(["Start slice 1", "Adjust plan first"]);
  });

  test("a click sends that action's message to the session inbox, once", async () => {
    const calls = stubFetch();
    const host = mount(<PanelessPrompt row={row} onToast={() => {}} />);
    await act(async () => buttons(host)[1].click());
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe("/api/session/message");
    expect(calls[0].body).toMatchObject({ rowId: "s-1", text: "Adjust plan first", confirm: true });
    expect(buttons(host).every((b) => b.disabled)).toBe(true);
    expect(host.textContent).toContain("Sent “Adjust plan first”.");
  });

  test("a refusal is shown and nothing claims success", async () => {
    stubFetch({ ok: false, error: "session gone", typed: false });
    const host = mount(<PanelessPrompt row={row} onToast={() => {}} />);
    await act(async () => buttons(host)[0].click());
    expect(host.textContent).toContain("Not sent: session gone");
  });

  test("no wrapUpQuestion -> nothing rendered", () => {
    const host = mount(<PanelessPrompt row={{ ...row, wrapUpQuestion: null }} onToast={() => {}} />);
    expect(buttons(host)).toHaveLength(0);
  });

  test("alert names the ask", () => {
    expect(alertFor(row)?.body).toBe("Start building DATA-314 with slice 1?");
  });
});
