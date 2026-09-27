import { useEffect, useRef } from "react";
import type { NeedsYouRow } from "./types";

/** Desktop + sound alert for NEW questions only (keyed by pane+question, so
 *  the 2s re-render never re-fires). Ported from the legacy page. */
export function ensureNotiPerm() {
  try {
    if (window.Notification && Notification.permission === "default") {
      Notification.requestPermission().catch(() => {});
    }
  } catch {
    /* unsupported browser */
  }
}

function playAlert() {
  try {
    const AC =
      window.AudioContext ||
      (window as unknown as { webkitAudioContext?: typeof AudioContext })
        .webkitAudioContext;
    if (!AC) return;
    const ctx =
      (playAlert as { _ctx?: AudioContext })._ctx ??
      ((playAlert as { _ctx?: AudioContext })._ctx = new AC());
    if (ctx.state === "suspended") ctx.resume().catch(() => {});
    [660, 880].forEach((f, k) => {
      const o = ctx.createOscillator();
      const g = ctx.createGain();
      o.connect(g);
      g.connect(ctx.destination);
      o.frequency.value = f;
      const t = ctx.currentTime + k * 0.22;
      g.gain.setValueAtTime(0.0001, t);
      g.gain.exponentialRampToValueAtTime(0.3, t + 0.03);
      g.gain.exponentialRampToValueAtTime(0.0001, t + 0.2);
      o.start(t);
      o.stop(t + 0.22);
    });
  } catch {
    /* audio unavailable */
  }
}

/** What one Needs You row alerts with, or null (nothing to alert on).
 *  `slot` = the agent (pane, or session for a pane-less Desktop/CLI row);
 *  `key` = the prompt shown — a new key in the same slot re-alerts. For a
 *  pane-less row the key is the asked TEXT, not the hook request id, so a
 *  prompt re-sent after a dashboard restart (new id) or flipping between the
 *  transcript fallback and the hook request never alerts twice. */
export function alertFor(
  i: NeedsYouRow,
): { slot: string; key: string; title: string; body: string } | null {
  if (i.paneId) {
    if (i.kind !== "question" || !i.question) return null;
    return {
      slot: i.paneId,
      key: i.paneId + " :: " + i.question.title + " :: " + i.question.question,
      title: "QUESTION needs you: " + i.label,
      body:
        i.question.question +
        " (" + i.question.options.filter((o) => !o.other).length + " options)",
    };
  }
  const slot = i.agentSession;
  if (!slot) return null;
  const hook = i.hookRequest;
  const question = hook?.questions?.[0]?.question ?? i.transcriptQuestion?.question;
  if (question) {
    return { slot, key: slot + " :: q :: " + question, title: "QUESTION needs you: " + i.label, body: question };
  }
  if (hook?.permission) {
    const body = hook.permission.title + ": " + hook.permission.detail.slice(0, 200);
    return { slot, key: slot + " :: p :: " + hook.permission.title + " :: " + hook.permission.detail,
             title: "PERMISSION needs you: " + i.label, body };
  }
  return null;
}

export function useQuestionAlerts(needsYou: NeedsYouRow[] | undefined) {
  const seen = useRef<Record<string, string>>({});
  useEffect(() => {
    ensureNotiPerm();
  }, []);
  useEffect(() => {
    if (!needsYou) return;
    for (const i of needsYou) {
      const alert = alertFor(i);
      if (!alert || seen.current[alert.slot] === alert.key) continue;
      seen.current[alert.slot] = alert.key;
      playAlert();
      try {
        if (window.Notification && Notification.permission === "granted") {
          new Notification(alert.title, { body: alert.body, tag: alert.slot });
        }
      } catch {
        /* notification failed */
      }
    }
  }, [needsYou]);
}
