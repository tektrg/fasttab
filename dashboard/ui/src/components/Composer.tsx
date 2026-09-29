import { useState } from "react";
import { Alert, Button, Group, List, Text, TextInput } from "@mantine/core";
import type { BoardRow } from "../types";
import {
  evaluateMessageBulk,
  isNotSubmitted,
  isQueued,
  isRefusedBeforeTyping,
  rowLabel,
  sendMessage,
  type SessionActionResult,
} from "../sessionActions";
import { INBOX_CAPTION, WAKE_CAPTION, messagesViaInbox, wakesToMessage } from "../openInClaude";
import { TOOL_MESSAGE_CAPTION, isToolAgent } from "../messageGates";

interface SentRow {
  rowId: string;
  label: string;
  res: SessionActionResult;
}

interface PendingRow {
  rowId: string;
  label: string;
  reason: string;
}

/** The one-line message composer (phase 9): board-to-pane text, the only
 *  non-destructive bulk verb.
 *
 *  Server resolves, UI renders: no client-side copy of the guards (no
 *  newlines, no leading `/`, length cap) — the text goes up raw and the
 *  server's refusal renders verbatim. Targets show by label so the PO can
 *  never type into a pane they did not mean. Enter sends, like the
 *  question panel's text field.
 *
 *  Result presentation, per the brief: sent → toast naming the pane;
 *  queued → SUCCESS saying it lands when the turn ends (never an
 *  invitation to re-send — that would double-send); NOT SUBMITTED → LOUD
 *  (a persistent red panel, not just the 2.5s toast): the message did not
 *  arrive and the PO must look.
 *
 *  Poll-safety: the draft lives here, keyed by the parent when a reset is
 *  wanted — a 5s board refetch re-renders without remounting, so half-typed
 *  text survives. */
