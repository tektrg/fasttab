import { useCallback, useEffect, useRef, useState } from "react";

/** Recording only: mic -> MediaRecorder -> one Blob. Upload and
 *  transcription live in useTranscription. */
export const MIN_RECORDING_MS = 700;
export const MAX_RECORDING_MS = 15 * 60 * 1000;
/** The countdown shows from here (1:00 before the cap). */
export const COUNTDOWN_FROM_MS = 14 * 60 * 1000;

/** Preference order: Safari records mp4, Chrome webm/opus. */
const MIME_PREFERENCE = ["audio/mp4", "audio/webm;codecs=opus", "audio/webm"];

export const MIC_DENIED_MESSAGE =
  "Microphone access is blocked. Allow the microphone for this site (or this app) in your phone's Settings, then try again.";
export const MIC_UNSUPPORTED_MESSAGE =
  "Voice recording isn't available here: this browser has no recorder, or the page isn't on a secure (https) connection.";
export const TOO_SHORT_MESSAGE = "That recording was too short, so it was ignored.";

/** First supported mime, or "" to let the browser choose. */
export function pickRecorderMime(): string {
  const Recorder = (globalThis as { MediaRecorder?: typeof MediaRecorder }).MediaRecorder;
  if (!Recorder?.isTypeSupported) return "";
  return MIME_PREFERENCE.find((m) => Recorder.isTypeSupported(m)) ?? "";
}

/** "audio/webm;codecs=opus" -> "audio/webm" (what the upload header carries). */
export function baseMime(mime: string): string {
  return mime.split(";")[0].trim();
}

export type RecorderPhase = "idle" | "starting" | "recording";

export interface RecorderOptions {
  /** Called once with the finished recording (not on cancel / too short). */
  onRecorded: (blob: Blob) => void;
  /** Clock override for tests. */
  now?: () => number;
}

export function useVoiceRecorder({ onRecorded, now = Date.now }: RecorderOptions) {
  const [phase, setPhase] = useState<RecorderPhase>("idle");
  const [elapsedMs, setElapsedMs] = useState(0);
  const [notice, setNotice] = useState<string | null>(null);
  const recorderRef = useRef<MediaRecorder | null>(null);
  const streamRef = useRef<MediaStream | null>(null);
  const chunksRef = useRef<Blob[]>([]);
  const startedAtRef = useRef(0);
  const discardRef = useRef(false);
  /** A cancel/unmount that arrives while the mic permission prompt is open. */
  const abortStartRef = useRef(false);
  const onRecordedRef = useRef(onRecorded);
  onRecordedRef.current = onRecorded;
  const nowRef = useRef(now);
  nowRef.current = now;

  const releaseMic = useCallback(() => {
    streamRef.current?.getTracks().forEach((t) => t.stop());
    streamRef.current = null;
  }, []);

  const finish = useCallback(
    (mimeHint: string) => {
      const recorder = recorderRef.current;
      recorderRef.current = null;
      releaseMic();
      const durationMs = nowRef.current() - startedAtRef.current;
      const chunks = chunksRef.current;
      chunksRef.current = [];
      setPhase("idle");
      setElapsedMs(0);
      if (discardRef.current) return;
      if (durationMs < MIN_RECORDING_MS || chunks.length === 0) {
        setNotice(TOO_SHORT_MESSAGE);
        return;
      }
      const type = baseMime(recorder?.mimeType || mimeHint) || "audio/mp4";
      onRecordedRef.current(new Blob(chunks, { type }));
    },
    [releaseMic],
  );

  const start = useCallback(async () => {
    if (phase !== "idle") return;
    setNotice(null);
    const Recorder = (globalThis as { MediaRecorder?: typeof MediaRecorder }).MediaRecorder;
    if (!Recorder || !navigator.mediaDevices?.getUserMedia) {
      setNotice(MIC_UNSUPPORTED_MESSAGE);
      return;
    }
    abortStartRef.current = false;
    setPhase("starting");
    let stream: MediaStream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (e) {
      setPhase("idle");
      const name = (e as { name?: string })?.name;
      const denied = name === "NotAllowedError" || name === "SecurityError" || name === "PermissionDeniedError";
      setNotice(denied ? MIC_DENIED_MESSAGE : "Couldn't open the microphone. Check that no other app is using it.");
      return;
    }
    if (abortStartRef.current) {
      stream.getTracks().forEach((t) => t.stop());
      setPhase("idle");
      return;
    }
    streamRef.current = stream;
    const mime = pickRecorderMime();
    let recorder: MediaRecorder;
    try {
      recorder = mime ? new Recorder(stream, { mimeType: mime }) : new Recorder(stream);
    } catch {
      releaseMic();
      setPhase("idle");
      setNotice(MIC_UNSUPPORTED_MESSAGE);
      return;
    }
    chunksRef.current = [];
    discardRef.current = false;
    recorder.ondataavailable = (e) => {
      if (e.data && e.data.size > 0) chunksRef.current.push(e.data);
    };
    recorder.onstop = () => finish(mime);
    recorder.onerror = () => {
      discardRef.current = true;
      setNotice("The recording failed. Try again.");
      if (recorder.state !== "inactive") recorder.stop();
      else finish(mime);
    };
    recorderRef.current = recorder;
    startedAtRef.current = nowRef.current();
    setElapsedMs(0);
    recorder.start();
    setPhase("recording");
  }, [phase, finish, releaseMic]);

  const stopRecorder = useCallback((discard: boolean) => {
    const recorder = recorderRef.current;
    if (!recorder) {
      // Still waiting on the permission prompt.
      if (discard) abortStartRef.current = true;
      return;
    }
    if (discard) discardRef.current = true;
    if (recorder.state !== "inactive") recorder.stop();
    else finish(recorder.mimeType);
  }, [finish]);

  const stop = useCallback(() => stopRecorder(false), [stopRecorder]);
  const cancel = useCallback(() => stopRecorder(true), [stopRecorder]);

  // Timer, 15-minute cap, and backgrounding (keep what was recorded).
  useEffect(() => {
    if (phase !== "recording") return;
    const tick = window.setInterval(() => {
      const elapsed = nowRef.current() - startedAtRef.current;
      setElapsedMs(elapsed);
      if (elapsed >= MAX_RECORDING_MS) stopRecorder(false);
    }, 250);
    const onHidden = () => {
      if (document.visibilityState === "hidden") stopRecorder(false);
    };
    document.addEventListener("visibilitychange", onHidden);
    return () => {
      window.clearInterval(tick);
      document.removeEventListener("visibilitychange", onHidden);
    };
  }, [phase, stopRecorder]);

  // Leaving the screen mid-recording: free the mic, deliver nothing.
  useEffect(
    () => () => {
      abortStartRef.current = true;
      discardRef.current = true;
      const recorder = recorderRef.current;
      if (recorder && recorder.state !== "inactive") recorder.stop();
      recorderRef.current = null;
      releaseMic();
    },
    [releaseMic],
  );

  const clearNotice = useCallback(() => setNotice(null), []);
  return { phase, elapsedMs, notice, start, stop, cancel, clearNotice };
}
