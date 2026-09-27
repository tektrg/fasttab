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
