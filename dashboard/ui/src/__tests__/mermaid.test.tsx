/**
 * Mermaid diagrams inside agent-authored markdown (Markdown.tsx ->
 * MermaidBlock.tsx). The real `mermaid` package is mocked: these tests pin
 * the wiring — lazy load only when a ```mermaid block exists, the strict
 * security config, the source fallback on a bad diagram, the SVG scrub,
 * theme following, and one render per final block content.
 *
 * Test order matters for the "never loads" checks: the module is imported at
 * most once per process (cached promise), so those run first.
 */
import { afterAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";

type RenderCall = { id: string; text: string; theme: string | undefined };
const calls = {
  load: 0,
  initialize: [] as Array<Record<string, unknown>>,
  render: [] as RenderCall[],
};
let currentTheme: string | undefined;
let nextSvg: (text: string) => string = (text) => `<svg data-testid="diagram"><text>${text.length}</text></svg>`;

mock.module("mermaid", () => {
  calls.load += 1;
  return {
    default: {
      initialize: (cfg: Record<string, unknown>) => {
        calls.initialize.push(cfg);
        currentTheme = cfg.theme as string | undefined;
      },
      render: async (id: string, text: string) => {
        calls.render.push({ id, text, theme: currentTheme });
        if (text.includes("BROKEN")) throw new Error("Parse error on line 1");
        return { svg: nextSvg(text) };
      },
    },
  };
});

const { Markdown } = await import("../components/Markdown");
const { MERMAID_RENDER_DELAY_MS, __resetMermaidCacheForTests } = await import("../components/MermaidBlock");

const mounted: Array<{ root: Root; host: HTMLElement }> = [];

function mount(text: string) {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => {
    root.render(<Markdown text={text} />);
  });
  mounted.push({ root, host });
  return {
    host,
    rerender: (next: string) =>
      act(() => {
        root.render(<Markdown text={next} />);
      }),
  };
}

async function waitRender(ms = MERMAID_RENDER_DELAY_MS + 60) {
  await act(async () => {
    await new Promise((r) => setTimeout(r, ms));
  });
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}

beforeEach(() => {
  for (const m of mounted.splice(0)) {
    act(() => m.root.unmount());
    m.host.remove();
  }
  calls.initialize = [];
  calls.render = [];
  nextSvg = (text) => `<svg data-testid="diagram"><text>${text.length}</text></svg>`;
  document.documentElement.removeAttribute("data-mantine-color-scheme");
  __resetMermaidCacheForTests();
});

afterAll(() => {
  for (const m of mounted.splice(0)) {
    act(() => m.root.unmount());
    m.host.remove();
  }
});

const FLOW = "```mermaid\nflowchart LR\n  A[Start] --> B[Done]\n```";

describe("mermaid is never loaded for messages without a diagram", () => {
  test("plain prose does not import mermaid", async () => {
    const m = mount("**done** — all tests green");
    await waitRender();
    expect(m.host.textContent).toContain("done");
    expect(calls.load).toBe(0);
    expect(calls.render.length).toBe(0);
  });

  test("a normal (non-mermaid) code block stays a code block and does not import mermaid", async () => {
    const m = mount("```ts\nconst a = 1;\n```\n\n```\nplain fence\n```");
    await waitRender();
    expect(m.host.querySelector("pre code.language-ts")).not.toBe(null);
    expect(m.host.textContent).toContain("plain fence");
    expect(m.host.querySelector(".md-mermaid")).toBe(null);
    expect(calls.load).toBe(0);
    expect(calls.render.length).toBe(0);
  });
});

