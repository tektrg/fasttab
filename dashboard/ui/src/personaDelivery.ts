import type { PersonaSummary } from "./api";
import type { BoardRow } from "./types";
import { canMessage, isBlockedOnYou } from "./messageGates";

/** What sending to a persona would do right now — the phone's copy of
 *  AgentBar's `PersonaDeliveryEffect.derive` (Sources/AgentBar/Routing/).
 *  Same five effects and wording, so both surfaces say the same thing. */
export type PersonaEffect =
  | "sendToMain"
  | "mainWaitingOnYou"
  | "mainUnreachable"
  | "resumeLast"
  | "startNew";

export const EFFECT_TEXT: Record<PersonaEffect, string> = {
  sendToMain: "send to main session",
  mainWaitingOnYou: "main session is waiting on you",
  mainUnreachable: "main session can't take messages here",
  resumeLast: "resume last conversation",
  startNew: "start new session",
};

export type MainSession =
  | { kind: "absent" }
  | { kind: "ready" | "waitingOnYou" | "unreachable"; row: BoardRow };

/** The persona's main session, resolved against the live board rows. */
export function mainSession(persona: PersonaSummary, rows: BoardRow[]): MainSession {
  const row = persona.mainRowId
    ? rows.find((r) => r.rowId === persona.mainRowId && r.status !== "ended")
    : undefined;
  if (!row) return { kind: "absent" };
  if (isBlockedOnYou(row.derived)) return { kind: "waitingOnYou", row };
  if (!canMessage(row.derived)) return { kind: "unreachable", row };
  return { kind: "ready", row };
}

/** `forcedStartNew` (the "Start a new session instead" switch) always wins,
 *  like AgentBar's Tab toggle. */
export function deriveEffect(
  main: MainSession,
  idleStart: PersonaSummary["idleStart"],
  forcedStartNew: boolean,
): PersonaEffect {
  if (forcedStartNew) return "startNew";
  switch (main.kind) {
    case "ready":
      return "sendToMain";
    case "waitingOnYou":
      return "mainWaitingOnYou";
    case "unreachable":
      return "mainUnreachable";
    case "absent":
      return idleStart === "resume" ? "resumeLast" : "startNew";
  }
}

export function isStartEffect(effect: PersonaEffect): boolean {
  return effect === "resumeLast" || effect === "startNew";
}

/** Why this persona can't be started from here, else null. The remote
 *  listener starts only personas with `remoteStart: true`; localhost omits
 *  the field and starts any offered persona. */
export function startRefusal(persona: PersonaSummary): string | null {
  if (persona.offline) return "its machine is offline";
  if (persona.remoteStart === false)
    return "can't be started from the phone — turn on remoteStart for it on the Mac";
  return null;
}
