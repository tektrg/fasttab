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
