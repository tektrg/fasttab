import React from "react";

/**
 * Minimal, safe Markdown renderer for the plan card and latest-message
 * display (no markdown library is in `package.json` — see AGENTS.md's rule
 * against pulling one in for a single small need). Every character of the
 * source text ends up as a React text node, never `dangerouslySetInnerHTML`
 * — an untrusted string containing a raw `<img onerror=...>` tag renders as
 * literal, inert text, exactly like AgentBar's own Markdown/ (input capped
 * upstream, only http/https/mailto links are clickable).
 *
 * Supports: headings ("#" through "######"), unordered lists ("-" or "*"),
 * paragraphs, and inline bold, italic, code, and [text](url) links
 * (http(s)/mailto only — anything else is left as plain text, never a
 * clickable javascript:/data: URL).
 */

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
    else if (m[3] !== undefined) parts.push(<code key={`${key}-c${i++}`}>{m[3]}</code>);
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

/** Rendered markdown as a plain array of block nodes — exported so callers
 *  needing a raw list (rather than the `<Markdown>` wrapper) can reuse it. */
export function renderMarkdownBlocks(text: string): React.ReactNode[] {
  const lines = text.split("\n");
  const blocks: React.ReactNode[] = [];
  let i = 0;
  let key = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) {
      i++;
      continue;
    }
    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    if (heading) {
      const level = Math.min(heading[1].length + 2, 6); // demote — this text never outranks the card's own headings
      const tag = `h${level}` as keyof React.JSX.IntrinsicElements;
      blocks.push(React.createElement(tag, { key: `b${key}` }, renderInline(heading[2], `h${key}`)));
      key++;
      i++;
      continue;
    }
    if (/^\s*[-*]\s+/.test(line)) {
      const items: string[] = [];
      while (i < lines.length && /^\s*[-*]\s+/.test(lines[i])) {
        items.push(lines[i].replace(/^\s*[-*]\s+/, ""));
        i++;
      }
      blocks.push(
        <ul key={`b${key}`}>
          {items.map((it, idx) => (
            <li key={idx}>{renderInline(it, `li${key}-${idx}`)}</li>
          ))}
        </ul>,
      );
      key++;
      continue;
    }
    const para: string[] = [];
    while (i < lines.length && lines[i].trim()) {
      para.push(lines[i]);
      i++;
    }
    blocks.push(<p key={`b${key}`}>{renderInline(para.join(" "), `p${key}`)}</p>);
    key++;
  }
  return blocks;
}

export function Markdown({ text }: { text: string }): React.ReactElement {
  return <>{renderMarkdownBlocks(text)}</>;
}
