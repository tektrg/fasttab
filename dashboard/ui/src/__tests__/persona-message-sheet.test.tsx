/**
 * PersonaMessageSheet — the phone's "message a persona" (AgentBar persona
 * routing parity). Threat model: a tap here types into a real session or
 * opens a new one on the Mac, so nothing is sent on a pick alone (Jev's or
 * the user's), and a start needs a second press + `confirm: true`.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { PersonaMessageSheet } from "../components/phone/PersonaMessageSheet";
import { theme } from "../theme";
import type { BoardRow } from "../types";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
  document.body.innerHTML = "";
});

const PERSONAS = [
  { name: "running", description: "Has a main session.", idleStart: "fresh", mainRowId: "main-1" },
  { name: "phone-ok", description: "Startable.", idleStart: "resume", mainRowId: null },
  { name: "fresh-one", description: "Starts fresh.", idleStart: "fresh", mainRowId: null },
  { name: "away", description: "Machine is off.", idleStart: "fresh", mainRowId: null, offline: true },
];

function liveRow(rowId: string, extra: Partial<BoardRow["derived"]> = {}): BoardRow {
  return {
    rowKind: "session",
    rowId,
    status: "live",
    derived: {
      paneId: "w1:p1",
      paneIdSanitized: "w1-p1",
      label: rowId,
      cwd: null,
      focused: false,
      hookState: "idle",
      hookSinceSec: 5,
      herdrStatus: "idle",
      disagree: false,
      hasHookData: true,
      screenState: "IDLE",
      messageVia: "pane",
      ...extra,
    },
    values: {},
  };
}

type Replies = Record<string, object>;

function stubFetch(replies: Replies, personas: unknown = PERSONAS) {
  const calls: { url: string; body: unknown }[] = [];
  globalThis.fetch = (async (url: unknown, init?: { body?: string }) => {
    const body = init?.body ? JSON.parse(init.body) : null;
    calls.push({ url: String(url), body });
    const reply = String(url) === "/api/personas" ? personas : (replies[String(url)] ?? { ok: false, error: "unstubbed" });
    return { ok: true, status: 200, json: async () => reply } as Response;
  }) as typeof fetch;
  return calls;
}

async function settle() {
  await act(async () => {
    for (let i = 0; i < 5; i++) await Promise.resolve();
  });
}

function mount(rows: BoardRow[], onClose = () => {}, onToast = (_m: string, _ok: boolean) => {}) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => {
    root.render(
      <MantineProvider theme={theme}>
        <PersonaMessageSheet opened rows={rows} onClose={onClose} onToast={onToast} />
      </MantineProvider>,
    );
  });
  return () => act(() => root.unmount());
}

function typeMessage(text: string) {
  const input = document.querySelector('input[aria-label="message"]') as HTMLInputElement;
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  act(() => {
    setter.call(input, text);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

function button(label: string) {
  return [...document.querySelectorAll("button")].find((b) => b.textContent?.trim() === label);
}

function pick(name: string) {
  const radio = document.querySelector(`input[type="radio"][value="${name}"]`) as HTMLInputElement;
  act(() => radio.click());
}

const posts = (calls: { url: string; body: unknown }[], url: string) => calls.filter((c) => c.url === url);

describe("PersonaMessageSheet", () => {
  test("running persona: Send goes to its main session via /api/session/message", async () => {
    const calls = stubFetch({ "/api/session/message": { ok: true, state: "message sent" } });
    let closed = false;
    const unmount = mount([liveRow("main-1")], () => (closed = true));
    await settle();
    expect(document.body.textContent).toContain("→ send to main session");
    typeMessage("hello $(echo INJECTED)");
    act(() => button("Send")!.click());
    await settle();
    expect(posts(calls, "/api/session/message")[0]?.body).toEqual({
      rowId: "main-1",
      actor: "po",
      text: "hello $(echo INJECTED)",
      confirm: false,
    });
    expect(posts(calls, "/api/persona/start")).toEqual([]);
    expect(closed).toBe(true);
    unmount();
  });

  test("busy main session: the queue needs a second press", async () => {
    const calls = stubFetch({ "/api/session/message": { ok: false, needsConfirm: true, reason: "mid-turn" } });
    const unmount = mount([liveRow("main-1")]);
    await settle();
    typeMessage("hi");
    act(() => button("Send")!.click());
    await settle();
    expect(button("Confirm queue")).toBeTruthy();
    act(() => button("Confirm queue")!.click());
    await settle();
    const sent = posts(calls, "/api/session/message");
    expect(sent.map((c) => (c.body as { confirm: boolean }).confirm)).toEqual([false, true]);
    unmount();
  });

  test("not running: Resume needs a confirm press, then posts confirm:true", async () => {
    const calls = stubFetch({ "/api/persona/start": { ok: true, mode: "resumed" } });
    const toasts: string[] = [];
    const unmount = mount([], () => {}, (m) => toasts.push(m));
    await settle();
    pick("phone-ok");
    typeMessage("pick up where we left off");
    act(() => button("Resume")!.click());
    await settle();
    expect(posts(calls, "/api/persona/start")).toEqual([]); // armed, nothing sent
    expect(document.body.textContent).toContain("Press again to confirm");
    act(() => button("Confirm resume")!.click());
    await settle();
    expect(posts(calls, "/api/persona/start")[0]?.body).toEqual({
      persona: "phone-ok",
      text: "pick up where we left off",
      fresh: false,
      confirm: true,
    });
    expect(toasts[0]).toContain("resumed: phone-ok");
    unmount();
  });

  test("not running, any registered persona: Start is offered (no per-persona opt-in)", async () => {
    const calls = stubFetch({ "/api/persona/start": { ok: true, mode: "started" } });
    const unmount = mount([]);
    await settle();
    pick("fresh-one");
    typeMessage("hi");
    expect(button("Start")!.disabled).toBe(false);
    act(() => button("Start")!.click());
    await settle();
    expect(posts(calls, "/api/persona/start")).toEqual([]); // armed, nothing sent
    act(() => button("Confirm start")!.click());
    await settle();
    expect(posts(calls, "/api/persona/start")[0]?.body).toEqual({
      persona: "fresh-one", text: "hi", fresh: true, confirm: true,
    });
    unmount();
  });

  test("machine offline: the persona isn't offered", async () => {
    stubFetch({});
    const unmount = mount([]);
    await settle();
    expect(document.querySelector('input[type="radio"][value="away"]')).toBeNull();
    expect(document.querySelector('input[type="radio"][value="fresh-one"]')).toBeTruthy();
    unmount();
  });

  test("main session waiting on you: nothing is sent", async () => {
    stubFetch({});
    const unmount = mount([liveRow("main-1", { screenState: "NEEDS_HUMAN" })]);
    await settle();
    typeMessage("hi");
    expect(button("Send")!.disabled).toBe(true);
    expect(document.body.textContent).toContain("waiting on you");
    unmount();
  });

  test("Ask Jev: shows the pick and waits for the user's confirm", async () => {
    const calls = stubFetch({
      "/api/jev/route": { ok: true, persona: "running", confidence: 0.82 },
      "/api/session/message": { ok: true, state: "message sent" },
    });
    const unmount = mount([liveRow("main-1")]);
    await settle();
    pick("phone-ok");
    typeMessage("fix the tab bar");
    act(() => button("Ask Jev")!.click());
    await settle();
    expect(posts(calls, "/api/jev/route")[0]?.body).toEqual({ text: "fix the tab bar" });
    expect(document.body.textContent).toContain("Jev picked running (82%)");
    expect(posts(calls, "/api/session/message")).toEqual([]); // never auto-sent
    const selected = document.querySelector('input[type="radio"][value="running"]') as HTMLInputElement;
    expect(selected.checked).toBe(true);
    act(() => button("Send")!.click());
    await settle();
    expect((posts(calls, "/api/session/message")[0]?.body as { rowId: string }).rowId).toBe("main-1");
    unmount();
  });

  test("a hand pick made while Jev is thinking wins over the late reply", async () => {
    let release: (v: unknown) => void = () => {};
    const gate = new Promise((r) => (release = r));
    globalThis.fetch = (async (url: unknown) => {
      if (String(url) === "/api/personas") return { ok: true, status: 200, json: async () => PERSONAS } as Response;
      await gate;
      return { ok: true, status: 200, json: async () => ({ ok: true, persona: "running", confidence: 0.9 }) } as Response;
    }) as typeof fetch;
    const unmount = mount([liveRow("main-1")]);
    await settle();
    typeMessage("hi");
    act(() => button("Ask Jev")!.click());
    pick("fresh-one");
    release(null);
    await settle();
    const chosen = document.querySelector('input[type="radio"][value="fresh-one"]') as HTMLInputElement;
    expect(chosen.checked).toBe(true);
    expect(document.body.textContent).not.toContain("Jev picked");
    unmount();
  });

  test("a Jev failure is shown verbatim, nothing sent", async () => {
    const calls = stubFetch({ "/api/jev/route": { ok: false, error: "Jev routing is off: no OpenRouter key on the Mac." } });
    const unmount = mount([]);
    await settle();
    typeMessage("hi");
    act(() => button("Ask Jev")!.click());
    await settle();
    expect(document.body.textContent).toContain("no OpenRouter key");
    expect(posts(calls, "/api/session/message")).toEqual([]);
    unmount();
  });

  test("closing the sheet drops an armed start: reopening needs both presses again", async () => {
    const calls = stubFetch({ "/api/persona/start": { ok: true, mode: "started" } });
    const host = document.createElement("div");
    document.body.appendChild(host);
    const root = createRoot(host);
    const render = (opened: boolean) =>
      act(() => {
        root.render(
          <MantineProvider theme={theme}>
            <PersonaMessageSheet opened={opened} rows={[]} onClose={() => {}} onToast={() => {}} />
          </MantineProvider>,
        );
      });
    render(true);
    await settle();
    pick("phone-ok");
    typeMessage("hi");
    act(() => button("Resume")!.click());
    expect(button("Confirm resume")).toBeTruthy();
    render(false);
    await settle();
    render(true);
    await settle();
    pick("phone-ok");
    expect(button("Confirm resume")).toBeUndefined();
    act(() => button("Resume")!.click());
    await settle();
    expect(posts(calls, "/api/persona/start")).toEqual([]);
    act(() => root.unmount());
  });

  test("a held (auto-repeating) Enter never confirms a start", async () => {
    const calls = stubFetch({ "/api/persona/start": { ok: true, mode: "started" } });
    const unmount = mount([]);
    await settle();
    pick("phone-ok");
    typeMessage("hi");
    const input = document.querySelector('input[aria-label="message"]') as HTMLInputElement;
    act(() => {
      input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    act(() => {
      input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", repeat: true, bubbles: true }));
    });
    await settle();
    expect(button("Confirm resume")).toBeTruthy(); // armed by the first press only
    expect(posts(calls, "/api/persona/start")).toEqual([]);
    unmount();
  });

  test("a same-tick double tap on Send posts once (QA2)", async () => {
    const calls = stubFetch({ "/api/session/message": { ok: true, state: "message sent" } });
    const unmount = mount([liveRow("main-1")]);
    await settle();
    typeMessage("hi");
    act(() => {
      button("Send")!.click();
      button("Send")!.click();
    });
    await settle();
    expect(posts(calls, "/api/session/message").length).toBe(1);
    unmount();
  });

  test("Enter + a tap in the same tick confirm a start once (QA2)", async () => {
    const calls = stubFetch({ "/api/persona/start": { ok: true, mode: "resumed" } });
    const unmount = mount([]);
    await settle();
    pick("phone-ok");
    typeMessage("hi");
    act(() => button("Resume")!.click());
    const input = document.querySelector('input[aria-label="message"]') as HTMLInputElement;
    act(() => {
      button("Confirm resume")!.click();
      input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    });
    await settle();
    expect(posts(calls, "/api/persona/start").length).toBe(1);
    unmount();
  });

  test("Jev network failure: error shown, Ask Jev usable again, no spinner (QA2)", async () => {
    globalThis.fetch = (async (url: unknown) => {
      if (String(url) === "/api/personas") return { ok: true, status: 200, json: async () => PERSONAS } as Response;
      throw new TypeError("Load failed");
    }) as typeof fetch;
    const unmount = mount([liveRow("main-1")]);
    await settle();
    typeMessage("hi");
    act(() => button("Ask Jev")!.click());
    await settle();
    expect(document.body.textContent).toContain("Load failed");
    expect(button("Ask Jev")!.disabled).toBe(false);
    expect(document.querySelector("[data-loading]")).toBeNull();
    const input = document.querySelector('input[aria-label="message"]') as HTMLInputElement;
    expect(input.disabled).toBe(false);
    unmount();
  });

  test("login expired mid-start: the error shows, the text stays for a retry (QA2)", async () => {
    globalThis.fetch = (async (url: unknown) => {
      if (String(url) === "/api/personas") return { ok: true, status: 200, json: async () => PERSONAS } as Response;
      return { ok: false, status: 401, json: async () => ({ ok: false, error: "unauthenticated" }) } as Response;
    }) as typeof fetch;
    const unmount = mount([]);
    await settle();
    pick("phone-ok");
    typeMessage("keep me");
    act(() => button("Resume")!.click());
    act(() => button("Confirm resume")!.click());
    await settle();
    expect(document.body.textContent).toContain("log in again");
    const input = document.querySelector('input[aria-label="message"]') as HTMLInputElement;
    expect(input.value).toBe("keep me");
    unmount();
  });

  test("no persona at all -> points at Settings", async () => {
    stubFetch({}, []);
    const unmount = mount([]);
    await settle();
    expect(document.body.textContent).toContain("Settings > Personas");
    unmount();
  });
});
