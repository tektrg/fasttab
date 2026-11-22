import { useEffect, useRef, useState } from "react";
import { Alert, Button, Group, List, Text, Textarea } from "@mantine/core";
import {
  compactHint,
  compactPolling,
  describeCompactJob,
  fetchCompactForRow,
  fetchCompactJob,
  flattenMessage,
  isCompactTerminal,
  parseCompactDraft,
  startCompact,
  unsentFollowUp,
  type CompactDraft,
  type CompactJob,
} from "../compactJob";
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
import { REMOTE_IMAGE_CAPTION, TOOL_MESSAGE_CAPTION, acceptsImages, isToolAgent } from "../messageGates";
import { imagesFromClipboard, uploadImages, useImageAttachments } from "../imageAttachments";
import { AttachImageButton, ImageAttachBar } from "./ImageAttachBar";
import { MicIcon, VoiceRecorderBar } from "./VoiceRecorderBar";
import { ActionButton } from "../ui/ActionButton";
import { IconButton } from "../ui/IconButton";
import { useVoiceInput } from "../voice/useVoiceInput";
import { appendTranscript } from "../voice/transcript";

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

/** The message composer (phase 9): board-to-pane text, the only
 *  non-destructive bulk verb.
 *
 *  Server resolves, UI renders: no client-side copy of the guards (no
 *  leading `/`, length cap) — the text goes up raw and the server's refusal
 *  renders verbatim. Targets show by label so the PO can never type into a
 *  pane they did not mean. Enter sends; Shift+Enter adds a line. A plain
 *  multi-line draft is sent as one line (newlines -> spaces: in a pane a
 *  newline IS the submit key, the server refuses it).
 *
 *  `/compact [instructions]` + optional lines 2..n (the follow-up) start a
 *  compact JOB instead (POST /api/session/compact: temporary Sonnet switch,
 *  compact, restore the model, send the follow-up — compactJob.ts). Its
 *  progress line polls until done/failed; a job already running or finished
 *  < 30 min ago shows when a single-row composer opens.
 *
 *  Result presentation, per the brief: sent → toast naming the pane;
 *  queued → SUCCESS saying it lands when the turn ends (never an
 *  invitation to re-send — that would double-send); NOT SUBMITTED → LOUD
 *  (a persistent red panel, not just the 2.5s toast): the message did not
 *  arrive and the PO must look.
 *
 *  `phone` (the row sheet's footer): ONE row — [field with the mic
 *  inside] [attach] [Send]. No visible label (the field keeps an accessible one), the
 *  "queues if the agent is busy" hint rides in the sent toast, and the
 *  "images only go to agents on this Mac" note shows only once an image was
 *  attached or pasted.
 *
 *  Poll-safety: the draft lives here, keyed by the parent when a reset is
 *  wanted — a 5s board refetch re-renders without remounting, so half-typed
 *  text survives. */
