/**
 * The phone's full-screen pushed screen (ui/Screen.tsx): one scroll area,
 * a footer that follows the visual viewport above the keyboard, and back via
 * the button, history (OS back gesture) or a left-edge swipe.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { Screen } from "../ui/Screen";

const css = (p: string) => readFileSync(join(import.meta.dir, "..", p), "utf8");
const rules = (src: string) => [...src.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((m) => ({ sel: m[1].trim(), body: m[2] }));

class FakeVV extends EventTarget { height = 800; scale = 1; offsetTop = 0; }
const realVV = Object.getOwnPropertyDescriptor(window, "visualViewport");
const realInner = window.innerHeight;
const unmounts: Array<() => void> = [];
afterEach(() => {
  while (unmounts.length) unmounts.pop()!();
  Object.defineProperty(window, "innerHeight", { value: realInner, configurable: true });
  if (realVV) Object.defineProperty(window, "visualViewport", realVV);
  else delete (window as unknown as Record<string, unknown>).visualViewport;
  document.body.innerHTML = "";
});

function mount(node: React.ReactNode) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => root.render(node));
  unmounts.push(() => act(() => root.unmount()));
  return root;
}

describe("single scroll area", () => {
  test("phone.css: nothing inside a screen declares its own scroller", () => {
    const phone = rules(css("components/phone/phone.css"));
    const bad = phone.filter(
      (r) => /overflow(-y)?:\s*(auto|scroll)/.test(r.body) && /latest-message|rp-screen-box|rp-msglog|rp-sections|ui-screen/.test(r.sel) && !/overflow-x/.test(r.sel),
    );
    expect(bad.map((r) => r.sel)).toEqual([]);
    for (const cls of ["rp-screen-box", "rp-msglog", "rp-sections"]) {
      const r = phone.find((x) => x.sel.includes(".ui-screen") && x.sel.includes(cls));
      expect(r?.body).toMatch(/overflow:\s*visible/);
    }
  });

  test("Screen.css: the body is the only overflow-y scroller", () => {
    const scrollers = rules(css("ui/Screen.css")).filter((r) => /overflow(-y)?:\s*(auto|scroll)/.test(r.body));
    expect(scrollers.map((r) => r.sel)).toEqual([".ui-screen__body"]);
  });
});

describe("keyboard up", () => {
  test("the screen box follows the visual viewport (footer right above the keyboard); CSS slims the footer", () => {
    const vv = new FakeVV();
    Object.defineProperty(window, "visualViewport", { value: vv, configurable: true });
    Object.defineProperty(window, "innerHeight", { value: 800, configurable: true });
    mount(<Screen open onClose={() => {}} title="t" footer={<input aria-label="msg" />}>body</Screen>);
    const screen = document.querySelector<HTMLElement>(".ui-screen")!;
    expect(screen.style.height).toBe("");
    act(() => {
      document.querySelector<HTMLInputElement>("input")!.focus();
      vv.height = 450;
      vv.offsetTop = 120;
      vv.dispatchEvent(new Event("resize"));
    });
    expect(screen.hasAttribute("data-keyboard")).toBe(true);
    expect(screen.style.height).toBe("450px");
    expect(screen.style.top).toBe("120px");
    act(() => {
      vv.height = 800;
      vv.offsetTop = 0;
      vv.dispatchEvent(new Event("resize"));
    });
    expect(screen.hasAttribute("data-keyboard")).toBe(false);
    expect(screen.style.height).toBe("");

    const hidden = rules(css("components/phone/phone.css")).find((r) => /\[data-keyboard\] \.phone-sheet-gate-note/.test(r.sel));
    expect(hidden?.body).toMatch(/display:\s*none/);
    for (const c of [".composer-remote-image-note", ".mantine-TextInput-label"]) expect(hidden!.sel).toContain(c);
  });
});

describe("back", () => {
  test("back button, history back and a left-edge swipe all close", () => {
    let closed = 0;
    const onClose = () => void closed++;
    mount(<Screen open onClose={onClose} title="Alpha">body</Screen>);
    expect(document.querySelector(".ui-screen")!.getAttribute("aria-label")).toBe("Alpha");
    expect(window.history.state?.uiScreen).toBe(true);

    act(() => document.querySelector<HTMLButtonElement>('button[aria-label="Back"]')!.click());
    expect(closed).toBe(1);

    act(() => void window.dispatchEvent(new PopStateEvent("popstate")));
    expect(closed).toBe(2);

    const screen = document.querySelector(".ui-screen")!;
    const touch = (type: string, x: number) => {
      const e = new Event(type, { bubbles: true }) as Event & Record<string, unknown>;
      const t = [{ clientX: x, clientY: 300 }];
      Object.assign(e, { touches: type === "touchend" ? [] : t, changedTouches: t });
      screen.dispatchEvent(e);
    };
    act(() => { touch("touchstart", 200); touch("touchend", 380); });
    expect(closed).toBe(2); // not from the edge
    act(() => { touch("touchstart", 8); touch("touchend", 160); });
    expect(closed).toBe(3);
  });
});
