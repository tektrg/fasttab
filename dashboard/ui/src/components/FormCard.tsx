import { useRef, useState } from "react";
import { Button, Checkbox, Group, Radio, Stack, Text, TextInput } from "@mantine/core";
import type { PendingQuestionForm } from "../types";
import { answerQuestion } from "../api";
import { Block } from "./Block";
import { MarkdownInline } from "./Markdown";

interface Draft {
  selected: string[];
  other: string;
}

/** The multi-question AskUserQuestion form card (`GET
 *  /api/session/latest`'s `pendingQuestion`). The dashboard's `/api/answer`
 *  only ever answers the ONE question currently on screen (server
 *  contract), so this sends one `/api/answer` per question, in order, same
 *  as AptusFit's `FormBatchDriver` — a simplified, non-retrying version: no
 *  pane-side verification is attempted from the web client, so a question
 *  the terminal has already moved past is not detected here (deferred, see
 *  the phase report). Stops and reports at the first refusal. */
export function FormCard({
  paneId,
  form,
  onToast,
  phone,
}: {
  paneId: string;
  form: PendingQuestionForm;
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
    inFlight.current = true;
    setSending(true);
    let allOk = true;
    let lastError = "";
    for (let i = 0; i < form.questions.length; i++) {
      const q = form.questions[i];
      const d = drafts[i];
      const choice = d.other.trim()
        ? { type: "text" as const, value: d.other.trim() }
        : {
            type: "select" as const,
            indices: d.selected
              .map((label) => q.options.findIndex((o) => o.label === label) + 1)
              .filter((n) => n > 0),
          };
      const res = await answerQuestion(paneId, choice, {
        title: q.header || q.question,
        question: q.question,
        multi: q.isMultiSelect,
        options: [],
        cursorIndex: null,
        otherIndex: null,
        hasSubmit: true,
      });
      if (!res.ok) {
        allOk = false;
        lastError = res.error || "?";
        break;
      }
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
