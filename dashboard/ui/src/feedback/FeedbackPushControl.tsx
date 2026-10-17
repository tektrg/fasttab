/** "Phone alerts" strip at the top of the Feedback tab: turn Web Push on/off for
 *  this device and send a test push (src/feedback/feedbackPush.ts). */
import { useEffect, useState } from "react";
import {
  PUSH_STATE_TEXT,
  basePushState,
  currentSubscription,
  disableFeedbackPush,
  enableFeedbackPush,
  readPushEnv,
  sendTestPush,
  type PushState,
} from "./feedbackPush";

type Notify = (message: string, ok: boolean) => void;

export function FeedbackPushControl({ onToast, initialState }: { onToast: Notify; initialState?: PushState }) {
  const [state, setState] = useState<PushState | null>(initialState ?? null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (initialState) return;
    let live = true;
    const base = basePushState(readPushEnv());
    if (base !== "off") return setState(base);
    currentSubscription()
      .then((subscription) => live && setState(subscription ? "on" : "off"))
      .catch(() => live && setState("off"));
    return () => {
      live = false;
    };
  }, [initialState]);

  if (!state) return null;

  const run = async (action: () => Promise<{ ok: boolean; error?: string; [key: string]: unknown }>, done: (reply: any) => string, next?: PushState) => {
    setBusy(true);
    try {
      const reply = await action();
      onToast(reply.ok ? done(reply) : "push: " + (reply.error || "failed"), reply.ok);
      if (reply.ok && next) setState(next);
    } catch (error) {
      onToast("push: " + String(error), false);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="feedback-push" data-state={state}>
      <span className="small">{PUSH_STATE_TEXT[state]}</span>
      {state === "off" && (
        <button type="button" disabled={busy} onClick={() => void run(enableFeedbackPush, () => "phone alerts on", "on")}>
          Turn on phone alerts
        </button>
      )}
      {state === "on" && (
        <>
          <button
            type="button"
            disabled={busy}
            onClick={() => void run(sendTestPush, (r) => (r.sent ? `test push sent to ${r.sent} device(s)` : "no device received it: turn alerts off and on again"))}
          >
            Send test push
          </button>
          <button type="button" disabled={busy} onClick={() => void run(disableFeedbackPush, () => "phone alerts off", "off")}>
            Turn off
          </button>
        </>
      )}
    </div>
  );
}