describe("mermaid block rendering", () => {
  test("a ```mermaid block lazy-loads mermaid and renders the diagram SVG", async () => {
    const m = mount(`Here is the flow:\n\n${FLOW}\n\nAfter.`);
    await waitRender();
    expect(calls.load).toBe(1);
    expect(calls.render.length).toBe(1);
    expect(calls.render[0].text).toContain("A[Start] --> B[Done]");
    const box = m.host.querySelector(".md-mermaid");
    expect(box).not.toBe(null);
    expect(box!.querySelector("svg")).not.toBe(null);
    // surrounding prose still renders
    expect(m.host.textContent).toContain("Here is the flow:");
    expect(m.host.textContent).toContain("After.");
  });

  test("passes the strict security config (never loose, no HTML labels)", async () => {
    mount(FLOW);
    await waitRender();
    expect(calls.initialize.length).toBeGreaterThan(0);
    const cfg = calls.initialize[calls.initialize.length - 1];
    expect(cfg.securityLevel).toBe("strict");
    expect(cfg.startOnLoad).toBe(false);
    expect(cfg.htmlLabels).toBe(false);
    expect((cfg.flowchart as { htmlLabels?: boolean } | undefined)?.htmlLabels).toBe(false);
    expect(cfg.suppressErrorRendering).toBe(true);
  });

  test("an invalid diagram shows the raw source plus a 'failed to render' note, never a blank", async () => {
    const m = mount("```mermaid\nflowchart BROKEN -->\n```");
    await waitRender();
    expect(calls.render.length).toBe(1);
    expect(m.host.querySelector(".md-mermaid svg")).toBe(null);
    const pre = m.host.querySelector("pre");
    expect(pre).not.toBe(null);
    expect(pre!.textContent).toContain("flowchart BROKEN -->");
    expect(m.host.textContent?.toLowerCase()).toContain("diagram failed to render");
  });

  test("scrubs the returned SVG: no script, no event handlers, no javascript: links, no foreignObject", async () => {
    const marker = "INJECTED";
    // <script> goes last: happy-dom's HTML parser swallows everything after
    // an svg <script> (browsers don't), which would hide the other checks.
    nextSvg = () =>
      `<svg onload="window.${marker}=1">` +
      `<a href="javascript:alert('${marker}')"><text>x</text></a>` +
      `<foreignObject><div onclick="x">${marker}-fo</div></foreignObject>` +
      `<g onmouseover="y"><text>ok</text></g><script>window.${marker}=2</script></svg>`;
    const m = mount(FLOW);
    await waitRender();
    const box = m.host.querySelector(".md-mermaid")!;
    const svg = box.querySelector("svg")!;
    expect(svg).not.toBe(null);
    expect(box.querySelector("script")).toBe(null);
    expect(box.querySelector("foreignObject")).toBe(null);
    expect(box.innerHTML).not.toContain("onload");
    expect(box.innerHTML).not.toContain("onmouseover");
    expect(box.innerHTML).not.toContain("javascript:");
    expect(box.innerHTML).not.toContain(`${marker}-fo`);
    expect(box.textContent).toContain("ok");
  });

  test("re-rendering the same content does not re-run mermaid (no flicker loop)", async () => {
    const m = mount(FLOW);
    await waitRender();
    expect(calls.render.length).toBe(1);
    m.rerender(FLOW);
    m.rerender(`${FLOW}\n`);
    await waitRender();
    expect(calls.render.length).toBe(1);
    expect(m.host.querySelector(".md-mermaid svg")).not.toBe(null);
  });

  test("a streaming block that changes quickly renders once, for the final content", async () => {
    const m = mount("```mermaid\nflowchart LR\n  A -->");
    m.rerender("```mermaid\nflowchart LR\n  A --> B");
    m.rerender("```mermaid\nflowchart LR\n  A --> B\n```");
    await waitRender();
    expect(calls.render.length).toBe(1);
    expect(calls.render[0].text.trim()).toBe("flowchart LR\n  A --> B");
  });

  test("theme follows the app color scheme and re-renders on a switch", async () => {
    document.documentElement.setAttribute("data-mantine-color-scheme", "dark");
    const m = mount(FLOW);
    await waitRender();
    expect(calls.render.length).toBe(1);
    expect(calls.render[0].theme).toBe("dark");
    act(() => {
      document.documentElement.setAttribute("data-mantine-color-scheme", "light");
    });
    await waitRender();
    expect(calls.render.length).toBe(2);
    expect(calls.render[1].theme).toBe("default");
    expect(m.host.querySelector(".md-mermaid svg")).not.toBe(null);
  });

  test("the diagram sits in its own horizontal-scroll box with a show-source toggle", async () => {
    const m = mount(FLOW);
    await waitRender();
    const scroll = m.host.querySelector(".md-mermaid__scroll");
    expect(scroll).not.toBe(null);
    expect(scroll!.querySelector("svg")).not.toBe(null);
    const details = m.host.querySelector("details.md-mermaid__source");
    expect(details).not.toBe(null);
    expect(details!.textContent).toContain("A[Start] --> B[Done]");
  });
});

// --- Fullscreen zoom viewer (MermaidZoomOverlay.tsx + mermaidZoom.ts) ---

const ZOOM_SVG = `<svg viewBox="0 0 400 200" width="400" height="200"><g><text>zoom me</text></g></svg>`;

