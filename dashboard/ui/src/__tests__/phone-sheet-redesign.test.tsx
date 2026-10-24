/**
 * Phone sheet redesign: header (status chip, no stray "—", Open in Claude
 * icon, "•••" menu with confirm), one-row footer composer (accessible label,
 * mic in the field, always-primary Send, image note only when relevant),
 * underline tabs, edge-to-edge CSS, 44px targets.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { PhoneSheet } from "../components/phone/PhoneSheet";
import { Composer } from "../components/Composer";
import { theme } from "../theme";
import type { BoardRow } from "../types";

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
  document.body.innerHTML = "";
});

const css = (p: string) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");

function row(derived: Partial<BoardRow["derived"]> = {}, extra: Partial<BoardRow> = {}): BoardRow {
  return {
    rowKind: "session",
    rowId: "alpha",
    status: "live",
    derived: {
      paneId: "w8:p1",
      paneIdSanitized: "w8-p1",
      label: "alpha",
      cwd: null,
      focused: false,
      hookState: "idle",
      hookSinceSec: null,
      herdrStatus: "idle",
      disagree: false,
      hasHookData: true,
      screenState: "IDLE",
      source: "herdr",
      messageVia: "pane",
      agentKind: "claude",
      ...derived,
    },
    values: {},
    actions: { stop: { enabled: true, needsConfirm: false, reason: "" }, archive: { enabled: true, needsConfirm: false, reason: "" } },
    ...extra,
  };
}

function stubFetch() {
  const calls: { url: string; body: unknown }[] = [];
  globalThis.fetch = (async (url: unknown, init?: { body?: string }) => {
    calls.push({ url: String(url), body: init?.body ? JSON.parse(init.body) : null });
    return { ok: true, status: 200, json: async () => ({ ok: true, state: "message sent" }) } as Response;
  }) as typeof fetch;
  return calls;
}

function mount(node: React.ReactNode) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => root.render(<MantineProvider theme={theme}>{node}</MantineProvider>));
  return { host, unmount: () => act(() => root.unmount()) };
}

const sheet = (r: BoardRow, onToast: (m: string, ok: boolean) => void = () => {}) => (
  <PhoneSheet row={r} properties={[]} onClose={() => {}} onToast={onToast} onRefetch={() => {}} />
);
const menuTrigger = () => document.querySelector<HTMLElement>('button[aria-label="More actions"]');
const items = () => [...document.querySelectorAll('[role="menuitem"]')] as HTMLElement[];
const settle = () => act(async () => { for (let i = 0; i < 5; i++) await Promise.resolve(); });

describe("header", () => {
  test("no stray '—' or '•' when there is no age; status chip stays", () => {
    stubFetch();
    const m = mount(sheet(row()));
    const head = document.querySelector(".ui-sheet__head")!;
    const sub = head.querySelector(".phone-sheet-sub")!.textContent!;
    expect(sub).toBe("Working");
    expect(head.querySelector(".ui-status")).not.toBeNull();
    expect(head.querySelector(".phone-sheet-meta")).toBeNull();
    m.unmount();
  });

  test("age shows when known", () => {
    stubFetch();
    const m = mount(sheet(row({ hookSinceSec: 300 })));
    expect(document.querySelector(".phone-sheet-meta")?.textContent).toBe("5m");
    m.unmount();
  });

  test("Open in Claude is a named icon link; the footer has no actions or quick rows", () => {
    stubFetch();
    const m = mount(sheet(row({ openUrl: "claude://code/continue?session=local_x" })));
    const link = document.querySelector<HTMLAnchorElement>('a[aria-label="Open in Claude"]');
    expect(link).not.toBeNull();
    expect(link!.className).toContain("ui-icon-btn");
    expect(document.querySelector(".phone-sheet-actions, .phone-sheet-quick")).toBeNull();
    m.unmount();
  });

  test("menu: 44px-row actions, destructive Done / /clear confirm first, Escape closes", async () => {
    const calls = stubFetch();
    const m = mount(sheet(row()));
    expect(menuTrigger()!.getAttribute("aria-haspopup")).toBe("menu");
    act(() => menuTrigger()!.click());
    expect(menuTrigger()!.getAttribute("aria-expanded")).toBe("true");
    expect(items().map((i) => i.textContent)).toEqual(["Done", "Park", "/compact", "/clear"]);
    expect(items().filter((i) => i.dataset.tone === "danger").map((i) => i.textContent)).toEqual(["Done", "/clear"]);
    act(() => items()[3].click());
    await settle();
    expect(calls.some((c) => c.url === "/api/session/message")).toBe(false);
    expect(items().map((i) => i.textContent)).toContain("Confirm clear");
    act(() => menuTrigger()!.closest(".ui-menu")!.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
    expect(document.querySelector('[role="menu"]')).toBeNull();
    m.unmount();
  });
});

describe("footer composer (phone)", () => {
  test("one row: accessible label instead of the long visible one, mic inside the field, primary Send", () => {
    stubFetch();
    const m = mount(sheet(row()));
    const footer = document.querySelector(".ui-sheet__footer")!;
    expect(footer.textContent).not.toContain("not destructive");
    const input = footer.querySelector<HTMLInputElement>(".composer-field input")!;
    expect(input.placeholder).toBe("Message agent…");
    expect(input.getAttribute("aria-label")).toBe("Message alpha");
    expect(footer.querySelector(".composer-field .composer-mic")?.getAttribute("aria-label")).toBe("record voice message");
    expect(footer.querySelector(".voice-bar")).toBeNull(); // no Voice row while idle
    const send = [...footer.querySelectorAll("button")].find((b) => b.textContent === "Send")!;
    expect(send.getAttribute("data-variant")).toBe("primary");
    expect(send.disabled).toBe(true); // empty, still primary-styled (CSS dims it)
    m.unmount();
  });

  test("remote-machine image note only after an image is pasted", () => {
    stubFetch();
    const remote = row({ acceptsImages: false });
    const m = mount(<Composer rows={[remote]} onToast={() => {}} phone />);
    expect(m.host.textContent).not.toContain("Images can only go to agents on this Mac");
    const input = m.host.querySelector<HTMLInputElement>("input")!;
    const paste = new Event("paste", { bubbles: true }) as Event & { clipboardData?: unknown };
    const file = new File(["x"], "a.png", { type: "image/png" });
    paste.clipboardData = { files: [file], items: [{ kind: "file", type: "image/png", getAsFile: () => file }] };
    act(() => { input.dispatchEvent(paste); });
    expect(m.host.textContent).toContain("Images can only go to agents on this Mac");
    m.unmount();
  });

  test("desktop Composer keeps its label and note", () => {
    stubFetch();
    const m = mount(<Composer rows={[row({ acceptsImages: false })]} onToast={() => {}} />);
    expect(m.host.textContent).toContain("not destructive");
    expect(m.host.textContent).toContain("Images can only go to agents on this Mac");
    m.unmount();
  });

  test("sent toast carries the queues-if-busy hint", async () => {
    stubFetch();
    const toasts: string[] = [];
    const m = mount(<Composer rows={[row()]} onToast={(t) => toasts.push(t)} phone />);
    const input = m.host.querySelector<HTMLInputElement>("input")!;
    act(() => {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!.call(input, "hi");
      input.dispatchEvent(new Event("input", { bubbles: true }));
    });
    await act(async () => { input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true })); });
    await settle();
    expect(toasts.some((t) => t.startsWith("sent to") && t.includes("queues if the agent is busy"))).toBe(true);
    m.unmount();
  });
});

describe("tabs + CSS", () => {
  test("underline tabs, no segmented control", () => {
    const phone = css("components/phone/phone.css");
    expect(phone).toMatch(/\.phone-tab\s*\{[^}]*height:\s*36px/);
    expect(phone).not.toMatch(/\.phone-tabs\s*\{[^}]*background:\s*var\(--sunken\)/);
    expect(phone).toMatch(/\.phone-tab\[aria-selected="true"\]::after\s*\{\s*background:\s*var\(--ink\)/);
  });

  test("phone sections are edge-to-edge (the global card is reset), one gutter at the sheet level", () => {
    const phone = css("components/phone/phone.css");
    expect(phone).toMatch(/\.phone-app section\s*\{[^}]*margin:\s*0;[^}]*border:\s*0;[^}]*border-radius:\s*0/);
    const sheetCss = css("ui/Sheet.css");
    expect(sheetCss).toContain("--ui-sheet-gutter: 12px");
    expect(sheetCss).toMatch(/\.ui-sheet__body\s*\{[^}]*padding:\s*var\(--s3\) var\(--ui-sheet-gutter\)/);
  });

  test("sm buttons are 44px on the phone; disabled primary Send is dimmed, not grey", () => {
    expect(css("ui/ActionButton.css")).toMatch(/max-width:\s*640px\)\s*\{\s*\.ui-btn\[data-size="sm"\]\s*\{\s*--btn-h:\s*44px/);
    expect(css("ui/ActionButton.css")).toMatch(/\.ui-btn:disabled\s*\{\s*opacity:\s*\.45/);
  });
});