export function Composer({
  rows,
  initialText,
  onToast,
  onDone,
  phone,
}: {
  rows: BoardRow[];
  initialText?: string;
  onToast: (msg: string, ok: boolean) => void;
  onDone?: () => void;
  phone?: boolean;
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
  // Uploaded once per send, shared by every target row and the confirm-queue step.
  const [heldIds, setHeldIds] = useState<string[]>([]);
  const attach = useImageAttachments();
  // Phone: an image was pasted at an agent that cannot take one.
  const [attachTried, setAttachTried] = useState(false);
  // Compact jobs by row id (one per row: the server is single-flight per row).
  const [compactJobs, setCompactJobs] = useState<Record<string, CompactJob>>({});
  const inputRef = useRef<HTMLTextAreaElement>(null);
  // The transcript joins the end of whatever is typed; sending stays a tap.
  const voice = useVoiceInput({
    onText: (spoken) => {
      setText((current) => appendTranscript(current, spoken));
      inputRef.current?.focus();
    },
  });

  // Partitioned fresh each render from server-provided row status — the
  // refetch can end rows under us, and ended rows must never be POSTed.
  const evaled = evaluateMessageBulk(rows);
  const targets = evaled.ready;
  // One target on another machine = no images for the whole send (the server
  // would refuse that row); thumbnails already attached stay removable.
  const imagesAllowed = targets.every((m) => acceptsImages(m.row.derived));
  const imagesBlocked = !imagesAllowed && attach.images.length > 0;
  const canSend =
    !busy && (text.trim().length > 0 || attach.images.length > 0) && targets.length > 0 && !pending
    && !imagesBlocked;
  // Claude Desktop / CLI rows have no pane: say "session", not "pane".
  const anyInbox = targets.some((m) => messagesViaInbox(m.row.derived));
  const allInbox = targets.length > 0 && targets.every((m) => messagesViaInbox(m.row.derived));

  const announce = (label: string, res: SessionActionResult) => {
    if (res.ok) {
      onToast(
        isQueued(res)
          ? `queued to ${label} — lands when the turn ends. Do not re-send.`
          : phone ? `sent to ${label} — queues if the agent is busy` : `sent to ${label}`,
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

  const postAll = async (list: BoardRow[], confirm: boolean, body: string, attachments: string[]) => {
    const done: SentRow[] = [];
    const need: PendingRow[] = [];
    for (const row of list) {
      const label = rowLabel(row);
      const res = await sendMessage(row.rowId, body, { confirm, attachments });
      if (!confirm && res.needsConfirm) {
        need.push({ rowId: row.rowId, label, reason: res.reason || "confirm" });
      } else {
        done.push({ rowId: row.rowId, label, res });
        announce(label, res);
      }
    }
    return { done, need };
  };

  // A single-row composer shows that row's running (or < 30 min finished)
  // compact job when it opens.
  const soleRowId = rows.length === 1 ? rows[0].rowId : null;
  useEffect(() => {
    if (!soleRowId) return;
    let live = true;
    void fetchCompactForRow(soleRowId).then((job) => {
      if (live && job) setCompactJobs((prev) => (prev[job.rowId] ? prev : { ...prev, [job.rowId]: job }));
    });
    return () => {
      live = false;
    };
  }, [soleRowId]);

  // Poll every non-terminal job until it is done/failed.
  const activeIds = Object.values(compactJobs)
    .filter((j) => !isCompactTerminal(j))
    .map((j) => j.id)
    .sort()
    .join(",");
  useEffect(() => {
    if (!activeIds) return;
    let live = true;
    const timer = setInterval(() => {
      for (const id of activeIds.split(",")) {
        void fetchCompactJob(id).then((job) => {
          if (live && job) setCompactJobs((prev) => ({ ...prev, [job.rowId]: job }));
        });
      }
    }, compactPolling.intervalMs);
    return () => {
      live = false;
      clearInterval(timer);
    };
  }, [activeIds]);

  const sendCompact = async (draft: string, compact: CompactDraft) => {
    if (attach.images.length > 0) {
      onToast("images can't go with /compact — remove them or send them separately", false);
      return;
    }
    setBusy(true);
    setText("");
    setReport(null);
    setPending(null);
    let anyStarted = false;
    for (const m of targets) {
      const label = rowLabel(m.row);
      const res = await startCompact(m.row.rowId, compact);
      const job = res.job;
      if (job) setCompactJobs((prev) => ({ ...prev, [job.rowId]: job }));
      if (res.ok) {
        anyStarted = true;
      } else if (res.error === "job-active") {
        // The running job is shown; THIS draft (its follow-up too) never went
        // anywhere, so it comes back below.
        onToast(`a compact is already running for ${label}`, false);
      } else if (res.status === 0) {
        // Dropped connection: a job may exist — re-sending just answers 409.
        onToast(`compact may not have started for ${label}: ${res.error || "?"}`, false);
      } else {
        onToast(`compact refused for ${label}: ${res.error || "?"}`, false);
      }
    }
    setBusy(false);
    // No job started from this draft: put it back, follow-up included.
    if (!anyStarted) setText((current) => (current === "" ? draft : current));
    onDone?.();
  };

  /** An unsent follow-up back into the box (appended under a draft). */
  const putBack = (followUp: string) => {
    setText((current) => (current.trim() ? `${current}\n${followUp}` : followUp));
    inputRef.current?.focus();
  };

  /** Phone: no Shift+Enter on a touch keyboard, so a button adds line 2. */
  const insertNewline = () => {
    const el = inputRef.current;
    const at = el?.selectionStart ?? text.length;
    const end = el?.selectionEnd ?? at;
    setText(text.slice(0, at) + "\n" + text.slice(end));
    requestAnimationFrame(() => {
      if (!el) return;
      el.focus();
      el.setSelectionRange(at + 1, at + 1);
    });
  };
  const hint = targets.length > 0 ? compactHint(text, !!phone) : null;

  const send = async () => {
    if (!canSend) return;
    const compact = parseCompactDraft(text);
    if (compact) {
      await sendCompact(text, compact);
      return;
    }
    const body = flattenMessage(text);
    setBusy(true);
    let ids: string[] = [];
    if (attach.images.length > 0) {
      const up = await uploadImages(attach.images.map((i) => i.blob));
      if (!up.ok) {
        setBusy(false);
        onToast(`image not uploaded — nothing was sent: ${up.error}`, false);
        return;
      }
      ids = up.ids;
    }
    setHeld(body);
    setHeldIds(ids);
    setText(""); // before the await, not after — the empty box IS the receipt
    setReport(null);
    setPending(null);
    const { done, need } = await postAll(
      targets.map((m) => m.row),
      false,
      body,
      ids,
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
    } else {
      attach.clear(); // the images went (or may have) with the text
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
    const { done } = await postAll(list, true, held, heldIds);
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

  const sendOrConfirm = () => {
    if (pending) void confirmQueue();
    else void send();
  };
  const field = (
    <Textarea
      autosize
      minRows={1}
      maxRows={6}
      {...(phone
        ? {
            "aria-label": targets.length > 0 ? `Message ${targets.length === 1 ? rowLabel(targets[0].row) : `${targets.length} selected rows`}` : "Message",
            placeholder: targets.length > 0 ? "Message agent…" : "select one or more rows to enable",
            enterKeyHint: "send" as const,
            rightSectionPointerEvents: "auto" as const,
            rightSectionWidth: 44,
            rightSection:
              voice.phase === "idle" || voice.phase === "starting" ? (
                <IconButton
                  className="composer-mic"
                  aria-label="record voice message"
                  disabled={busy || !!pending || voice.phase === "starting" || targets.length === 0}
                  onClick={voice.start}
                >
                  <MicIcon />
                </IconButton>
              ) : null,
          }
        : {
            label:
              targets.length > 0
                ? `Message ${targets.length === 1 ? rowLabel(targets[0].row) : `${targets.length} selected rows`} — not destructive: queues on busy ${allInbox ? "sessions" : "panes"}`
                : "Message — select rows first",
            placeholder:
              targets.length > 0
                ? `to the ${allInbox ? "session" : "pane"}${targets.length > 1 ? "s" : ""} — Enter sends, Shift+Enter new line`
                : "select one or more rows to enable",
          })}
      ref={inputRef}
      value={text}
      disabled={targets.length === 0}
      onChange={(e) => setText(e.currentTarget.value)}
      onPaste={(e) => {
        const files = imagesFromClipboard(e.clipboardData);
        if (!imagesAllowed) {
          if (files.length) setAttachTried(true);
          return;
        }
        if (files.length) {
          e.preventDefault();
          void attach.add(files);
        }
      }}
      onKeyDown={(e) => {
        // Shift+Enter falls through: the textarea inserts the newline.
        if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
          e.preventDefault();
          sendOrConfirm();
        }
      }}
      style={{ flex: 1, minWidth: 0 }}
    />
  );

  return (
    <div className={phone ? "composer composer--phone" : "composer"} onClick={(e) => e.stopPropagation()}>
      {phone ? (
        <div className="composer-row">
          <div className="composer-field">{field}</div>
          {hint && (
            <IconButton
              className="composer-newline"
              aria-label="new line: message to send after the compact"
              disabled={busy || !!pending}
              onClick={insertNewline}
            >
              <NewlineIcon />
            </IconButton>
          )}
          {targets.length > 0 && imagesAllowed && (
            <AttachImageButton count={attach.images.length} disabled={busy || !!pending} onAdd={(files) => void attach.add(files)} />
          )}
          <ActionButton
            variant="primary"
            className="composer-send"
            disabled={!canSend && !pending}
            aria-busy={busy || undefined}
            onClick={sendOrConfirm}
          >
            {busy ? "Sending…" : pending ? `Confirm queue (${pending.length})` : "Send"}
          </ActionButton>
        </div>
      ) : (
        <Group gap="sm" align="flex-end" wrap="nowrap">
          {field}
          <Button color="blue" disabled={!canSend && !pending} loading={busy} onClick={sendOrConfirm}>
            {pending ? `Confirm queue (${pending.length})` : "Send"}
          </Button>
        </Group>
      )}
      {targets.length > 0 && (imagesAllowed || attach.images.length > 0) && (
        <ImageAttachBar
          images={attach.images}
          error={attach.error}
          disabled={busy || !!pending}
          canAdd={imagesAllowed}
          compact={phone}
          onAdd={(files) => void attach.add(files)}
          onRemove={attach.remove}
        />
      )}
      {(targets.length > 0 || voice.phase !== "idle") && <VoiceRecorderBar voice={voice} disabled={busy || !!pending} compact={phone} />}
      {targets.length > 0 && !imagesAllowed && (!phone || imagesBlocked || attachTried) && (
        <Text size="xs" c={imagesBlocked ? "red" : "dimmed"} mt={4} className="composer-remote-image-note">
          {imagesBlocked ? `${REMOTE_IMAGE_CAPTION} Remove the images to send.` : REMOTE_IMAGE_CAPTION}
        </Text>
      )}
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
      {hint && (
        <Text size="xs" c="dimmed" mt={4} className="composer-compact-hint">
          {hint}
        </Text>
      )}
      {Object.values(compactJobs).map((job) => {
        const unsent = unsentFollowUp(job);
        return (
        <Text
          key={job.id}
          size="xs"
          mt={4}
          c={job.state === "failed" ? "red" : job.state === "done" ? "green" : "dimmed"}
          className="composer-compact-progress"
          data-state={job.state}
          aria-live="polite"
        >
          {rows.length > 1 ? `${rowLabel(rows.find((r) => r.rowId === job.rowId) ?? rows[0])}: ` : ""}
          {describeCompactJob(job)}
          {unsent && (
            <Button
              variant="subtle"
              size="compact-xs"
              ml={6}
              aria-label="put the queued message back in the box"
              title={unsent}
              onClick={() => putBack(unsent)}
            >
              Put it back in the box
            </Button>
          )}
          {isCompactTerminal(job) && (
            <Button
              variant="subtle"
              size="compact-xs"
              ml={6}
              aria-label="dismiss compact status"
              onClick={() =>
                setCompactJobs((prev) => {
                  const next = { ...prev };
                  delete next[job.rowId];
                  return next;
                })
              }
            >
              ×
            </Button>
          )}
        </Text>
        );
      })}
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

/** ↵ (corner-down-left): the phone composer's "new line" button. */
function NewlineIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"
      strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M20 4v7a4 4 0 0 1-4 4H4" />
      <path d="M9 10l-5 5 5 5" />
    </svg>
  );
}
