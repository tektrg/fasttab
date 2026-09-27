import React from "react";
import ReactMarkdown, { type Components } from "react-markdown";
import remarkGfm from "remark-gfm";

/**
 * Markdown (plan card, latest-message, and other agent-authored content).
 * Full GFM via `react-markdown` + `remark-gfm` — headings, emphasis, inline
 * code, fenced code blocks, lists (incl. nested + task lists), tables,
 * blockquotes, links, hr, strikethrough, autolinks.
 *
 * Safety, unchanged from the old hand-written renderer: `react-markdown` is
 * used WITHOUT `rehype-raw`, so raw HTML in the source is never parsed into
 * real elements — it lands as escaped literal text (mirrors the previous
 * behavior exactly; see `__tests__/markdown.test.tsx`, still green). Image
 * markdown (`![alt](src)`) never becomes a real `<img>` — only its alt text
 * shows, dropped explicitly below. Links are allowlisted to http(s)/mailto;
 * anything else (javascript:, data:, vbscript:, disguised/whitespace/entity
 * tricks around the scheme) renders as inert text, not a clickable anchor.
 */

const SAFE_HREF_RE = /^(https?:|mailto:)/i;

function isSafeHref(href: string | undefined): boolean {
  if (!href) return false;
  return SAFE_HREF_RE.test(href.trim());
}

/** Demote headings — agent-authored markdown must never outrank the card's
 *  own chrome (h1..h6 -> h3..h6, capped), same rule the old hand-written
 *  renderer applied. */
function heading(level: number) {
  const tag = `h${Math.min(level + 2, 6)}` as keyof React.JSX.IntrinsicElements;
  return ({ children }: { children?: React.ReactNode }) => React.createElement(tag, null, children);
}

const blockComponents: Components = {
  h1: heading(1),
  h2: heading(2),
  h3: heading(3),
  h4: heading(4),
  h5: heading(5),
  h6: heading(6),
  a: ({ href, children, ...props }) => {
    if (!isSafeHref(href)) return <>{children}</>;
    return (
      <a {...props} href={href} target="_blank" rel="noreferrer noopener">
        {children}
      </a>
    );
  },
  // Image markdown is not supported — never becomes a real <img>; only the
  // alt text (if any) is shown, so the source isn't silently dropped.
  img: ({ alt }) => <>{alt ?? ""}</>,
  table: ({ children }) => (
    <div className="md-table-scroll">
      <table className="md-table">{children}</table>
    </div>
  ),
  pre: ({ children }) => <pre className="md-pre">{children}</pre>,
  code: ({ className, children, ...props }) => {
    // Fenced blocks carry a `language-xxx` className from remark; inline
    // code does not — this is the same signal react-markdown v9+ exposes.
    const isBlock = /language-/.test(className ?? "");
    return (
      <code className={isBlock ? className : "md-inline-code"} {...props}>
        {children}
      </code>
    );
  },
  li: ({ className, children, ...props }) => (
    <li className={className ? `${className} md-li` : "md-li"} {...props}>
      {children}
    </li>
  ),
};

/** The full block-level renderer: headings, lists, tables, code blocks,
 *  blockquotes, hr — everything. Use for multi-line agent content. */
export function Markdown({ text }: { text: string }): React.ReactElement {
  return (
    <ReactMarkdown remarkPlugins={[remarkGfm]} components={blockComponents}>
      {text}
    </ReactMarkdown>
  );
}

// --- Inline-only variant, for one-line contexts (a question's title, a
// short label) where a heading/list/table would break the layout. Kept as
// a small hand-rolled renderer (bold/italic/code/links only, same safety
// rules) rather than pulling react-markdown's block machinery in for a
// single line of text. ---

const LINK_RE = /\[([^\]]+)\]\((https?:\/\/[^\s)]+|mailto:[^\s)]+)\)/g;
const EMPHASIS_RE = /(\*\*([^*]+)\*\*|`([^`]+)`|\*([^*]+)\*|_([^_]+)_)/g;

function renderEmphasis(text: string, key: string): React.ReactNode {
  const parts: React.ReactNode[] = [];
  let last = 0;
  let m: RegExpExecArray | null;
  let i = 0;
  EMPHASIS_RE.lastIndex = 0;
  while ((m = EMPHASIS_RE.exec(text))) {
    if (m.index > last) parts.push(text.slice(last, m.index));
    if (m[2] !== undefined) parts.push(<strong key={`${key}-b${i++}`}>{m[2]}</strong>);
    else if (m[3] !== undefined) parts.push(<code key={`${key}-c${i++}`} className="md-inline-code">{m[3]}</code>);
    else if (m[4] !== undefined) parts.push(<em key={`${key}-i${i++}`}>{m[4]}</em>);
    else if (m[5] !== undefined) parts.push(<em key={`${key}-i${i++}`}>{m[5]}</em>);
    last = m.index + m[0].length;
  }
  if (last < text.length) parts.push(text.slice(last));
  return <React.Fragment key={key}>{parts}</React.Fragment>;
}

function renderInline(text: string, keyPrefix: string): React.ReactNode {
  const nodes: React.ReactNode[] = [];
  let lastIndex = 0;
  let m: RegExpExecArray | null;
  let idx = 0;
  LINK_RE.lastIndex = 0;
  while ((m = LINK_RE.exec(text))) {
    if (m.index > lastIndex) {
      nodes.push(renderEmphasis(text.slice(lastIndex, m.index), `${keyPrefix}-t${idx++}`));
    }
    nodes.push(
      <a key={`${keyPrefix}-a${idx++}`} href={m[2]} target="_blank" rel="noreferrer noopener">
        {m[1]}
      </a>,
    );
    lastIndex = m.index + m[0].length;
  }
  if (lastIndex < text.length) {
    nodes.push(renderEmphasis(text.slice(lastIndex), `${keyPrefix}-t${idx++}`));
  }
  return nodes;
}

/** One-line / inline-only markdown: bold, italic, inline code, links — no
 *  headings, lists, tables or code fences. For question text, option
 *  descriptions, and other short snippets that must never grow block
 *  structure or wrap-break a compact layout. */
export function MarkdownInline({ text }: { text: string }): React.ReactElement {
  return <>{renderInline(text, "mi")}</>;
}
