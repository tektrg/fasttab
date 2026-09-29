import { useEffect, useRef, useState } from "react";
import { Button, Radio, Switch, TextInput } from "@mantine/core";
import type { BoardRow } from "../../types";
import { Sheet } from "../../ui/Sheet";
import { listPersonas, routeWithJev, startPersona, type PersonaSummary } from "../../api";
import { isQueued, sendMessage } from "../../sessionActions";
import { imagesFromClipboard, uploadImages, useImageAttachments } from "../../imageAttachments";
import { ImageAttachBar } from "../ImageAttachBar";
import {
  EFFECT_TEXT,
  deriveEffect,
  isStartEffect,
  mainSession,
  startRefusal,
  type PersonaEffect,
} from "../../personaDelivery";

/** "Message a persona" — the phone's copy of AgentBar's persona routing.
 *  Pick a persona (or "Ask Jev": the server picks, the key never reaches
 *  the phone), see what sending would do, confirm. Nothing is ever sent
 *  or started on the pick alone, same as AgentBar's confirm row:
 *  - running main session -> the normal Send message path (a busy session
 *    asks to confirm the queue);
 *  - nothing running -> Start/Resume, which needs a second press (any
 *    registered persona; the server checks the name again). */
/** "<description> · → <effect>", or why that effect can't happen here. */
function personaCaption(p: PersonaSummary, effect: PersonaEffect): string {
  const blocked = isStartEffect(effect) ? startRefusal(p) : null;
  return `${p.description} · → ${blocked ? `not running — ${blocked}` : EFFECT_TEXT[effect]}`;
}

