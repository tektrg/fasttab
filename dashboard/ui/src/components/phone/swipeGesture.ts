/** Pure state machine for swipe-left-to-reveal on a list row. No DOM, no
 *  timers: the component feeds pointer coordinates in and renders `offset`.
 *
 *  A gesture starts "pending" and commits to ONE axis once the finger moved
 *  past SLOP: mostly vertical -> "scroll" (we ignore the rest, the browser
 *  scrolls the list); mostly horizontal -> "swipe". Committing early keeps a
 *  diagonal scroll from dragging the row. */

/** Width of the revealed action tray (two 80pt buttons). */
export const REVEAL_PX = 160;
/** Finger travel before we pick an axis. */
export const SLOP_PX = 8;
/** Released past this share of REVEAL_PX = snaps open, else closed. */
export const SNAP_RATIO = 0.4;

export type SwipePhase = "idle" | "pending" | "swipe" | "scroll";

export interface SwipeState {
  phase: SwipePhase;
  startX: number;
  startY: number;
  /** Row offset when the gesture began (0 closed, -REVEAL_PX open). */
  baseOffset: number;
  /** Current row offset in px, always in [-REVEAL_PX, 0]. */
  offset: number;
}

export const swipeIdle = (open = false): SwipeState => ({
  phase: "idle",
  startX: 0,
  startY: 0,
  baseOffset: open ? -REVEAL_PX : 0,
  offset: open ? -REVEAL_PX : 0,
});

const clampOffset = (px: number) => Math.min(0, Math.max(-REVEAL_PX, px));

export function swipeStart(state: SwipeState, x: number, y: number): SwipeState {
  return { ...state, phase: "pending", startX: x, startY: y, baseOffset: state.offset };
}

export function swipeMove(state: SwipeState, x: number, y: number): SwipeState {
  if (state.phase === "idle" || state.phase === "scroll") return state;
  const dx = x - state.startX;
  const dy = y - state.startY;
  if (state.phase === "pending") {
    if (Math.max(Math.abs(dx), Math.abs(dy)) < SLOP_PX) return state;
    if (Math.abs(dy) >= Math.abs(dx)) return { ...state, phase: "scroll" };
    return { ...state, phase: "swipe", offset: clampOffset(state.baseOffset + dx) };
  }
  return { ...state, offset: clampOffset(state.baseOffset + dx) };
}

export interface SwipeEnd {
  state: SwipeState;
  /** True when the finger really dragged: the click that follows must be swallowed. */
  swallowClick: boolean;
}

/** Release (or cancel): snap open past the threshold, else closed. */
export function swipeEnd(state: SwipeState): SwipeEnd {
  if (state.phase !== "swipe") return { state: swipeIdle(state.baseOffset !== 0), swallowClick: false };
  const open = state.offset <= -REVEAL_PX * SNAP_RATIO;
  return { state: swipeIdle(open), swallowClick: true };
}

export const isOpen = (state: SwipeState) => state.offset <= -REVEAL_PX * SNAP_RATIO && state.phase !== "swipe";
