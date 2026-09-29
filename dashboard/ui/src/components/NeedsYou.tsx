import { useState } from "react";
import { Badge, Button, Chip, Group, Paper, Stack, Text, TextInput } from "@mantine/core";
import type { NeedsYouRow, PickerQuestion, QuestionPreview } from "../types";
import { answerQuestion, fmtAge } from "../api";
import { ensureNotiPerm } from "../alerts";
import { KindBadge } from "./Severity";
import { MarkdownInline } from "./Markdown";
import { PanelessPrompt } from "./HookRequestCard";

// Phase 5: display-only box for the hook's question preview. Plain text, NO
// buttons, NO Confirm — the hook copy comes from raw tool input and can never
// satisfy the server's exact-match refusal gate, so it must never be
// sendable. The sweep's parsed picker replaces this within one interval.
// BeautifulUI (04) Approval Card chrome: card header with step indicator,
// options as non-interactive preview chips, collapse-only footer.
function PreviewBox({ p }: { p: QuestionPreview }) {
  const [expanded, setExpanded] = useState(true);
  if (!expanded) {
    return (
      <Paper withBorder radius="xl" shadow="sm" p="xs" style={{ margin: 8 }} className="appr-card">
        <Button variant="subtle" size="compact-sm" onClick={() => setExpanded(true)}>
          Preview ▸
        </Button>
      </Paper>
    );
  }
  return (
    <Paper withBorder radius="xl" shadow="sm" p="sm" style={{ margin: 8 }} onClick={ensureNotiPerm} className="appr-card">
      <Group justify="space-between" mb={4} className="appr-head">
        <Group gap="xs">
          <Badge size="sm" variant="light" color="gray" className="appr-step">
            PREVIEW
          </Badge>
          <Text size="xs" c="dimmed" className="appr-title">
            {p.title ? p.title + " · " : ""}options still loading
          </Text>
        </Group>
        <Button
          variant="subtle"
          size="compact-xs"
          title="collapse"
          onClick={() => setExpanded(false)}
        >
          ▴
        </Button>
      </Group>
      <Text mb="xs"><MarkdownInline text={p.question} /></Text>
      <Stack gap={2} mb="xs">
        {p.options.map((o) => (
          <div key={o.index}>
            <Badge size="sm" variant="outline" color="gray">
              {o.index}. {o.label}
            </Badge>
            {o.description ? (
              <Text size="xs" c="dimmed">
                <MarkdownInline text={o.description} />
              </Text>
            ) : null}
          </div>
        ))}
      </Stack>
      <Text size="xs" c="dimmed" mt="xs">
        The worker just opened this picker — the answerable buttons land at
        the next screen sweep, within seconds. Nothing here can send an
        answer.
      </Text>
    </Paper>
  );
}

