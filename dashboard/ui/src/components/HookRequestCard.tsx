import { useState } from "react";
import { Badge, Button, Chip, Group, Paper, Stack, Text, TextInput } from "@mantine/core";
import type { HookAnswer, HookQuestion, HookRequest, NeedsYouRow, TranscriptQuestion } from "../types";
import { answerHookRequest } from "../api";
import { MarkdownInline } from "./Markdown";
import { ActionButton } from "../ui/ActionButton";

/** A pane-less (Claude Desktop / CLI outside herdr) Needs You row's prompt:
 *  - `hookRequest` — the PermissionRequest hook holds it: answerable here,
 *    one POST /api/hook/permission/<id>/answer (same contract AgentBar uses,
 *    Sources/AgentBar/AGENTS.md "Hook answer bridge");
 *  - else `transcriptQuestion` — read from the transcript: display only.
 *  Used by the desktop NeedsYou table and the phone inbox alike. */
export function PanelessPrompt({
  row,
  onToast,
  phone,
}: {
  row: NeedsYouRow;
  onToast: (msg: string, ok: boolean) => void;
  /** Phone sheet: numbered 48pt option rows and one full-width Send. */
  phone?: boolean;
}) {
  // A pane row is answered by its pane path — except an OpenCode / Codex
  // prompt, which has no pane path and comes with its own request (`tool`).
  if (row.paneId && !row.hookRequest?.tool) return null;
  if (row.hookRequest) {
    // Keyed by request id: a new prompt (or a re-sent one with a new id)
    // starts from a clean card, never with the old one's picks.
    return <HookRequestCard key={row.hookRequest.requestId} request={row.hookRequest} onToast={onToast} phone={phone} />;
  }
  if (row.transcriptQuestion) return <TranscriptQuestionNote q={row.transcriptQuestion} />;
  return null;
}

/** Said to Claude with a denial (the server default names AgentBar). */
const WEB_DENY: HookAnswer = { behavior: "deny", message: "The user denied this from the dashboard web UI." };

type SendState = { status: "idle" | "sending" | "sent" } | { status: "error"; error: string };

const PRODUCT_NAME = { opencode: "OpenCode", codex: "Codex" } as const;

/** "Claude" unless the request came from OpenCode / Codex. */
export function productName(request: HookRequest): string {
  return request.tool ? PRODUCT_NAME[request.tool] : "Claude";
}

function useHookSend(request: HookRequest, onToast: (msg: string, ok: boolean) => void) {
  const requestId = request.requestId;
  const [state, setState] = useState<SendState>({ status: "idle" });
  const send = async (answer: HookAnswer) => {
    setState({ status: "sending" });
    const res = await answerHookRequest(requestId, answer);
    // Never retried: a refusal (409 answered in Claude / Claude stopped
    // waiting) is final and shown verbatim.
    setState(res.ok ? { status: "sent" } : { status: "error", error: res.error || "no reason given" });
    onToast(res.ok ? `answer sent to ${productName(request)}` : "answer not sent: " + (res.error || "?"), res.ok);
  };
  return { state, send, busy: state.status === "sending" || state.status === "sent" };
}

function SendFooter({ state, request }: { state: SendState; request: HookRequest }) {
  const product = productName(request);
  if (state.status === "sent") {
    return <Text size="xs" c="green" mt="xs">Sent — {product} continues.</Text>;
  }
  if (state.status === "error") {
    return <Text size="xs" c="red" mt="xs">Not sent: {state.error}</Text>;
  }
  return (
    <Text size="xs" c="dimmed" mt="xs">
      {request.tool === "codex"
        ? "Codex waits for this answer — it draws its own prompt only if nobody answers here in time."
        : `${product} shows this prompt on the Mac too — whichever is answered first wins.`}
    </Text>
  );
}

/** One question's draft: picked option labels, or free text (which replaces them). */
interface Draft {
  picked: string[];
  text: string;
}

