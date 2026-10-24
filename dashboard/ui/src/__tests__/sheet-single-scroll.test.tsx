/**
 * One scroll area per sheet (.ui-sheet__body) and a lean footer while the
 * keyboard is up. See the SCROLL RULE in ui/Sheet.tsx.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { Sheet } from "../ui/Sheet";

const css = (p: string) => readFileSync(join(import.meta.dir, "..", p), "utf8");
const rules = (src: string) => [...src.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((m) => ({ sel: m[1].trim(), body: m[2] }));

class FakeVV extends EventTarget { height = 800; scale = 1; offsetTop = 0; }
const realVV = Object.getOwnPropertyDescriptor(window, "visualViewport");
const realInner = window.innerHeight;
const unmounts: Array<() => void> = [];
afterEach(() => {
  while (unmounts.length) unmounts.pop()!();
  Object.defineProperty(window, "innerHeight", { value: realInner, configurable: true });
  document.body.removeAttribute("style");
  if (realVV) Object.defineProperty(window, "visualViewport", realVV);
  else delete (window as unknown as Record<string, unknown>).visualViewport;
  document.body.innerHTML = "";
});

describe("single scroll area", () => {
  test("phone.css: nothing inside a sheet declares its own scroller", () => {
    const phone = rules(css("components/phone/phone.css"));
    const bad = phone.filter(
      (r) => /overflow(-y)?:\s*(auto|scroll)/.test(r.body) && /latest-message|rp-screen-box|rp-msglog|rp-sections|ui-sheet/.test(r.sel) && !/overflow-x/.test(r.sel),
    );
    expect(bad.map((r) => r.sel)).toEqual([]);
    expect(phone.some((r) => /latest-message/.test(r.sel) && /max-height:\s*40vh/.test(r.body))).toBe(false);
    // desktop inner scrollers are neutralised inside a sheet
    for (const cls of ["rp-screen-box", "rp-msglog", "rp-sections"]) {
      const r = phone.find((x) => x.sel.includes(`.ui-sheet`) && x.sel.includes(cls));
      expect(r?.body).toMatch(/overflow:\s*visible/);
    }
  });

  test("Sheet.css: the body is the only overflow-y scroller", () => {
    const sheet = rules(css("ui/Sheet.css")).filter((r) => /overflow(-y)?:\s*(auto|scroll)/.test(r.body));
    expect(sheet.map((r) => r.sel)).toEqual([".ui-sheet__body"]);
  });
});

describe("keyboard up", () => {
  test("sheet flags data-keyboard + --ui-vvh and snaps full on input focus; CSS hides the extras", () => {
    const vv = new FakeVV();
    Object.defineProperty(window, "visualViewport", { value: vv, configurable: true });
    Object.defineProperty(window, "innerHeight", { value: 800, configurable: true });
    const host = document.createElement("div");
    document.body.appendChild(host);
    const root = createRoot(host);
    act(() => root.render(<Sheet open onOpenChange={() => {}} title="t" footer={<input aria-label="msg" />}>body</Sheet>));
    unmounts.push(() => act(() => root.unmount()));
    const sheet = document.querySelector<HTMLElement>(".ui-sheet")!;
    expect(sheet.hasAttribute("data-full")).toBe(false);
    act(() => {
      document.querySelector<HTMLInputElement>("input")!.focus();
      vv.height = 450;
      vv.dispatchEvent(new Event("resize"));
    });
    expect(sheet.hasAttribute("data-keyboard")).toBe(true);
    expect(sheet.style.getPropertyValue("--ui-vvh")).toBe("450px");
    expect(sheet.hasAttribute("data-full")).toBe(true);
    act(() => {
      vv.height = 800;
      vv.dispatchEvent(new Event("resize"));
    });
    expect(sheet.hasAttribute("data-keyboard")).toBe(false);

    const hidden = rules(css("components/phone/phone.css")).find((r) => /\[data-keyboard\] \.phone-sheet-gate-note/.test(r.sel));
    expect(hidden?.body).toMatch(/display:\s*none/);
    for (const c of [".composer-remote-image-note", ".mantine-TextInput-label"]) expect(hidden!.sel).toContain(c);
  });
});