function dialog(): HTMLElement | null {
  return document.querySelector('[role="dialog"].mmz');
}
function canvasView() {
  const c = document.querySelector(".mmz-canvas") as HTMLElement;
  return { scale: Number(c.dataset.scale), x: Number(c.dataset.x), y: Number(c.dataset.y), el: c };
}
function button(label: string): HTMLButtonElement {
  const b = document.querySelector(`[aria-label="${label}"]`) as HTMLButtonElement | null;
  if (!b) throw new Error(`no button "${label}"`);
  return b;
}
async function click(el: Element) {
  await act(async () => {
    (el as HTMLElement).click();
  });
  await waitRender(20);
}
async function key(k: string, opts: KeyboardEventInit = {}) {
  const target = document.activeElement ?? document.body;
  await act(async () => {
    target.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...opts }));
  });
}
async function openViewer() {
  nextSvg = () => ZOOM_SVG;
  const m = mount(FLOW);
  await waitRender();
  await click(m.host.querySelector(".md-mermaid__scroll")!);
  expect(dialog()).not.toBe(null);
  return m;
}
function pointer(type: string, el: Element, id: number, x: number, y: number) {
  const Ctor = (globalThis as { PointerEvent?: typeof PointerEvent }).PointerEvent ?? MouseEvent;
  const ev = new Ctor(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, pointerId: id, button: 0 } as PointerEventInit);
  if ((ev as PointerEvent).pointerId !== id) Object.defineProperty(ev, "pointerId", { value: id });
  el.dispatchEvent(ev);
}

/** happy-dom's WheelEvent drops ctrlKey/clientX/clientY; browsers keep them. */
function wheelEv(init: WheelEventInit): WheelEvent {
  const ev = new WheelEvent("wheel", { bubbles: true, cancelable: true, ...init });
  for (const k of ["ctrlKey", "metaKey", "clientX", "clientY"] as const) {
    if (init[k] !== undefined && ev[k] !== init[k]) Object.defineProperty(ev, k, { value: init[k] });
  }
  return ev;
}