export function hookAnswerText(q: HookQuestion, draft: Draft): string | null {
  const text = draft.text.trim();
  if (text) return text;
  // Option order, never tap order — same as AgentBar's "a, b".
  const labels = q.options.map((o) => o.label).filter((l) => draft.picked.includes(l));
  return labels.length ? labels.join(", ") : null;
}

function QuestionFields({
  q,
  draft,
  disabled,
  onChange,
  phone,
}: {
  q: HookQuestion;
  draft: Draft;
  disabled: boolean;
  onChange: (next: Draft) => void;
  phone?: boolean;
}) {
  const toggle = (label: string) => {
    const on = draft.picked.includes(label);
    const picked = q.multiSelect
      ? on ? draft.picked.filter((l) => l !== label) : [...draft.picked, label]
      : on ? [] : [label];
    onChange({ ...draft, picked });
  };
  return (
    <div className="hook-question">
      <Group gap="xs" mb={4}>
        <Badge size="sm" variant="light" color={q.multiSelect ? "violet" : "blue"}>
          {q.multiSelect ? "PICK ANY" : "PICK ONE"}
        </Badge>
        {q.header ? <Text size="xs" c="dimmed">{q.header}</Text> : null}
      </Group>
      <Text mb="xs"><MarkdownInline text={q.question} /></Text>
      {phone ? (
        <div className="ui-options" role="group" aria-label={q.question}>
          {q.options.map((o, i) => {
            const on = draft.picked.includes(o.label);
            return (
              <button
                key={i}
                type="button"
                className="ui-option"
                aria-pressed={on}
                disabled={disabled}
                onClick={() => toggle(o.label)}
              >
                <span className="ui-option__n" aria-hidden="true">{i + 1}</span>
                <span className="ui-option__body">
                  <span className="ui-option__label"><MarkdownInline text={o.label} /></span>
                  {o.description ? <span className="ui-option__desc"><MarkdownInline text={o.description} /></span> : null}
                </span>
              </button>
            );
          })}
        </div>
      ) : (
<Stack gap="xs" mb="xs" align="stretch">
          {q.options.map((o, i) => (
            <Stack key={i} gap={2}>
              <Chip
                checked={draft.picked.includes(o.label)}
                onChange={() => toggle(o.label)}
                disabled={disabled}
                color="green"
              >
                {i + 1}. {o.label}
              </Chip>
              {o.description ? (
                <Text size="xs" c="dimmed"><MarkdownInline text={o.description} /></Text>
              ) : null}
            </Stack>
          ))}
        </Stack>
        )}
      <TextInput
        label="Other"
        placeholder="type an answer instead — replaces option picks"
        value={draft.text}
        disabled={disabled}
        onChange={(e) => onChange({ ...draft, text: e.currentTarget.value })}
      />
    </div>
  );
}

function HookQuestionCard({ request, onToast, phone }: { request: HookRequest; onToast: (msg: string, ok: boolean) => void; phone?: boolean }) {
  const questions = request.questions ?? [];
  const [drafts, setDrafts] = useState<Draft[]>(() => questions.map(() => ({ picked: [], text: "" })));
  const { state, send, busy } = useHookSend(request, onToast);
  const texts = questions.map((q, i) => hookAnswerText(q, drafts[i]));
  const complete = questions.length > 0 && texts.every((t) => t !== null);
  const submit = () => {
    if (!complete || busy) return;
    const answers: Record<string, string> = {};
    questions.forEach((q, i) => (answers[q.question] = texts[i] as string));
    void send({ behavior: "allow", answers });
  };
  return (
    <Paper withBorder radius="xl" shadow="sm" p="sm" style={{ margin: 8 }} className="appr-card hook-card">
      <Stack gap="md">
        {questions.map((q, i) => (
          <QuestionFields
            key={q.question}
            q={q}
            draft={drafts[i]}
            disabled={busy}
            phone={phone}
            onChange={(next) => setDrafts((d) => d.map((old, j) => (j === i ? next : old)))}
          />
        ))}
      </Stack>
      {phone ? (
        <ActionButton variant="primary" className="ui-btn--block" disabled={!complete || busy} onClick={submit}>
          {state.status === "sending" ? "Sending…" : questions.length > 1 ? `Send ${questions.length} answers` : "Send answer"}
        </ActionButton>
      ) : (
        <Group justify="flex-end" mt="sm">
          <Button color="green" disabled={!complete || busy} loading={state.status === "sending"} onClick={submit}>
            {questions.length > 1 ? `Send ${questions.length} answers` : "Send answer"}
          </Button>
        </Group>
      )}
      <SendFooter state={state} request={request} />
    </Paper>
  );
}

