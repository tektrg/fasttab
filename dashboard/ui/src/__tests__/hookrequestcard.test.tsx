/**
 * Pane-less (Claude Desktop / CLI) Needs You rows on the web UI — the phone's
 * web remote included: a hook-held prompt is answerable with exactly the body
 * AgentBar sends (POST /api/hook/permission/<id>/answer), a transcript-only
 * question is display only, alerts never repeat for a re-sent prompt, and the
 * SSE stream announces this build as an answer surface.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { PanelessPrompt } from "../components/HookRequestCard";
import { alertFor } from "../alerts";
import { useDashboardState } from "../api";
import { theme } from "../theme";
import type { HookRequest, NeedsYouRow } from "../types";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
  document.body.innerHTML = "";
});

function stubFetch(reply: { status?: number; body: unknown } = { body: { ok: true, state: "answered" } }) {
  const calls: { url: string; body: unknown }[] = [];
  globalThis.fetch = (async (url: unknown, init?: { body?: string }) => {
    calls.push({ url: String(url), body: init?.body ? JSON.parse(init.body) : null });
    const status = reply.status ?? 200;
    return { ok: status < 400, status, json: async () => reply.body } as Response;
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

async function settle() {
  await act(async () => {
    for (let k = 0; k < 4; k++) await Promise.resolve();
  });
}

function click(el: Element | null | undefined) {
  if (!el) throw new Error("element not found");
  act(() => {
    el.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
}

function button(text: string): HTMLButtonElement | null {
  return ([...document.querySelectorAll("button")].find((b) => b.textContent?.trim() === text) as
    HTMLButtonElement | undefined) ?? null;
}

function chip(labelText: string): HTMLInputElement {
  const label = [...document.querySelectorAll("label")].find((l) => l.textContent?.trim() === labelText);
  const input = label && document.getElementById(label.getAttribute("for") || "");
  if (!input) throw new Error("chip not found: " + labelText);
  return input as HTMLInputElement;
}

function typeInto(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  act(() => {
    setter.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

function otherInputs(): HTMLInputElement[] {
  return [...document.querySelectorAll("input[type=text], input:not([type])")] as HTMLInputElement[];
}

function row(extra: Partial<NeedsYouRow>): NeedsYouRow {
  return {
    kind: "blocked", urgency: 1, label: "Live refresh", paneId: null, detail: "Question",
    sinceSec: 3, identity: "sess-1", source: "claude-desktop", agentSession: "sess-1", ...extra,
  };
}

const QUESTION: HookRequest = {
  requestId: "hp1-abc",
  kind: "question",
  toolName: "AskUserQuestion",
  questions: [{
    question: "Which refresh?", header: "Live refresh", multiSelect: false,
    options: [{ label: "Poll", description: "" }, { label: "Push", description: "" }],
  }],
};

describe("hook question", () => {
  test("pick one option -> the AgentBar answer body, to the request's answer route", async () => {
    const calls = stubFetch();
    mount(<PanelessPrompt row={row({ hookRequest: QUESTION })} onToast={() => {}} />);
    expect(button("Send answer")!.disabled).toBe(true);
    click(chip("2. Push"));
    click(button("Send answer"));
    await settle();
    expect(calls).toEqual([{
      url: "/api/hook/permission/hp1-abc/answer",
      body: { behavior: "allow", answers: { "Which refresh?": "Push" } },
    }]);
    expect(document.body.textContent).toContain("Sent — Claude continues.");
    expect(button("Send answer")!.disabled).toBe(true);
  });

  test("multi-question form: every question needed; multi-select joins in option order; Other replaces picks", async () => {
    const calls = stubFetch();
    const form: HookRequest = {
      ...QUESTION,
      questions: [
        { question: "Which parts?", header: "Parts", multiSelect: true,
          options: [{ label: "A", description: "" }, { label: "B", description: "" }] },
        { question: "Name?", header: "Name", multiSelect: false,
          options: [{ label: "Keep", description: "" }] },
      ],
    };
    mount(<PanelessPrompt row={row({ hookRequest: form })} onToast={() => {}} />);
    click(chip("2. B"));
    click(chip("1. A"));
    expect(button("Send 2 answers")!.disabled).toBe(true);
    typeInto(otherInputs()[1], "  $(echo INJECTED)  ");
    click(button("Send 2 answers"));
    await settle();
    expect(calls[0].body).toEqual({
      behavior: "allow",
      answers: { "Which parts?": "A, B", "Name?": "$(echo INJECTED)" },
    });
  });

  test("a refusal (answered in Claude first) is shown verbatim, never retried", async () => {
    const calls = stubFetch({ status: 409, body: { ok: false, error: "This prompt was already answered in Claude." } });
    mount(<PanelessPrompt row={row({ hookRequest: QUESTION })} onToast={() => {}} />);
    click(chip("1. Poll"));
    click(button("Send answer"));
    await settle();
    expect(calls.length).toBe(1);
    expect(document.body.textContent).toContain("Not sent: This prompt was already answered in Claude.");
  });
});

describe("hook permission", () => {
  const PERMISSION: HookRequest = {
    requestId: "hp2-def", kind: "permission", toolName: "Bash",
    permission: { title: "Run a shell command", detail: "echo sentinel",
      suggestions: [{ index: 0, label: "Always allow `Bash(echo:*)` in this project" }] },
  };

  test("Allow once / Deny send the plain decision", async () => {
    const calls = stubFetch();
    mount(<PanelessPrompt row={row({ hookRequest: PERMISSION })} onToast={() => {}} />);
    expect(document.body.textContent).toContain("echo sentinel");
    click(button("Deny"));
    await settle();
    expect(calls[0]).toEqual({ url: "/api/hook/permission/hp2-def/answer", body: { behavior: "deny" } });
  });

  test("a permission-rule suggestion needs a second tap", async () => {
    const calls = stubFetch();
    mount(<PanelessPrompt row={row({ hookRequest: PERMISSION })} onToast={() => {}} />);
    click(button("Allow + Always allow `Bash(echo:*)` in this project"));
    await settle();
    expect(calls.length).toBe(0);
    click(button("Confirm: Always allow `Bash(echo:*)` in this project"));
    await settle();
    expect(calls[0].body).toEqual({ behavior: "allow", suggestionIndex: 0 });
  });
});

describe("transcript question fallback", () => {
  test("display only: the question text, no buttons, nothing sent", () => {
    const calls = stubFetch();
    mount(<PanelessPrompt
      row={row({ detail: "Input needed", transcriptQuestion: { header: "Live refresh", question: "Which refresh?", questionCount: 2 } })}
      onToast={() => {}} />);
    expect(document.body.textContent).toContain("Which refresh?");
    expect(document.body.textContent).toContain("(+1 more)");
    expect(document.body.textContent).toContain("answer it in Claude");
    expect(document.querySelectorAll("button").length).toBe(0);
    expect(calls.length).toBe(0);
  });

  test("a pane row never renders it (its pane path answers)", () => {
    mount(<PanelessPrompt row={row({ paneId: "w1:p1", hookRequest: QUESTION })} onToast={() => {}} />);
    expect(document.body.textContent).toBe("");
  });
});

describe("alerts for pane-less rows", () => {
  test("same question: transcript fallback -> hook request -> re-sent with a new id = one alert key", () => {
    const fallback = alertFor(row({ transcriptQuestion: { header: "", question: "Which refresh?", questionCount: 1 } }));
    const held = alertFor(row({ hookRequest: QUESTION }));
    const resent = alertFor(row({ hookRequest: { ...QUESTION, requestId: "hp9-new" } }));
    expect(fallback).not.toBe(null);
    expect(new Set([fallback!.key, held!.key, resent!.key]).size).toBe(1);
    expect(held!.slot).toBe("sess-1");
  });

  test("a different question re-alerts; a bare waiting row does not alert", () => {
    const other = alertFor(row({ hookRequest: { ...QUESTION, questions: [{ ...QUESTION.questions![0], question: "Other?" }] } }));
    expect(other!.key).not.toBe(alertFor(row({ hookRequest: QUESTION }))!.key);
    expect(alertFor(row({}))).toBe(null);
  });
});

describe("SSE stream", () => {
  test("opened with answerSurface=web (the dashboard may hold prompts for this page)", () => {
    const urls: string[] = [];
    const RealEventSource = (globalThis as { EventSource?: unknown }).EventSource;
    (globalThis as { EventSource?: unknown }).EventSource = class {
      static CLOSED = 2;
      readyState = 0;
      onmessage = null;
      onerror = null;
      constructor(url: string) { urls.push(url); }
      close() {}
    };
    stubFetch({ body: {} });
    function Probe() {
      useDashboardState();
      return null;
    }
    mount(<Probe />);
    (globalThis as { EventSource?: unknown }).EventSource = RealEventSource;
    expect(urls).toEqual(["/api/events?answerSurface=web"]);
  });
});