describe("mermaid zoom viewer", () => {
  test("clicking a rendered diagram opens a modal dialog with the diagram", async () => {
    await openViewer();
    const d = dialog()!;
    expect(d.getAttribute("aria-modal")).toBe("true");
    expect(d.getAttribute("aria-label")).toBeTruthy();
    expect(d.querySelector(".mmz-canvas svg")).not.toBe(null);
    expect(d.contains(document.activeElement)).toBe(true);
  });

  test("the expand button opens it too, and Esc closes it with focus back on the button", async () => {
    nextSvg = () => ZOOM_SVG;
    const m = mount(FLOW);
    await waitRender();
    const expand = m.host.querySelector('[aria-label="Expand diagram"]') as HTMLButtonElement;
    expect(expand).not.toBe(null);
    expand.focus();
    await click(expand);
    expect(dialog()).not.toBe(null);
    await key("Escape");
    expect(dialog()).toBe(null);
    expect(document.activeElement).toBe(expand);
  });

  test("the × button closes it", async () => {
    await openViewer();
    await click(button("Close diagram"));
    expect(dialog()).toBe(null);
  });

  test("zoom buttons change the scale within 0.25x..8x and Fit resets", async () => {
    await openViewer();
    const fit = canvasView().scale;
    expect(fit).toBeGreaterThan(0.25);
    expect(fit).toBeLessThanOrEqual(8);
    await click(button("Zoom in"));
    expect(canvasView().scale).toBeGreaterThan(fit);
    for (let i = 0; i < 30; i++) await click(button("Zoom in"));
    expect(canvasView().scale).toBe(8);
    for (let i = 0; i < 40; i++) await click(button("Zoom out"));
    expect(canvasView().scale).toBe(0.25);
    await click(button("Fit to screen"));
    expect(canvasView().scale).toBeCloseTo(fit, 6);
  });

  test("the SVG is resized (vector), not CSS-scaled: canvas width = natural width × scale", async () => {
    await openViewer();
    await click(button("Zoom in"));
    const v = canvasView();
    expect(v.el.style.width).toBe(`${400 * v.scale}px`);
    expect(v.el.style.transform).not.toContain("scale");
  });

  test("ctrl+wheel (trackpad pinch) zooms in the viewer; plain wheel pans", async () => {
    await openViewer();
    const vp = document.querySelector(".mmz-viewport")!;
    const before = canvasView();
    await act(async () => {
      vp.dispatchEvent(wheelEv({ deltaY: -50, ctrlKey: true, clientX: 100, clientY: 100 }));
    });
    const zoomed = canvasView();
    expect(zoomed.scale).toBeGreaterThan(before.scale);
    // zoom is around the cursor: the diagram point under (100,100) stays put
    expect((100 - zoomed.x) / zoomed.scale).toBeCloseTo((100 - before.x) / before.scale, 6);
    await act(async () => {
      vp.dispatchEvent(wheelEv({ deltaY: 40 }));
    });
    const panned = canvasView();
    expect(panned.scale).toBe(zoomed.scale);
    expect(panned.y).toBeCloseTo(zoomed.y - 40, 6);
  });

  test("wheel over an inline diagram (with or without ctrl) never zooms or opens anything", async () => {
    nextSvg = () => ZOOM_SVG;
    const m = mount(FLOW);
    await waitRender();
    const box = m.host.querySelector(".md-mermaid__scroll")!;
    const plain = wheelEv({ deltaY: 100 });
    const ctrl = wheelEv({ deltaY: -100, ctrlKey: true });
    await act(async () => {
      box.dispatchEvent(plain);
      box.dispatchEvent(ctrl);
    });
    expect(plain.defaultPrevented).toBe(false);
    expect(ctrl.defaultPrevented).toBe(false);
    expect(dialog()).toBe(null);
    expect(document.querySelector(".mmz-canvas")).toBe(null);
  });

  test("one-finger drag pans; two-finger pinch zooms", async () => {
    await openViewer();
    const vp = document.querySelector(".mmz-viewport")!;
    const start = canvasView();
    await act(async () => {
      pointer("pointerdown", vp, 1, 100, 100);
      pointer("pointermove", vp, 1, 130, 90);
      pointer("pointerup", vp, 1, 130, 90);
    });
    const panned = canvasView();
    expect(panned.scale).toBe(start.scale);
    expect(panned.x).toBeCloseTo(start.x + 30, 6);
    expect(panned.y).toBeCloseTo(start.y - 10, 6);
    await act(async () => {
      pointer("pointerdown", vp, 1, 200, 200);
      pointer("pointerdown", vp, 2, 300, 200);
      pointer("pointermove", vp, 2, 400, 200);
      pointer("pointerup", vp, 2, 400, 200);
      pointer("pointerup", vp, 1, 200, 200);
    });
    expect(canvasView().scale).toBeCloseTo(Math.min(8, panned.scale * 2), 6);
  });

  test("the page behind can't scroll while open; scroll lock is undone on close", async () => {
    document.body.style.overflow = "";
    await openViewer();
    expect(document.body.style.overflow).toBe("hidden");
    await key("Escape");
    expect(document.body.style.overflow).toBe("");
  });

  test("Tab is trapped inside the dialog and every button has a label", async () => {
    await openViewer();
    const d = dialog()!;
    const buttons = Array.from(d.querySelectorAll("button"));
    expect(buttons.length).toBeGreaterThanOrEqual(4);
    for (const b of buttons) expect(b.getAttribute("aria-label")).toBeTruthy();
    buttons[buttons.length - 1].focus();
    await key("Tab");
    expect(document.activeElement).toBe(buttons[0]);
    buttons[0].focus();
    await key("Tab", { shiftKey: true });
    expect(document.activeElement).toBe(buttons[buttons.length - 1]);
  });
});

describe("mermaidZoom math", () => {
  test("zoomAt keeps the point under the cursor fixed and clamps the scale", async () => {
    const { zoomAt, MAX_SCALE, MIN_SCALE } = await import("../components/mermaidZoom");
    const v = { scale: 1, x: 10, y: 20 };
    const z = zoomAt(v, 2, 110, 70);
    // diagram point under (110,70) before: ((110-10)/1, (70-20)/1) = (100,50)
    expect((110 - z.x) / z.scale).toBeCloseTo(100, 6);
    expect((70 - z.y) / z.scale).toBeCloseTo(50, 6);
    expect(zoomAt(v, 1000, 0, 0).scale).toBe(MAX_SCALE);
    expect(zoomAt(v, 0.0001, 0, 0).scale).toBe(MIN_SCALE);
  });

  test("svgSize reads the viewBox, then width/height, then a default", async () => {
    const { svgSize } = await import("../components/mermaidZoom");
    expect(svgSize(`<svg id="a" viewBox="-8 -8 412.5 216"><g/></svg>`)).toEqual({ w: 412.5, h: 216 });
    expect(svgSize(`<svg width="300" height="100"></svg>`)).toEqual({ w: 300, h: 100 });
    expect(svgSize(`<svg></svg>`)).toEqual({ w: 800, h: 600 });
  });
});
