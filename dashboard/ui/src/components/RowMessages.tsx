import { useCallback, useEffect, useRef, useState } from "react";
import { Loader } from "@mantine/core";
import { fetchSessionHistory, fmtAge } from "../api";
import type { BoardRow, SessionHistoryEntry } from "../types";
import { Composer } from "./Composer";

/** Everything the board ever sent this row, plus the box to send more.
 *
 *  Reads as a conversation: OLDEST AT TOP, newest against the composer, so
 *  the thing the PO just said sits where they are about to type. Ladder
 *  actions (stop/close/compact/…) are interleaved as one dim line each —
 *  they are context for why a worker went quiet, not turns in the
 *  conversation, and rendering them at message weight would drown the
 *  actual messages.
 *
 *  The three statuses are deliberately NOT cosmetic variants of each other:
 *  `sent` arrived, `queued` will arrive when the worker's turn ends (and
 *  re-sending would double-send), `failed` never arrived at all. A failed
 *  message that reads like a sent one is how a PO concludes a worker is
 *  ignoring them. */
export function RowMessages({
  row,
  onToast,
  onRefetch,
}: {
  row: BoardRow;
  onToast: (msg: string, ok: boolean) => void;
  onRefetch: () => void;
}) {
  const rowId = row.rowId;
  const [entries, setEntries] = useState<SessionHistoryEntry[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const logRef = useRef<HTMLDivElement | null>(null);
  const deadRef = useRef(false);

  const load = useCallback(async () => {
    setLoading(true);
    const res = await fetchSessionHistory(rowId);
    if (deadRef.current) return;
    setLoading(false);
    if (res.ok) {
      setError(null);
      setEntries(res.entries ?? []);
    } else {
      // Visible, never a silent blank: an empty log and an unreachable
      // server look identical otherwise, and only one of them means
      // "you have not talked to this worker".
      setError(res.error ?? "history unavailable");
      setEntries(null);
    }
  }, [rowId]);

  useEffect(() => {
    deadRef.current = false;
    setEntries(null);
    setError(null);
    void load();
    return () => {
      deadRef.current = true;
    };
  }, [load]);

  // Newest sits at the bottom, so that is where the log opens.
  useEffect(() => {
    const el = logRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [entries]);

  // The contract returns newest first; sort here rather than reverse, so a
  // server that ever changes order cannot silently invert the conversation.
  const ordered = [...(entries ?? [])].sort(
    (a, b) => a.ts - b.ts || a.id - b.id,
  );

  const afterSend = () => {
    void load();
    onRefetch();
  };

  return (
    <div className="rp-messages">
      <div className="rp-section-name rp-messages-head">
        messages
        {loading && <Loader size={12} />}
      </div>
      <div className="rp-msglog" ref={logRef}>
        {error && <div className="rp-msg-error">history unavailable — {error}</div>}
        {!error && entries === null && loading && (
          <div className="small">loading the message history…</div>
        )}
        {!error && entries !== null && ordered.length === 0 && (
          <div className="small">no messages to this worker yet</div>
        )}
        {ordered.map((e) => (
          <Entry key={e.id} entry={e} />
        ))}
      </div>
      <div className="rp-composerband">
        {/* Reused wholesale: it already empties the box on Enter, holds the
            text when a send fails, and runs the busy-pane confirm-queue
            flow. Re-implementing any of that here would fork three
            behaviours that took a phase to get right. */}
        <Composer rows={[row]} onToast={onToast} onDone={afterSend} />
      </div>
    </div>
  );
}

function Entry({ entry }: { entry: SessionHistoryEntry }) {
  const abs = new Date(entry.ts * 1000).toLocaleString();
  const age = fmtAge(Date.now() / 1000 - entry.ts);

  if (entry.action !== "message") {
    return (
      <div className="rp-msg-ladder" title={abs}>
        <span className="rp-msg-when">{age} ago</span> {entry.actor} ·{" "}
        {entry.action}
        {entry.status === "failed" ? " — failed" : ""}
        {entry.reason ? ` · ${entry.reason}` : ""}
      </div>
    );
  }

  const failed = entry.status === "failed";
  return (
    <div className={"rp-msg" + (failed ? " rp-msg-failed" : "")}>
      <div className="rp-msg-meta">
        <span className="rp-msg-when" title={abs}>
          {age} ago
        </span>{" "}
        <span className="rp-msg-actor">{entry.actor}</span>
        {entry.status === "sent" && (
          <span className="rp-msg-ok" title="sent — it arrived in the pane">
            {" "}
            ✓
          </span>
        )}
      </div>
      <div className="rp-msg-text">{entry.text ?? ""}</div>
      {entry.status === "queued" && (
        <div className="rp-msg-queued">
          ⏳ queued — lands when the turn ends. Do not re-send.
        </div>
      )}
      {failed && (
        <div className="rp-msg-failnote">
          FAILED — this message never arrived
          {entry.reason ? `: ${entry.reason}` : ""}
        </div>
      )}
      {entry.truncated && (
        <div className="rp-msg-trunc">
          only the first 80 characters were recorded — this message predates
          full-text logging
        </div>
      )}
    </div>
  );
}
