/** Status language shared by every AgentBar surface: each state has a unique
 *  shape + colour + word, so it reads without colour. Only `run` animates. */
export type UiStatus = "need" | "ask" | "run" | "park" | "sleep" | "end" | "warn";

export type StatusShape =
  | "diamond"
  | "ring"
  | "dot"
  | "square"
  | "dashed-ring"
  | "hollow-ring"
  | "triangle";

export interface StatusMeta {
  label: string;
  shape: StatusShape;
  /** CSS custom property (a token from index.css) that colours this state. */
  colorVar: string;
  pulses: boolean;
}

export const STATUS_META: Record<UiStatus, StatusMeta> = {
  need: { label: "Blocked", shape: "diamond", colorVar: "--need", pulses: false },
  ask: { label: "Ask", shape: "ring", colorVar: "--ask", pulses: false },
  run: { label: "Working", shape: "dot", colorVar: "--run", pulses: true },
  park: { label: "Parked", shape: "square", colorVar: "--park", pulses: false },
  sleep: { label: "Sleeping", shape: "dashed-ring", colorVar: "--ink-4", pulses: false },
  end: { label: "Ended", shape: "hollow-ring", colorVar: "--ink-4", pulses: false },
  warn: { label: "Unknown", shape: "triangle", colorVar: "--warn", pulses: false },
};

export const ALL_STATUSES = Object.keys(STATUS_META) as UiStatus[];