export function PersonaMessageSheet({
  opened,
  rows,
  onClose,
  onToast,
}: {
  opened: boolean;
  rows: BoardRow[];
  onClose: () => void;
  onToast: (msg: string, ok: boolean) => void;
}) {
  const [personas, setPersonas] = useState<PersonaSummary[] | null>(null);
  const [loadFailed, setLoadFailed] = useState(false);
  const [persona, setPersona] = useState<string>("");
  const [text, setText] = useState("");
  const attach = useImageAttachments();
  const [forceNew, setForceNew] = useState(false);
  const [busy, setBusy] = useState<"send" | "jev" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [jevPick, setJevPick] = useState<{ persona: string; confidence: number } | null>(null);
  // Second-press states: a start, or queueing into a busy main session.
  const [armedStart, setArmedStart] = useState(false);
  const [queueReason, setQueueReason] = useState<string | null>(null);
  // Read by the async Jev reply: drop it if the text changed or the sheet closed.
  const askedTextRef = useRef(text);
  askedTextRef.current = text;
  const openedRef = useRef(opened);
  openedRef.current = opened;
  const choiceRef = useRef({ persona, forceNew });
  choiceRef.current = { persona, forceNew };
  // Same-tick double tap / Enter + tap: `busy` only disables the buttons on
  // the next render, so both presses would pass (ReviewCard's guard).
  const inFlight = useRef(false);

  useEffect(() => {
    if (!opened) return;
    let dead = false;
    // A reopened sheet never inherits a pending confirm or an old Jev pick.
    setError(null);
    setLoadFailed(false);
    setArmedStart(false);
    setQueueReason(null);
    setJevPick(null);
    listPersonas().then((list) => {
      if (dead) return;
      const offered = (list ?? []).filter((p) => !p.offline);
      setPersonas(offered);
      setLoadFailed(list === null);
      if (!offered.some((p) => p.name === persona)) setPersona(offered[0]?.name ?? "");
    });
    return () => {
      dead = true;
    };
    // `persona` only keeps a still-listed choice; re-list on open only.
  }, [opened]);

  const chosen = personas?.find((p) => p.name === persona);
  const effectOf = (p: PersonaSummary, forced: boolean): PersonaEffect =>
    deriveEffect(mainSession(p, rows), p.idleStart, forced);
  const effect = chosen ? effectOf(chosen, forceNew) : null;

  // Any change to what would happen (incl. the board: the main session
  // ended or got busy) disarms a pending confirm.
  useEffect(() => {
    setArmedStart(false);
    setQueueReason(null);
  }, [persona, text, forceNew, effect]);
  const refusal = !chosen || !effect
    ? null
    : effect === "mainWaitingOnYou"
      ? "Its main session is waiting on you — answer it first, or start a new session."
      : effect === "mainUnreachable"
        ? "Its main session can't take messages here — start a new session instead."
        : isStartEffect(effect)
          ? startRefusal(chosen)
          : null;
  const hasText = text.trim() !== "";
  const hasImages = attach.images.length > 0;
  // Images go only to a running session (persona start takes text only).
  const imageRefusal = hasImages && effect && isStartEffect(effect)
    ? "Images can only go to a running session — remove them to start one."
    : null;
  const canSubmit = !!chosen && !!effect && (hasText || (hasImages && effect === "sendToMain"))
    && !refusal && !imageRefusal && busy === null;

  const askJev = async () => {
    if (!hasText || busy || inFlight.current) return;
    inFlight.current = true;
    setBusy("jev");
    setError(null);
    setJevPick(null);
    const askedText = text;
    const askedChoice = choiceRef.current;
    const res = await routeWithJev(askedText.trim());
    inFlight.current = false;
    setBusy(null);
    // Stale: the text changed, the sheet closed, or the user picked by hand meanwhile.
    const now = choiceRef.current;
    if (askedTextRef.current !== askedText || !openedRef.current) return;
    if (now.persona !== askedChoice.persona || now.forceNew !== askedChoice.forceNew) return;
    if (res.ok && res.persona && personas?.some((p) => p.name === res.persona)) {
      setPersona(res.persona);
      setForceNew(false);
      setJevPick({ persona: res.persona, confidence: res.confidence ?? 0 });
    } else {
      setError(res.ok ? `Jev picked ${res.persona}, which isn't listed here` : res.error || "Jev routing failed");
    }
  };

  const finish = (message: string) => {
    onToast(message, true);
    setText("");
    setForceNew(false);
    setJevPick(null);
    attach.clear();
    onClose();
  };

  const send = async (main: BoardRow, confirm: boolean) => {
    let attachments: string[] = [];
    if (attach.images.length > 0) {
      const up = await uploadImages(attach.images.map((i) => i.blob));
      if (!up.ok) {
        setError(`Image not uploaded — nothing was sent: ${up.error}`);
        return;
      }
      attachments = up.ids;
    }
    const res = await sendMessage(main.rowId, text.trim(), { confirm, attachments });
    if (res.ok) {
      finish(isQueued(res) ? `queued to ${persona} — lands when the turn ends` : `sent to ${persona}`);
    } else if (res.needsConfirm) {
      setQueueReason(res.reason || "the session is busy — confirm to queue");
    } else {
      setError(res.error || res.reason || "send failed");
    }
  };

  const start = async () => {
    const res = await startPersona({ persona, text: text.trim(), fresh: effect === "startNew" });
    if (res.ok) finish(`${res.mode === "resumed" ? "resumed" : "started"}: ${persona}`);
    else setError(res.error || "start failed");
  };

  const submit = async () => {
    if (!canSubmit || !chosen || !effect || inFlight.current) return;
    const main = mainSession(chosen, rows);
    if (isStartEffect(effect) && !armedStart) {
      setArmedStart(true);
      return;
    }
    inFlight.current = true;
    setBusy("send");
    setError(null);
    if (effect === "sendToMain" && main.kind === "ready") await send(main.row, queueReason !== null);
    else if (isStartEffect(effect)) await start();
    inFlight.current = false;
    setBusy(null);
  };

  const submitLabel = !effect
    ? "Send"
    : queueReason !== null
      ? "Confirm queue"
      : isStartEffect(effect)
        ? armedStart
          ? `Confirm ${effect === "resumeLast" ? "resume" : "start"}`
          : effect === "resumeLast"
            ? "Resume"
            : "Start"
        : "Send";

  const footer = (
      <div className="phone-sheet-footer">
        <TextInput
          value={text}
          onChange={(e) => setText(e.currentTarget.value)}
          placeholder="Message…"
          aria-label="message"
          enterKeyHint="send"
          disabled={busy === "jev"}
          onPaste={(e) => {
            const files = imagesFromClipboard(e.clipboardData);
            if (files.length) {
              e.preventDefault();
              void attach.add(files);
            }
          }}
          onKeyDown={(e) => {
            // A held Enter auto-repeats: never let it press "confirm" too.
            if (e.key === "Enter" && !e.repeat) void submit();
          }}
        />
        <ImageAttachBar
          images={attach.images}
          error={attach.error}
          disabled={busy !== null}
          onAdd={(files) => void attach.add(files)}
          onRemove={attach.remove}
        />
        <div className="phone-sheet-actions persona-sheet-actions">
          <Switch
            checked={forceNew}
            onChange={(e) => setForceNew(e.currentTarget.checked)}
            label="Start a new session instead"
            className="persona-sheet-fresh"
          />
          <Button
            size="sm"
            variant="light"
            disabled={!hasText || busy !== null || !personas?.length}
            loading={busy === "jev"}
            onClick={() => void askJev()}
          >
            Ask Jev
          </Button>
          <Button
            size="sm"
            color={armedStart || queueReason !== null ? "orange" : undefined}
            disabled={!canSubmit}
            loading={busy === "send"}
            onClick={() => void submit()}
          >
            {submitLabel}
          </Button>
        </div>
      </div>
  );

  return (
    <Sheet
      open={opened}
      onOpenChange={(o) => !o && onClose()}
      title="Message a persona"
      footer={footer}
    >
        {personas === null ? (
          <div className="empty">loading…</div>
        ) : personas.length === 0 ? (
          <div className="empty persona-sheet-empty">
            {loadFailed ? "Couldn't load personas." : "No persona yet — add one in AgentBar Settings > Personas."}
          </div>
        ) : (
          <Radio.Group
            value={persona}
            onChange={(v) => {
              setPersona(v);
              setJevPick(null);
            }}
            name="persona"
          >
            <div className="persona-sheet-list">
              {personas.map((p) => (
                <Radio
                  key={p.name}
                  value={p.name}
                  label={p.name}
                  description={personaCaption(p, effectOf(p, false))}
                  className="persona-sheet-item"
                />
              ))}
            </div>
          </Radio.Group>
        )}
        {jevPick && (
          <div className="persona-sheet-jev">
            Jev picked <strong>{jevPick.persona}</strong> ({Math.round(jevPick.confidence * 100)}%) —
            check it, then confirm below.
          </div>
        )}
        {queueReason && <div className="persona-sheet-note">{queueReason}</div>}
        {armedStart && chosen && effect && (
          <div className="persona-sheet-note">
            {effect === "resumeLast"
              ? `Reopens ${chosen.name}'s last conversation on the Mac and sends it your message.`
              : `Starts ${chosen.name} on the Mac in a new conversation and sends it your message.`}{" "}
            Press again to confirm.
          </div>
        )}
        {refusal && <div className="persona-sheet-note">{refusal}</div>}
        {imageRefusal && <div className="persona-sheet-note">{imageRefusal}</div>}
        {error && <div className="persona-sheet-error">{error}</div>}
    </Sheet>
  );
}
