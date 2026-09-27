/**
 * Markdown (plan card + latest-message renderer, phase 2b QA). Everything
 * lands as a React text node, never `dangerouslySetInnerHTML` — this file
 * pins the specific bypasses a threat model worries about: disguised
 * `javascript:`/`data:`/`vbscript:` links, mixed-case or whitespace/entity
 * tricks around the scheme, raw HTML inside a "code" span, and image
 * markdown (unsupported — never becomes a real `<img>`).
 */
import { describe, expect, test } from "bun:test";
import { createRoot } from "react-dom/client";
import { act } from "react";
import { Markdown } from "../components/Markdown";

function render(text: string): HTMLElement {
  const host = document.createElement("div");
  document.body.appendChild(host);
  const root = createRoot(host);
  act(() => {
    root.render(<Markdown text={text} />);
  });
  return host;
}

describe("Markdown link scheme filtering", () => {
  test("http/https/mailto links render as real, clickable anchors", () => {
    const host = render("[click me](https://example.com/x)");
    const a = host.querySelector("a");
    expect(a).not.toBe(null);
    expect(a!.getAttribute("href")).toBe("https://example.com/x");
    expect(a!.getAttribute("rel")).toContain("noopener");
  });

  for (const scheme of [
    "javascript:alert(1)",
    "JavaScript:alert(1)",
    "JAVASCRIPT:alert(1)",
    "vbscript:msgbox(1)",
    "data:text/html,<script>alert(1)</script>",
    "javascript:/*https://*/alert(1)",
    " javascript:alert(1)",
    "java\tscript:alert(1)",
    "javascript&colon;alert(1)",
  ]) {
    test(`disguised scheme "${scheme}" never becomes a clickable link`, () => {
      const host = render(`[click me](${scheme})`);
      const a = host.querySelector("a");
      expect(a).toBe(null);
      // Fails closed: the text stays visible as inert text, not silently dropped.
      expect(host.textContent).toContain("click me");
    });
  }

  test("a link whose label contains markup shows as literal text, not injected HTML", () => {
    const host = render('[<img src=x onerror=alert(1)>](https://example.com)');
    expect(host.querySelector("img")).toBe(null);
    expect(host.textContent).toContain("<img src=x onerror=alert(1)>");
  });
});

describe("Markdown image / raw HTML handling", () => {
  test("image markdown is not supported — never becomes a real <img>", () => {
    const host = render('![alt](https://example.com/x.png "onerror payload")');
    expect(host.querySelector("img")).toBe(null);
  });

  test("a raw <img onerror> tag inside inline code stays literal text", () => {
    const sentinel = '<img src=x onerror="window.__pwned = true">';
    const host = render("Use `" + sentinel + "` as a literal string.");
    expect(host.querySelector("img")).toBe(null);
    expect((window as unknown as { __pwned?: boolean }).__pwned).toBeUndefined();
    expect(host.textContent).toContain(sentinel);
  });

  test("a raw <script> tag anywhere in the text never executes and never renders as an element", () => {
    const host = render("<script>window.__pwned2 = true</script>");
    expect(host.querySelector("script")).toBe(null);
    expect((window as unknown as { __pwned2?: boolean }).__pwned2).toBeUndefined();
  });
});

describe("Markdown GFM tables", () => {
  test("a realistic Claude-style table renders headers, alignment, and inline markdown in cells", () => {
    const md = [
      "| File | Status | Coverage | Notes |",
      "| --- | :---: | ---: | :--- |",
      "| `Markdown.tsx` | **done** | 92% | uses `remark-gfm` |",
      "| `PhoneInbox.tsx` | *pending* | 10% | needs `filterAgents` |",
    ].join("\n");
    const host = render(md);
    const table = host.querySelector("table.md-table");
    expect(table).not.toBe(null);
    const headers = Array.from(host.querySelectorAll("th")).map((th) => th.textContent);
    expect(headers).toEqual(["File", "Status", "Coverage", "Notes"]);
    const bodyRows = host.querySelectorAll("tbody tr");
    expect(bodyRows.length).toBe(2);
    const firstRowCells = Array.from(bodyRows[0].querySelectorAll("td"));
    expect(firstRowCells[0].querySelector("code")?.textContent).toBe("Markdown.tsx");
    expect(firstRowCells[1].querySelector("strong")?.textContent).toBe("done");
    expect(firstRowCells[3].querySelector("code")?.textContent).toBe("remark-gfm");
    expect(host.querySelector(".md-table-scroll")).not.toBe(null);
  });

  test("escaped pipes inside a cell do not split the column", () => {
    const md = "| A | B |\n| --- | --- |\n| a \\| b | c |";
    const host = render(md);
    const cells = host.querySelectorAll("tbody td");
    expect(cells.length).toBe(2);
    expect(cells[0].textContent).toBe("a | b");
  });

  test("a row with a missing cell still renders without throwing", () => {
    const md = "| A | B | C |\n| --- | --- | --- |\n| only one |";
    const host = render(md);
    expect(host.querySelector("table")).not.toBe(null);
    const cells = host.querySelectorAll("tbody td");
    expect(cells.length).toBe(3);
    expect(cells[0].textContent).toBe("only one");
    expect(cells[1].textContent).toBe("");
  });

  test("a row with an extra cell does not throw and keeps the header count", () => {
    const md = "| A | B |\n| --- | --- |\n| x | y | z (extra) |";
    const host = render(md);
    const headerCells = host.querySelectorAll("thead th");
    expect(headerCells.length).toBe(2);
  });
});

describe("Markdown GFM: fenced code, task lists, headings, blockquotes", () => {
  test("a fenced code block renders as monospace inside a scroll container", () => {
    const md = "```ts\nconst x = 1;\nfunction longLineThatWouldOverflowAPhoneWidthEasily() {}\n```";
    const host = render(md);
    const pre = host.querySelector("pre.md-pre");
    expect(pre).not.toBe(null);
    expect(pre!.querySelector("code")?.textContent).toContain("const x = 1;");
  });

  test("task list items render as disabled checkboxes, not literal [x] text", () => {
    const md = "- [x] done thing\n- [ ] todo thing";
    const host = render(md);
    const boxes = host.querySelectorAll('input[type="checkbox"]');
    expect(boxes.length).toBe(2);
    expect((boxes[0] as HTMLInputElement).checked).toBe(true);
    expect((boxes[1] as HTMLInputElement).checked).toBe(false);
  });

  test("nested lists render nested <ul>/<ol>", () => {
    const md = "- a\n  - a1\n  - a2\n- b";
    const host = render(md);
    const outer = host.querySelector("ul");
    expect(outer?.querySelector("ul")).not.toBe(null);
  });

  test("headings demote so agent text never outranks card chrome", () => {
    const host = render("# Title");
    expect(host.querySelector("h1")).toBe(null);
    expect(host.querySelector("h3")).not.toBe(null);
  });

  test("blockquote and hr render", () => {
    const host = render("> quoted\n\n---\n");
    expect(host.querySelector("blockquote")).not.toBe(null);
    expect(host.querySelector("hr")).not.toBe(null);
  });

  test("raw HTML embedded in the text still never becomes a real element (GFM path)", () => {
    const host = render("before\n\n<div>injected</div>\n\nafter");
    expect(host.querySelector("div")).toBe(null);
    expect(host.textContent).toContain("before");
    expect(host.textContent).toContain("after");
  });
});
