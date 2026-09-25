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

export function useQuestionAlerts(needsYou: NeedsYouRow[] | undefined) {
  const seen = useRef<Record<string, string>>({});
  useEffect(() => {
    ensureNotiPerm();
  }, []);
  useEffect(() => {
    if (!needsYou) return;
    for (const i of needsYou) {
      if (i.kind !== "question" || !i.question || !i.paneId) continue;
      const key =
        i.paneId + " :: " + i.question.title + " :: " + i.question.question;
      if (seen.current[i.paneId] === key) continue;
      seen.current[i.paneId] = key;
      playAlert();
      try {
        if (window.Notification && Notification.permission === "granted") {
          new Notification("QUESTION needs you: " + i.label, {
            body:
              i.question.question +
              " (" +
              i.question.options.filter((o) => !o.other).length +
              " options)",
            tag: i.paneId,
          });
        }
      } catch {
        /* notification failed */
      }
    }
  }, [needsYou]);
}