function QuestionBox({
  paneId,
  q,
  onToast,
}: {
  paneId: string;
  q: PickerQuestion;
  onToast: (msg: string, ok: boolean) => void;
}) {
  // Staging lives here (per-question mount) so the 2s table re-render never
  // loses staged picks and typing never fights the refresh — the input is
  // owned by this component, not rebuilt by the parent.
  // `nextQ`: a multi-question turn queues Q2 right behind Q1 — the server
  // returns it fresh with the send response, so the box advances immediately
  // instead of waiting up to 15s for the feed. Keyed use in the parent
  // remounts this component once the feed catches up.
  const [expanded, setExpanded] = useState(true);
  const [selected, setSelected] = useState<number[]>([]);
  const [text, setText] = useState("");
  const [sending, setSending] = useState(false);
  const [nextQ, setNextQ] = useState<PickerQuestion | null>(null);
  const [lastError, setLastError] = useState<string | null>(null);
  const shown = nextQ ?? q;

  if (!expanded) {
    return (
      <Paper withBorder radius="xl" shadow="sm" p="xs" style={{ margin: 8 }}>
        <Button variant="subtle" size="compact-sm" onClick={() => setExpanded(true)}>
          Answer here ▸
        </Button>
      </Paper>
    );
  }

  const toggle = (idx: number) => {
    if (shown.multi) {
      setSelected((s) =>
        s.includes(idx) ? s.filter((x) => x !== idx) : [...s, idx],
      );
    } else {
      setSelected([idx]);
    }
  };

  const canSend =
    (selected.length > 0 || text.trim().length > 0) && !sending;
  const sendOnEnter = (e: React.KeyboardEvent) => {
    // Enter sends exactly what Confirm & Send would — never anything the
    // button itself refuses (empty staging, mid-send).
    if (e.key === "Enter" && canSend) {
      e.preventDefault();
      void send();
    }
  };
  const send = async () => {
    // Free text replaces option picks — same precedence as the legacy page.
    const choice = text.trim()
      ? { type: "text" as const, value: text.trim() }
      : {
          type: "select" as const,
          indices: [...selected].sort((a, b) => a - b),
        };
    if (choice.type === "select" && choice.indices.length === 0) return;
    setSending(true);
    const res = await answerQuestion(paneId, choice, shown);
    setSending(false);
    if (res.ok) {
      setSelected([]);
      setText("");
      setNextQ(res.next ?? null);
      setLastError(null);
      if (!res.next) setExpanded(false);
    } else {
      // A toast alone is easy to miss on the phone (it auto-dismisses and
      // this card stays open expecting another try) — the real server
      // reason ("answer may not have landed — re-check the pane", "question
      // changed or gone", etc.) is kept here, next to Confirm & Send, same
      // as FormCard's persisted result line, instead of only flashing past.
      setLastError(res.error || "failed — no reason given");
    }
    onToast(
      res.ok
        ? res.next
          ? "answer sent — next question below"
          : "answer sent"
        : "answer refused: " + (res.error || "?"),
      !!res.ok,
    );
  };

  // A real answer form (BeautifulUI 04 Approval Card chrome): card header
  // with step indicator (pick one / pick any + option count), options as
  // selectable card-chips the PO stages, footer with Skip (collapse) +
  // Confirm & Send. Staging never sends — same semantics as before, only
  // the chrome changed. Staging lives here (per-question mount) so the 2s
  // table re-render never loses staged picks.
  // Screen parser calls it `desc`, the hook sidecar `description` — same text.
  const optDesc = (o: { desc?: string; description?: string }) =>
    o.desc || o.description || "";
  const optCount = shown.options.filter((o) => !o.other).length;
  return (
    <Paper withBorder radius="xl" shadow="sm" p="sm" style={{ margin: 8 }} onClick={ensureNotiPerm} className="appr-card">
      <Group justify="space-between" mb={4} className="appr-head">
        <Group gap="xs">
          <Badge
            size="sm"
            variant="light"
            color={shown.multi ? "violet" : "blue"}
            className="appr-step"
          >
            {shown.multi ? "PICK ANY" : "PICK ONE"} · {optCount}Q
          </Badge>
          <Text size="xs" c="dimmed" className="appr-title">
            {shown.title}
          </Text>
        </Group>
        <Button
          variant="subtle"
          size="compact-xs"
          title="collapse"
          onClick={() => setExpanded(false)}
        >
          ▴
        </Button>
      </Group>
      {shown.context ? (
        <Text size="xs" c="dimmed" fs="italic" mb="xs">
          “{shown.context}”
        </Text>
      ) : null}
      <Text mb="xs"><MarkdownInline text={shown.question} /></Text>
      <Stack gap="xs" mb="sm" align="stretch" className="appr-opts">
        {shown.options
          .filter((o) => !o.other)
          .map((o) => (
            <Stack key={o.index} gap={2} className={"appr-opt" + (selected.includes(o.index) ? " appr-opt-sel" : "")}>
              <Chip
                checked={selected.includes(o.index)}
                onChange={() => toggle(o.index)}
                color="green"
                variant={selected.includes(o.index) ? "filled" : "outline"}
              >
                {o.index}. {o.label}
                {o.checked ? " ✓" : ""}
              </Chip>
              {optDesc(o) ? (
                <Text size="xs" c="dimmed">
                  <MarkdownInline text={optDesc(o)} />
                </Text>
              ) : null}
            </Stack>
          ))}
      </Stack>
      <Group gap="sm" align="flex-end" className="appr-foot">
        <TextInput
          label="Other"
          placeholder="type free text instead — replaces option picks"
          value={text}
          onChange={(e) => setText(e.currentTarget.value)}
          onKeyDown={sendOnEnter}
          style={{ flex: 1, minWidth: 0 }}
        />
        <Button variant="subtle" onClick={() => setExpanded(false)}>
          Skip
        </Button>
        <Button
          color="green"
          disabled={!canSend}
          loading={sending}
          onClick={send}
        >
          Confirm &amp; Send
        </Button>
      </Group>
      {lastError ? (
        <Text size="xs" c="red" mt="xs">
          Not sent: {lastError}
        </Text>
      ) : (
        <Text size="xs" c="dimmed" mt="xs">
          Clicking stages only — nothing is sent until Confirm (or Enter in
          the text field). Free text replaces option picks. The server
          re-reads the pane fresh and refuses if the question moved on.
        </Text>
      )}
    </Paper>
  );
}