export function Composer({
  rows,
  initialText,
  onToast,
  onDone,
}: {
  rows: BoardRow[];
  initialText?: string;
  onToast: (msg: string, ok: boolean) => void;
  onDone?: () => void;
}) {
  const [text, setText] = useState(initialText ?? "");
  // The in-flight text, held apart from the box. Enter empties the box at
  // once — a send takes 4-6s server-side (pane read, sleep, type, verify),
  // and a box that still holds the text through that silence is how the
  // same line gets sent twice. The confirm-queue step and the NOT SUBMITTED
  // recovery both read this copy, so clearing loses nothing.
  const [held, setHeld] = useState("");
  const [busy, setBusy] = useState(false);
  const [pending, setPending] = useState<PendingRow[] | null>(null);
  const [report, setReport] = useState<SentRow[] | null>(null);

  // Partitioned fresh each render from server-provided row status — the
  // refetch can end rows under us, and ended rows must never be POSTed.
  const evaled = evaluateMessageBulk(rows);
  const targets = evaled.ready;
  const canSend =
    !busy && text.trim().length > 0 && targets.length > 0 && !pending;
  // Claude Desktop / CLI rows have no pane: say "session", not "pane".
  const anyInbox = targets.some((m) => messagesViaInbox(m.row.derived));
  const allInbox = targets.length > 0 && targets.every((m) => messagesViaInbox(m.row.derived));

  const announce = (label: string, res: SessionActionResult) => {
    if (res.ok) {
      onToast(
        isQueued(res)
          ? `queued to ${label} — lands when the turn ends. Do not re-send.`
          : `sent to ${label}`,
        true,
      );
    } else if (res.needsConfirm) {
      onToast(`confirm needed: ${label}`, false);
    } else if (isNotSubmitted(res)) {
      onToast(
        `NOT SUBMITTED to ${label} — the message did not arrive: ${res.error}`,
        false,
      );
    } else if (isRefusedBeforeTyping(res)) {
      onToast(`refused for ${label}: ${res.error || res.reason || "?"}`, false);
    } else {
      // Not provably untyped (mid-sequence error, dropped connection): the
      // text may have landed, so never word it as a clean refusal.
      onToast(
        `send to ${label} failed partway — it may have arrived; check the session before retrying: ${res.error || res.reason || "?"}`,
        false,
      );
    }
  };

  const postAll = async (list: BoardRow[], confirm: boolean, body: string) => {
    const done: SentRow[] = [];
    const need: PendingRow[] = [];
    for (const row of list) {
      const label = rowLabel(row);
      const res = await sendMessage(row.rowId, body, { confirm });
      if (!confirm && res.needsConfirm) {
        need.push({ rowId: row.rowId, label, reason: res.reason || "confirm" });
      } else {
        done.push({ rowId: row.rowId, label, res });
        announce(label, res);
      }
    }
    return { done, need };
  };

  const send = async () => {
    if (!canSend) return;
    const body = text.trim();
    setHeld(body);
    setText(""); // before the await, not after — the empty box IS the receipt
    setBusy(true);
    setReport(null);
    setPending(null);
    const { done, need } = await postAll(
      targets.map((m) => m.row),
      false,
      body,
    );
    setBusy(false);
    setReport(done);
    if (need.length > 0) setPending(need);
    // Every row positively reported `typed:false` (e.g. a control character):
    // nothing reached a pane, so the text goes straight back — a refusal must
    // not cost the typed line. Anything else stays out of the box: NOT
    // SUBMITTED text may still sit in a pane's input, and a mid-sequence
    // error or dropped connection may have delivered it — a restored box
    // would double-send on the next Enter.
    if (need.length === 0 && done.every((r) => isRefusedBeforeTyping(r.res))) {
      setText((current) => (current === "" ? body : current));
    }
    onDone?.();
  };

  const confirmQueue = async () => {
    if (!pending || busy) return;
    setBusy(true);
    const byId = new Map(rows.map((r) => [r.rowId, r]));
    const list = pending
      .map((p) => byId.get(p.rowId))
      .filter((r): r is BoardRow => !!r);
    const { done } = await postAll(list, true, held);
    setBusy(false);
    setPending(null);
    setReport((prev) => [...(prev ?? []), ...done]);
    onDone?.();
  };

  const dismiss = () => {
    setReport(null);
    setPending(null);
  };

  const notSubmitted = (report ?? []).filter((r) => isNotSubmitted(r.res));
  const queued = (report ?? []).filter((r) => isQueued(r.res));

  return (
    <div className="composer" onClick={(e) => e.stopPropagation()}>
      <Group gap="sm" align="flex-end" wrap="nowrap">
        <TextInput
          label={
            targets.length > 0
              ? `Message ${targets.length === 1 ? rowLabel(targets[0].row) : `${targets.length} selected rows`} — not destructive: queues on busy ${allInbox ? "sessions" : "panes"}`
              : "Message — select rows first"
          }
          placeholder={
            targets.length > 0
              ? `one line to the ${allInbox ? "session" : "pane"}${targets.length > 1 ? "s" : ""} — Enter sends`
              : "select one or more rows to enable"
          }
          value={text}
          disabled={targets.length === 0}
          onChange={(e) => setText(e.currentTarget.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              if (pending) void confirmQueue();
              else void send();
            }
          }}
          style={{ flex: 1, minWidth: 0 }}
        />
        <Button
          color="blue"
          disabled={!canSend && !pending}
          loading={busy}
          onClick={() => {
            if (pending) void confirmQueue();
            else void send();
          }}
        >
          {pending ? `Confirm queue (${pending.length})` : "Send"}
        </Button>
      </Group>
      {anyInbox && (
        <Text size="xs" c="dimmed" mt={4} className="composer-inbox-note">
          {INBOX_CAPTION}
        </Text>
      )}
      {targets.some((m) => isToolAgent(m.row.derived)) && (
        <Text size="xs" c="dimmed" mt={4} className="composer-tool-note">
          {TOOL_MESSAGE_CAPTION}
        </Text>
      )}
      {targets.some((m) => wakesToMessage(m.row)) && (
        <Text size="xs" c="dimmed" mt={4} className="composer-wake-note">
          {WAKE_CAPTION}
        </Text>
      )}
      {evaled.refused.length > 0 && (
        <Text size="xs" c="dimmed" mt={4}>
          {evaled.refused.length} ended{" "}
          {evaled.refused.length === 1 ? "row" : "rows"} will be refused,
          never sent:{" "}
          {evaled.refused.map((m) => rowLabel(m.row)).join(", ")}
        </Text>
      )}

      {pending && (
        <Alert color="yellow" title={`${pending.length} busy — confirm each queue`} mt="sm">
          <List size="sm">
            {pending.map((p) => (
              <List.Item key={p.rowId}>
                <strong>{p.label}</strong> — {p.reason}
              </List.Item>
            ))}
          </List>
        </Alert>
      )}

      {notSubmitted.length > 0 && (
        <Alert color="red" title="NOT SUBMITTED — the message did not arrive" mt="sm">
          <List size="sm">
            {notSubmitted.map((r) => (
              <List.Item key={r.rowId}>
                <strong>{r.label}</strong> — {r.res.error} Look at the pane
                before retrying.
              </List.Item>
            ))}
          </List>
          {/* The box was emptied on Enter, so a failed send would otherwise
              cost the typed line. It is held here, verbatim, one click from
              being back in the box — never re-sent automatically. */}
          {held && (
            <Text size="sm" mt={6}>
              Your text: “{held}”{" "}
              <Button
                variant="subtle"
                size="compact-xs"
                onClick={() => setText(held)}
              >
                Put it back in the box
              </Button>
            </Text>
          )}
        </Alert>
      )}

      {report && report.length > 0 && (
        <Alert
          color={notSubmitted.length > 0 ? "red" : "green"}
          title={`send report — ${report.filter((r) => r.res.ok).length} of ${report.length} ok`}
          mt="sm"
        >
          <List size="sm">
            {report.map((r) => (
              <List.Item key={r.rowId}>
                <strong>{r.label}</strong> —{" "}
                {r.res.ok
                  ? isQueued(r.res)
                    ? `✓ queued — lands when the turn ends. Do not re-send.`
                    : `✓ ${r.res.state ?? "sent"}`
                  : `✗ ${r.res.error || r.res.reason || "?"}`}
              </List.Item>
            ))}
          </List>
          {queued.length > 0 && (
            <Text size="sm" mt={4}>
              Queued messages are logged on the server — a retry would send
              twice.
            </Text>
          )}
          <Button variant="subtle" size="xs" mt={6} onClick={dismiss}>
            Dismiss
          </Button>
        </Alert>
      )}
    </div>
  );
}
