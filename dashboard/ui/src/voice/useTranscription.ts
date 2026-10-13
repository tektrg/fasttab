import { useCallback, useEffect, useRef, useState } from "react";
import { getTranscribe, startTranscribe, uploadAudio } from "../api";

export const POLL_INTERVAL_MS = 1500;
export const GIVE_UP_AFTER_MS = 12 * 60 * 1000;
/** Consecutive network errors tolerated while polling before giving up. */
const MAX_POLL_ERRORS = 5;

export const TIMEOUT_MESSAGE = "Transcription is taking too long. Try again in a little while.";
export const NO_SPEECH_MESSAGE = "No speech was heard in that recording.";

export type TranscriptionStatus = "idle" | "uploading" | "transcribing" | "failed";

export interface TranscriptionOptions {
  /** The finished, already-normalised transcript. */
  onText: (text: string) => void;
  pollIntervalMs?: number;
  giveUpAfterMs?: number;
}

/** Upload one recording, start the job, poll until it is done or failed.
 *  Retry re-POSTs the same job id (or re-uploads when the upload itself failed). */
export function useTranscription({
  onText,
  pollIntervalMs = POLL_INTERVAL_MS,
  giveUpAfterMs = GIVE_UP_AFTER_MS,
}: TranscriptionOptions) {
  const [status, setStatus] = useState<TranscriptionStatus>("idle");
  const [error, setError] = useState<string | null>(null);
  const blobRef = useRef<Blob | null>(null);
  const idRef = useRef<string | null>(null);
  /** Bumped by reset/unmount/new run: a stale poll loop sees it and stops. */
  const runRef = useRef(0);
  const onTextRef = useRef(onText);
  onTextRef.current = onText;

  const fail = (message: string) => {
    setError(message);
    setStatus("failed");
  };

  const poll = useCallback(
    async (id: string, run: number) => {
      const deadline = Date.now() + giveUpAfterMs;
      let errors = 0;
      while (runRef.current === run) {
        await new Promise((r) => setTimeout(r, pollIntervalMs));
        if (runRef.current !== run) return;
        const res = await getTranscribe(id);
        if (runRef.current !== run) return;
        if (res.unknownId) {
          idRef.current = null;
          return fail("The dashboard no longer has this recording. Record again.");
        }
        if (res.state === "done") {
          const text = (res.text ?? "").trim();
          if (!text) return fail(NO_SPEECH_MESSAGE);
          blobRef.current = null;
          idRef.current = null;
          setStatus("idle");
          setError(null);
          onTextRef.current(text);
          return;
        }
        if (res.state === "failed") return fail(res.error || "Transcription failed.");
        if (res.ok) errors = 0;
        else if (res.error && /logged out/.test(res.error)) return fail(res.error);
        else if (++errors >= MAX_POLL_ERRORS) return fail(res.error || "Lost contact with the dashboard.");
        if (Date.now() >= deadline) return fail(TIMEOUT_MESSAGE);
      }
    },
    [pollIntervalMs, giveUpAfterMs],
  );

  const run = useCallback(
    async (blob: Blob | null) => {
      const myRun = ++runRef.current;
      setError(null);
      let id = idRef.current;
      if (!id) {
        if (!blob) return fail("Nothing to retry. Record again.");
        setStatus("uploading");
        const up = await uploadAudio(blob);
        if (runRef.current !== myRun) return;
        if (!up.ok) return fail(up.error);
        id = up.id;
        idRef.current = id;
      }
      setStatus("transcribing");
      const started = await startTranscribe(id);
      if (runRef.current !== myRun) return;
      if (started.unknownId) {
        idRef.current = null;
        return fail("The dashboard no longer has this recording. Record again.");
      }
      if (!started.ok) return fail(started.error || "Couldn't start the transcription.");
      await poll(id, myRun);
    },
    [poll],
  );

  const submit = useCallback(
    (blob: Blob) => {
      blobRef.current = blob;
      idRef.current = null;
      return run(blob);
    },
    [run],
  );
  const retry = useCallback(() => run(blobRef.current), [run]);
  /** Abandon the job (Cancel, close, "Record again"): nothing lands later. */
  const reset = useCallback(() => {
    runRef.current++;
    blobRef.current = null;
    idRef.current = null;
    setStatus("idle");
    setError(null);
  }, []);

  useEffect(() => () => void runRef.current++, []);

  return { status, error, submit, retry, reset };
}