export function NeedsYou({
  rows,
  onFocus,
  onToast,
}: {
  rows: NeedsYouRow[];
  onFocus: (paneId: string, label: string) => void;
  onToast: (msg: string, ok: boolean) => void;
}) {
  return (
    <>
      <div
        className="small"
        style={{ padding: "6px 12px", color: "var(--ink-3)" }}
      >
        Only panes STOPPED, waiting for you to type.{" "}
        <span className="kind-question">QUESTION</span> a picker you can answer
        right here (expand, stage, Confirm) — a just-opened one first shows as
        a preview with no buttons until the sweep parses it ·{" "}
        <span className="kind-blocked">BLOCKED</span> a permission request; go
        to the pane and press ·{" "}
        <span className="kind-feed-broken">FEED BROKEN</span> this list cannot
        see, so an empty page below it proves nothing. Finished, quiet,
        crashed and vanished workers are NOT here — nothing is stopped waiting
        for a keystroke, so they live in BOARD with their last line. Click a
        row to focus its pane in herdr.
      </div>
      <div id="needsyou-body" style={{ overflowX: "auto" }}>
        {rows.length === 0 ? (
          <div className="empty">nothing needs you right now</div>
        ) : (
          // Fixed layout: the global nowrap table style used to size this
          // table to its widest cell, overflowing the viewport and stretching
          // the question panel with it. Columns get explicit shares and every
          // cell wraps instead.
          <table className="ny-table">
            <colgroup>
              <col style={{ width: "11%" }} />
              <col style={{ width: "9%" }} />
              <col style={{ width: "22%" }} />
              <col style={{ width: "10%" }} />
              <col style={{ width: "48%" }} />
            </colgroup>
            <tbody>
              {rows.flatMap((i) => {
                const key = (i.paneId ?? i.label) + "::" + i.kind;
                const main = (
                  <tr
                    key={key}
                    className={"needsyou-row rowkind-" + i.kind}
                    data-pane={i.paneId ?? undefined}
                    onClick={() =>
                      i.paneId && onFocus(i.paneId, i.label)
                    }
                  >
                    <td>
                      <KindBadge kind={i.kind}>{i.kind.toUpperCase()}</KindBadge>
                    </td>
                    <td className="small">{fmtAge(i.sinceSec)}</td>
                    <td>{i.label}</td>
                    <td className="small">{i.paneId ?? ""}</td>
                    <td className="wrap"><MarkdownInline text={i.detail} /></td>
                  </tr>
                );
                // Preview row (hook copy, not yet screen-parsed): display-only,
                // clicks never focus the pane — stop propagation like below.
                if (
                  i.kind === "question" &&
                  i.paneId &&
                  !i.question &&
                  i.questionPreview
                ) {
                  return [
                    main,
                    <tr
                      key={key + "::preview"}
                      className="needsyou-row"
                      onClick={(e) => e.stopPropagation()}
                    >
                      <td></td>
                      <td colSpan={4} style={{ padding: 0 }}>
                        <PreviewBox p={i.questionPreview} />
                      </td>
                    </tr>,
                  ];
                }
                // Question box row: clicks stage/confirm, NEVER focus the
                // pane — stop propagation like the legacy .qbox handler.
                if (i.kind === "question" && i.question && i.paneId) {
                  const q = i.question;
                  return [
                    main,
                    <tr
                      key={key + "::qbox"}
                      className="needsyou-row"
                      onClick={(e) => e.stopPropagation()}
                    >
                      <td></td>
                      <td colSpan={4} style={{ padding: 0 }}>
                        <QuestionBox
                          key={
                            i.paneId +
                            " :: " +
                            q.title +
                            " :: " +
                            q.question
                          }
                          paneId={i.paneId}
                          q={q}
                          onToast={onToast}
                        />
                      </td>
                    </tr>,
                  ];
                }
                // Pane-less (Desktop / CLI) row: the hook-held prompt to
                // answer, or the transcript's question to read.
                if ((!i.paneId || i.hookRequest?.tool) && (i.hookRequest || i.transcriptQuestion)) {
                  return [
                    main,
                    <tr
                      key={key + "::hook"}
                      className="needsyou-row"
                      onClick={(e) => e.stopPropagation()}
                    >
                      <td></td>
                      <td colSpan={4} style={{ padding: 0 }}>
                        <PanelessPrompt row={i} onToast={onToast} />
                      </td>
                    </tr>,
                  ];
                }
                return [main];
              })}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
