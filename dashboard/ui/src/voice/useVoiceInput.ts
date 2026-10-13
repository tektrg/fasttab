import { useCallback } from "react";
import { useTranscription } from "./useTranscription";
import { useVoiceRecorder } from "./useVoiceRecorder";

/** Record -> upload -> transcribe, as the one thing a message box needs.
 *  `onText` receives the transcript; the caller decides how it joins the draft. */
export function useVoiceInput({
  onText,
  now,
  pollIntervalMs,
  giveUpAfterMs,
}: {
  onText: (text: string) => void;
  /** Test seams: clock, poll cadence, give-up window. */
  now?: () => number;
  pollIntervalMs?: number;
  giveUpAfterMs?: number;
}) {
  const transcription = useTranscription({ onText, pollIntervalMs, giveUpAfterMs });
  const { submit, reset } = transcription;
  const recorder = useVoiceRecorder({ onRecorded: (blob) => void submit(blob), now });
  const { start } = recorder;

  const phase = recorder.phase === "idle" ? transcription.status : "recording";
  /** "Record again" and the first tap both start clean. */
  const startFresh = useCallback(() => {
    reset();
    void start();
  }, [reset, start]);
  const cancelAll = useCallback(() => {
    recorder.cancel();
    reset();
  }, [recorder, reset]);

  return {
    phase: recorder.phase === "starting" ? ("starting" as const) : phase,
    elapsedMs: recorder.elapsedMs,
    error: transcription.error ?? recorder.notice,
    canRetry: transcription.status === "failed",
    start: startFresh,
    stop: recorder.stop,
    cancel: cancelAll,
    retry: transcription.retry,
  };
}

export type VoiceInput = ReturnType<typeof useVoiceInput>;
