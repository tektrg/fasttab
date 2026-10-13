import { COUNTDOWN_FROM_MS, MAX_RECORDING_MS } from "../voice/useVoiceRecorder";
import { formatClock } from "../voice/transcript";
import type { VoiceInput } from "../voice/useVoiceInput";

/** Mic button and the states after it: recording (timer, Stop, Cancel),
 *  uploading, transcribing, failed (Retry, Record again). Presentational —
 *  all behaviour is in useVoiceInput. The transcript itself lands in the
 *  message box; sending stays the user's own tap. */
export function VoiceRecorderBar({ voice, disabled }: { voice: VoiceInput; disabled?: boolean }) {
  const { phase, elapsedMs, error } = voice;
  const left = MAX_RECORDING_MS - elapsedMs;
  return (
    <div className="voice-bar" aria-live="polite">
      {(phase === "idle" || phase === "starting") && (
        <button
          type="button"
          className="voice-button"
          aria-label="record voice message"
          disabled={disabled || phase === "starting"}
          onClick={voice.start}
        >
          <MicIcon /> {phase === "starting" ? "Starting…" : "Voice"}
        </button>
      )}
      {phase === "recording" && (
        <>
          <span className="voice-dot" aria-hidden="true" />
          <span className="voice-clock" role="timer" aria-label="recording time">
            {formatClock(elapsedMs)}
          </span>
          {elapsedMs >= COUNTDOWN_FROM_MS && (
            <span className="voice-countdown">{formatClock(left)} left</span>
          )}
          <button type="button" className="voice-button voice-stop" aria-label="stop recording" onClick={voice.stop}>
            Stop
          </button>
          <button type="button" className="voice-button" aria-label="cancel recording" onClick={voice.cancel}>
            Cancel
          </button>
        </>
      )}
      {(phase === "uploading" || phase === "transcribing") && (
        <>
          <span className="voice-working">{phase === "uploading" ? "Uploading…" : "Transcribing…"}</span>
          <button type="button" className="voice-button" aria-label="cancel transcription" onClick={voice.cancel}>
            Cancel
          </button>
        </>
      )}
      {phase === "failed" && (
        <>
          {voice.canRetry && (
            <button type="button" className="voice-button" aria-label="retry transcription" onClick={() => void voice.retry()}>
              Retry
            </button>
          )}
          <button type="button" className="voice-button" aria-label="record again" disabled={disabled} onClick={voice.start}>
            Record again
          </button>
        </>
      )}
      {error && <span className="voice-error" role="alert">{error}</span>}
    </div>
  );
}

function MicIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"
      strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <rect x="9" y="3" width="6" height="12" rx="3" />
      <path d="M5 11a7 7 0 0 0 14 0M12 18v3" />
    </svg>
  );
}
