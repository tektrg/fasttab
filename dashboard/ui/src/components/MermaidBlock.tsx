import React, { Suspense, lazy, useEffect, useRef, useState, useSyncExternalStore } from "react";
import type { MermaidConfig } from "mermaid";

// Fullscreen pan/zoom viewer: its own small chunk, fetched on first expand.
const MermaidZoomOverlay = lazy(() => import("./MermaidZoomOverlay"));

/**
 * One ```mermaid fenced block from agent-authored markdown (Markdown.tsx's
 * `pre` override hands the block's text here).
 *
 * - **Lazy**: `mermaid` (~1 MB+) is a dynamic import, fetched only the first
 *   time a diagram block actually mounts. Messages without one never load it,
 *   so the main/phone bundle does not grow.
 * - **Untrusted input**: `securityLevel: "strict"`, `htmlLabels: false` (labels
 *   are SVG text, not HTML in a foreignObject), and the returned SVG is
 *   scrubbed again here (`scrubSvg`: no script/foreignObject/SMIL, no on*
 *   handlers, only `#`/http(s) links) before it is inserted.
 * - **Never blank, never crash**: while pending the raw source shows; a bad
 *   diagram shows the raw source plus a "diagram failed to render" note.
 * - **No flicker loop**: results are cached by (theme, content hash); a block
 *   renders once per final content, after a short quiet period so a message
 *   still streaming in does not trigger a render per poll.
 * - **Theme**: follows Mantine's `data-mantine-color-scheme` on <html> and
 *   re-renders when it flips (OS light/dark switch).
 * - **Phone**: the diagram keeps its natural size inside its own
 *   horizontal-scroll box (`.md-mermaid__scroll`), never widening the page.
 * - **Zoom**: tap the diagram or its ⤢ button for the fullscreen pan/zoom
 *   viewer (MermaidZoomOverlay, lazy). Inline never zooms or eats the wheel.
 */

type Scheme = "light" | "dark";
type Result = { ok: true; svg: string } | { ok: false };
type MermaidApi = {
  initialize: (config: MermaidConfig) => void;
  render: (id: string, text: string) => Promise<{ svg: string }>;
};

/** Quiet period before a block renders; a still-changing block waits. */
export const MERMAID_RENDER_DELAY_MS = 150;
const CACHE_LIMIT = 100;

// Diagram types whose SVG would otherwise shrink to the container width
// (`useMaxWidth`, mermaid's default) — unreadable on a phone. Natural size +
// the scroll box instead.
const DIAGRAMS = [
  "flowchart", "sequence", "gantt", "journey", "class", "state", "er", "pie",
  "quadrantChart", "requirement", "mindmap", "timeline", "gitGraph", "c4",
  "sankey", "xyChart", "block", "packet", "architecture", "kanban", "radar",
];

export function mermaidConfig(scheme: Scheme): MermaidConfig {
  const perDiagram = Object.fromEntries(DIAGRAMS.map((d) => [d, { useMaxWidth: false }]));
  return {
    ...perDiagram,
    startOnLoad: false,
    securityLevel: "strict",
    htmlLabels: false,
    flowchart: { useMaxWidth: false, htmlLabels: false },
    suppressErrorRendering: true,
    theme: scheme === "dark" ? "dark" : "default",
  } as MermaidConfig;
}

// --- color scheme (Mantine writes it on <html>; absent = light) ---

function readScheme(): Scheme {
  if (typeof document === "undefined") return "light";
  return document.documentElement.getAttribute("data-mantine-color-scheme") === "dark" ? "dark" : "light";
}

function subscribeScheme(onChange: () => void): () => void {
  if (typeof MutationObserver === "undefined" || typeof document === "undefined") return () => {};
  const obs = new MutationObserver(onChange);
  obs.observe(document.documentElement, { attributes: true, attributeFilter: ["data-mantine-color-scheme"] });
  return () => obs.disconnect();
}

function useColorScheme(): Scheme {
  return useSyncExternalStore(subscribeScheme, readScheme, () => "light");
}

// --- render pipeline (module-level: one mermaid instance, one queue) ---

let mermaidPromise: Promise<MermaidApi> | null = null;
let queue: Promise<unknown> = Promise.resolve();
let seq = 0;
const pending = new Map<string, Promise<Result>>();
const settled = new Map<string, Result>();

function loadMermaid(): Promise<MermaidApi> {
  if (!mermaidPromise) {
    mermaidPromise = import("mermaid").then((m) => m.default as unknown as MermaidApi);
    // A failed chunk fetch (offline, redeploy) must not stick forever.
    mermaidPromise.catch(() => {
      mermaidPromise = null;
    });
  }
  return mermaidPromise;
}

/** FNV-1a, 32-bit, hex — a cache key, not a security boundary. */
function hashString(s: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return (h >>> 0).toString(16);
}

function cacheKey(source: string, scheme: Scheme): string {
  return `${scheme}:${hashString(source)}:${source.length}`;
}

function remember(key: string, result: Result) {
  settled.set(key, result);
  if (settled.size > CACHE_LIMIT) settled.delete(settled.keys().next().value as string);
}

