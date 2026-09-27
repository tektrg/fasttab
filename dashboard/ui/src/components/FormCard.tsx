import { useRef, useState } from "react";
import { Button, Checkbox, Group, Radio, Stack, Text, TextInput } from "@mantine/core";
import type { PendingQuestionForm, PickerQuestion } from "../types";
import { answerQuestion } from "../api";
import { Block } from "./Block";
import { MarkdownInline } from "./Markdown";

interface Draft {
  selected: string[];
  other: string;
}

/** The multi-question AskUserQuestion form card (`GET
 *  /api/session/latest`'s `pendingQuestion` supplies the labels/options to
 *  RENDER; `screenQuestion` — the sweep's screen-parsed picker, same object
 *  NeedsYou's QuestionBox sends — supplies the title/question actually POSTED).
 *
 *  Bug fixed here (2026-09-27, "question changed or gone" on a still-visible
 *  question): this card used to build the posted `question` from the
 *  transcript's raw `header`/`question` strings. `/api/answer` re-reads the
 *  pane fresh and refuses unless the posted title/question match
 *  `classify_pane.parse_question_block`'s SCREEN-rendered text letter for
 *  letter (chief-dashboard-server.py's `answer_pane_question`) — and the
 *  transcript copy is a different representation of the same question
 *  (verbatim tool-input text, markdown and all) from the terminal's cleaned,
 *  box-unwrapped rendering, so the two are essentially never byte-identical.
 *  `read_hook_question`'s docstring already says this copy "can never
 *  satisfy answer_pane_question()'s exact-match refusal gate" — NeedsYou's
 *  PreviewBox treats the same kind of copy as display-only for exactly that
 *  reason; this card was the one place still sending it.
 *
 *  Fix: submit the SCREEN-parsed `screenQuestion` for the tab currently open
 *  (matches what the server's fresh re-read will see), then advance to each
 *  next tab using the `next` question the server itself returns after a
 *  landed answer — the same closed-loop progression NeedsYou's QuestionBox
 *  already relies on. No `screenQuestion` yet (the sweep hasn't caught up to
 *  a just-opened picker) means nothing safe to post, so Submit refuses with
 *  a wait-and-retry reason instead of guessing.
 *
 *  The dashboard's `/api/answer` only ever answers the ONE question
 *  currently on screen (server contract), so this still sends one
 *  `/api/answer` per question, in order, same as AptusFit's
 *  `FormBatchDriver` — a simplified, non-retrying version. Stops and
 *  reports at the first refusal. */
export function FormCard({
  paneId,
  form,
  screenQuestion,
  onToast,
  phone,
}: {
  paneId: string;
  form: PendingQuestionForm;
  screenQuestion?: PickerQuestion | null;
  onToast: (msg: string, ok: boolean) => void;
  phone?: boolean;
}) {
  const [drafts, setDrafts] = useState<Draft[]>(
    form.questions.map(() => ({ selected: [], other: "" })),
  );
  const [sending, setSending] = useState(false);
  const [result, setResult] = useState<{ ok: boolean; msg: string } | null>(null);
  // React batches same-tick state updates, so `sending` alone cannot stop a
  // second click dispatched before the disabled-button re-render commits
  // (proven: two clicks in one event-loop turn otherwise fire two POSTs).
  // This ref is read-and-set synchronously, ahead of any state update.
  const inFlight = useRef(false);

  const setDraft = (i: number, next: Partial<Draft>) =>
    setDrafts((ds) => ds.map((d, idx) => (idx === i ? { ...d, ...next } : d)));

  const toggle = (qi: number, label: string, multi: boolean) => {
    setDrafts((ds) =>
      ds.map((d, idx) => {
        if (idx !== qi) return d;
        if (multi) {
          const has = d.selected.includes(label);
          return { ...d, selected: has ? d.selected.filter((l) => l !== label) : [...d.selected, label] };
        }
        return { ...d, selected: [label] };
      }),
    );
  };

  const answered = (d: Draft) => d.selected.length > 0 || d.other.trim().length > 0;
  const canSubmit = drafts.every(answered) && !sending;

  const submit = async () => {
    if (inFlight.current) return;
    if (!screenQuestion) {
      // No screen-parsed copy yet (the sweep hasn't caught up to a
      // just-opened picker) — nothing here would satisfy the server's
      // exact-match gate, so refuse instead of posting a guess.
      const msg = "the on-screen question hasn't loaded yet — wait a few seconds and try again";
      setResult({ ok: false, msg });
      onToast("answer refused: " + msg, false);
      return;
    }
    inFlight.current = true;
    setSending(true);
    let allOk = true;
    let lastError = "";
    let current: PickerQuestion | null = screenQuestion;
    for (let i = 0; i < form.questions.length; i++) {
      const q = form.questions[i];
      const d = drafts[i];
      if (!current) {
        allOk = false;
        lastError = "question changed or gone — re-check the pane";
        break;
      }
      const choice = d.other.trim()
        ? { type: "text" as const, value: d.other.trim() }
        : {
            type: "select" as const,
            indices: d.selected
              .map((label) => q.options.findIndex((o) => o.label === label) + 1)
              .filter((n) => n > 0),
          };
      const res = await answerQuestion(paneId, choice, current);
      if (!res.ok) {
        allOk = false;
        lastError = res.error || "?";
        break;
      }
      // The server hands back the NEXT tab's screen-parsed question fresh —
      // same progression NeedsYou's QuestionBox uses — so every question
      // after the first is still posted against a live, verified copy.
      current = res.next ?? null;
    }
    setSending(false);
    inFlight.current = false;
    setResult(allOk ? { ok: true, msg: "sent" } : { ok: false, msg: lastError });
    onToast(allOk ? "answers sent" : "not sent: " + lastError, allOk);
  };

  return (
    <Block phone={phone} className="form-card">
      <Stack gap="md">
        {form.questions.map((q, qi) => (
          <div key={qi}>
            {q.header && (
              <Text size="xs" c="dimmed">
                <MarkdownInline text={q.header} />
              </Text>
            )}
            <Text mb="xs">
              <MarkdownInline text={q.question} />
            </Text>
            <Stack gap={4}>
              {q.options.map((o) =>
                q.isMultiSelect ? (
                  <Checkbox
                    key={o.label}
                    label={o.label}
                    checked={drafts[qi].selected.includes(o.label)}
                    onChange={() => toggle(qi, o.label, true)}
                  />
                ) : (
                  <Radio
                    key={o.label}
                    label={o.label}
                    checked={drafts[qi].selected.includes(o.label)}
                    onChange={() => toggle(qi, o.label, false)}
                  />
                ),
              )}
            </Stack>
            <TextInput
              mt="xs"
              label="Other"
              placeholder="type free text instead — replaces option picks"
              value={drafts[qi].other}
              onChange={(e) => setDraft(qi, { other: e.currentTarget.value })}
            />
          </div>
        ))}
      </Stack>
      <Group mt="sm">
        <Button color="green" disabled={!canSubmit} loading={sending} onClick={() => void submit()}>
          Submit
        </Button>
      </Group>
      {result && (
        <Text size="xs" c={result.ok ? "dimmed" : "red"} mt="xs">
          {result.ok ? "Sent." : `Not sent: ${result.msg}`}
        </Text>
      )}
    </Block>
  );
}