function HookPermissionCard({ request, onToast, phone }: { request: HookRequest; onToast: (msg: string, ok: boolean) => void; phone?: boolean }) {
  const permission = request.permission;
  const { state, send, busy } = useHookSend(request, onToast);
  // A suggestion saves a permission rule: it takes a second tap, like
  // AgentBar's "Confirm permission change".
  const [armedSuggestion, setArmedSuggestion] = useState<number | null>(null);
  if (!permission) return null;
  const pressSuggestion = (index: number) => {
    if (armedSuggestion !== index) {
      setArmedSuggestion(index);
      return;
    }
    void send({ behavior: "allow", suggestionIndex: index });
  };
  return (
    <Paper withBorder radius="xl" shadow="sm" p="sm" style={{ margin: 8 }} className="appr-card hook-card">
      <Group gap="xs" mb={4}>
        <Badge size="sm" variant="light" color="orange">PERMISSION</Badge>
        <Text size="sm" fw={600}>{permission.title}</Text>
      </Group>
      <pre className="hook-permission-detail">{permission.detail}</pre>
      <Stack gap="xs" mt="xs">
        <Button color="green" disabled={busy} onClick={() => void send({ behavior: "allow" })} h={phone ? 48 : undefined}>
          Allow once
        </Button>
        {permission.suggestions.map((s) => (
          <Button
            key={s.index}
            variant={armedSuggestion === s.index ? "filled" : "light"}
            color="green"
            disabled={busy}
            onClick={() => pressSuggestion(s.index)}
            styles={{ label: { whiteSpace: "normal" } }}
            h="auto"
            mih={phone ? 48 : undefined}
            py={6}
          >
            {armedSuggestion === s.index ? "Tap again to save: " : ""}
            <MarkdownInline text={s.label} />
          </Button>
        ))}
        {permission.suggestions.length ? (
          <Text size="xs" c="dimmed">
            A rule button allows this now AND saves the rule, so {productName(request)} stops asking — it takes a second tap.
          </Text>
        ) : null}
        <Button color="red" variant="light" disabled={busy} onClick={() => void send(WEB_DENY)} h={phone ? 48 : undefined}>
          Deny
        </Button>
      </Stack>
      <SendFooter state={state} request={request} />
    </Paper>
  );
}

function HookRequestCard({ request, onToast, phone }: { request: HookRequest; onToast: (msg: string, ok: boolean) => void; phone?: boolean }) {
  return request.kind === "question"
    ? <HookQuestionCard request={request} onToast={onToast} phone={phone} />
    : <HookPermissionCard request={request} onToast={onToast} phone={phone} />;
}

function TranscriptQuestionNote({ q }: { q: TranscriptQuestion }) {
  const more = q.questionCount > 1 ? ` (+${q.questionCount - 1} more)` : "";
  return (
    <Paper withBorder radius="xl" p="sm" style={{ margin: 8 }} className="appr-card hook-card">
      <Group gap="xs" mb={4}>
        <Badge size="sm" variant="light" color="gray">ASKED</Badge>
        {q.header ? <Text size="xs" c="dimmed">{q.header}{more}</Text> : null}
      </Group>
      <Text mb="xs"><MarkdownInline text={q.question} /></Text>
      <Text size="xs" c="dimmed">
        Display only — answer it in Claude on the Mac. An answer form shows up
        here if Claude's hook sends the prompt again.
      </Text>
    </Paper>
  );
}
