/**
 * P2 QA2: soft-keyboard behaviour. Vaul's `repositionInputs` lifts the sheet
 * by the keyboard height, so the footer must NOT also translate itself; the
 * fixed tab bar hides while a text field has the keyboard up.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { Sheet } from "../ui/Sheet";
import { TabBar } from "../components/phone/TabBar";

class FakeVV extends EventTarget {
  height = 800;
  scale = 1;
  offsetTop = 0;
}
const realVV = Object.getOwnPropertyDescriptor(window, "visualViewport");
function installVV(): FakeVV {
  const vv = new FakeVV();
  Object.defineProperty(window, "visualViewport", { value: vv, configurable: true });
  Object.defineProperty(window, "innerHeight", { value: 800, configurable: true });
  return vv;
}
const realInner = window.innerHeight;
const unmounts: Array<() => void> = [];
afterEach(() => {
  // Unmount first: an open Vaul sheet leaves body scroll-lock styles that leak into later files.
  while (unmounts.length) unmounts.pop()!();
  Object.defineProperty(window, "innerHeight", { value: realInner, configurable: true });
  document.body.removeAttribute("style");
  if (realVV) Object.defineProperty(window, "visualViewport", realVV);
  else delete (window as unknown as Record<string, unknown>).visualViewport;
  document.body.innerHTML = "";
});

function mount(node: React.ReactNode) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => root.render(node));
  const unmount = () => act(() => root.unmount());
  unmounts.push(unmount);
  return { host, unmount };
}

describe("soft keyboard", () => {
  test("Sheet footer is not translated when the visual viewport shrinks (Vaul owns the lift)", () => {
    const vv = installVV();
    mount(<Sheet open onOpenChange={() => {}} title="t" footer={<input aria-label="msg" />}>body</Sheet>);
    act(() => {
      vv.height = 450;
      vv.dispatchEvent(new Event("resize"));
    });
    const footer = document.querySelector<HTMLElement>(".ui-sheet__footer");
    expect(footer).not.toBeNull();
    expect(footer!.style.transform).toBe("");
  });

  test("tab bar hides while a text field is focused under a shrunken viewport", () => {
    const vv = installVV();
    const { host } = mount(
      <>
        <input aria-label="search" />
        <TabBar tab="inbox" onTab={() => {}} inboxBadge={0} />
      </>,
    );
    const nav = host.querySelector("nav")!;
    expect(nav.hasAttribute("data-keyboard")).toBe(false);
    act(() => {
      host.querySelector("input")!.focus();
      vv.height = 450;
      vv.dispatchEvent(new Event("resize"));
    });
    expect(nav.hasAttribute("data-keyboard")).toBe(true);
    // Pinch-zoom shrinks the viewport too; that is not a keyboard.
    act(() => {
      vv.scale = 2;
      vv.dispatchEvent(new Event("resize"));
    });
    expect(nav.hasAttribute("data-keyboard")).toBe(false);
  });

  test("CSS: tab bar hides on keyboard; toast moves to the top while a sheet is open", () => {
    const phoneCss = readFileSync(join(import.meta.dir, "../components/phone/phone.css"), "utf8");
    const toastCss = readFileSync(join(import.meta.dir, "../ui/Toast.css"), "utf8");
    expect(phoneCss).toMatch(/\.phone-tabbar\[data-keyboard\]\s*\{\s*display:\s*none/);
    expect(toastCss).toMatch(/body:has\(\.ui-sheet\[data-state="open"\]\)\s+\.ui-toast-region\s*\{[^}]*top:/);
  });
});