function renderDiagram(source: string, scheme: Scheme): Promise<Result> {
  const key = cacheKey(source, scheme);
  const done = settled.get(key);
  if (done) return Promise.resolve(done);
  const inflight = pending.get(key);
  if (inflight) return inflight;

  // mermaid.initialize is global config, so initialize + render run as one
  // step of a single queue — a theme flip mid-render can't cross wires.
  const job: Promise<Result> = queue.then(async () => {
    let mermaid: MermaidApi;
    try {
      mermaid = await loadMermaid();
    } catch {
      return { ok: false as const, transient: true };
    }
    const id = `mmd-${hashString(source)}-${++seq}`;
    try {
      mermaid.initialize(mermaidConfig(scheme));
      const { svg } = await mermaid.render(id, source);
      const clean = scrubSvg(svg);
      return clean ? { ok: true as const, svg: clean } : { ok: false as const };
    } catch {
      return { ok: false as const };
    } finally {
      // mermaid renders in a temporary node under <body>; on a parse error it
      // can be left behind.
      document.getElementById(id)?.remove();
      document.getElementById(`d${id}`)?.remove();
    }
  }).then((r) => {
    pending.delete(key);
    // A failed lazy-load is transient (retry next mount); a parse error is not.
    if (!("transient" in r)) remember(key, r);
    return r.ok ? r : { ok: false as const };
  });
  pending.set(key, job);
  queue = job.catch(() => {});
  return job;
}

/** Test-only: forget cached results so each test renders fresh. */
export function __resetMermaidCacheForTests() {
  settled.clear();
  pending.clear();
}

// --- SVG scrub (defense in depth on top of mermaid's strict mode) ---

const DROP_TAGS = new Set([
  "script", "foreignobject", "iframe", "object", "embed", "link", "meta", "base",
  "form", "input", "button", "textarea", "animate", "set", "animatemotion", "animatetransform", "handler",
]);
const URL_ATTRS = new Set(["href", "xlink:href", "src", "action", "formaction"]);
const SAFE_URL_RE = /^(#|https?:)/i;

/** Returns the cleaned `<svg>` markup, or null when there is no svg at all.
 *  Parsed in an inert DOMParser document, so nothing executes while cleaning. */
export function scrubSvg(svg: string): string | null {
  const doc = new DOMParser().parseFromString(`<!doctype html><body>${svg}`, "text/html");
  const root = doc.body.querySelector("svg");
  if (!root) return null;
  for (const el of Array.from(root.querySelectorAll("*"))) {
    if (DROP_TAGS.has(el.tagName.toLowerCase())) el.remove();
  }
  for (const el of [root, ...Array.from(root.querySelectorAll("*"))]) {
    for (const attr of Array.from(el.attributes)) {
      const name = attr.name.toLowerCase();
      const value = attr.value.replace(/[\u0000- ]/g, "");
      if (name.startsWith("on")) el.removeAttribute(attr.name);
      else if (URL_ATTRS.has(name) && !SAFE_URL_RE.test(value)) el.removeAttribute(attr.name);
      else if (name === "style" && /javascript:|expression\(/i.test(value)) el.removeAttribute(attr.name);
    }
  }
  return root.outerHTML;
}

// --- component ---

function SourceBlock({ source }: { source: string }) {
  return (
    <pre className="md-pre">
      <code className="language-mermaid">{source}</code>
    </pre>
  );
}

export function MermaidBlock({ source }: { source: string }): React.ReactElement {
  const scheme = useColorScheme();
  const key = cacheKey(source, scheme);
  const [zoomOpen, setZoomOpen] = useState(false);
  const expandRef = useRef<HTMLButtonElement>(null);
  const [shown, setShown] = useState<{ key: string; result: Result } | null>(() => {
    const done = settled.get(key);
    return done ? { key, result: done } : null;
  });

  useEffect(() => {
    const done = settled.get(key);
    if (done) {
      setShown({ key, result: done });
      return;
    }
    let cancelled = false;
    const timer = setTimeout(() => {
      void renderDiagram(source, scheme).then((result) => {
        if (!cancelled) setShown({ key, result });
      });
    }, MERMAID_RENDER_DELAY_MS);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
    // `key` already encodes source + scheme.
  }, [key]);

  const current = shown?.key === key ? shown.result : settled.get(key);

  if (current && !current.ok) {
    return (
      <div className="md-mermaid md-mermaid--failed">
        <SourceBlock source={source} />
        <div className="md-mermaid__note">diagram failed to render</div>
      </div>
    );
  }

  // Pending with a previous good diagram on screen (theme flip, content
  // edit): keep showing it rather than flashing back to source.
  const svg = current?.ok ? current.svg : shown?.result.ok ? shown.result.svg : null;
  if (!svg) return <SourceBlock source={source} />;

  return (
    <div className="md-mermaid">
      <div className="md-mermaid__frame">
        {/* SVG from mermaid strict mode, re-scrubbed by scrubSvg above.
            Inline = scroll box only: no wheel/pinch handling here, so the
            page scrolls normally over it; zoom lives in the overlay. */}
        <div
          className="md-mermaid__scroll"
          onClick={(e) => {
            if (!(e.target as Element).closest?.("a")) setZoomOpen(true);
          }}
          dangerouslySetInnerHTML={{ __html: svg }}
        />
        <button
          type="button"
          ref={expandRef}
          className="md-mermaid__expand"
          aria-label="Expand diagram"
          title="Expand"
          onClick={() => setZoomOpen(true)}
        >
          ⤢
        </button>
      </div>
      {zoomOpen ? (
        <Suspense fallback={null}>
          <MermaidZoomOverlay svg={svg} returnFocus={expandRef.current} onClose={() => setZoomOpen(false)} />
        </Suspense>
      ) : null}
      <details className="md-mermaid__source">
        <summary>show source</summary>
        <SourceBlock source={source} />
      </details>
    </div>
  );
}
