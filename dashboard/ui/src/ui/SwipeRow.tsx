import { useRef, useState, type ReactNode } from "react";
import {
  REVEAL_PX,
  isOpen,
  swipeEnd,
  swipeIdle,
  swipeMove,
  swipeStart,
  type SwipeState,
} from "../components/phone/swipeGesture";
import "./SwipeRow.css";

export interface SwipeAction {
  label: string;
  tone: "neutral" | "danger";
  disabled?: boolean;
  onPress: () => void;
}

/** A row that slides left to reveal up to two action buttons. Pointer events,
 *  `touch-action: pan-y` (the browser keeps vertical scroll; we only own the
 *  horizontal axis). The sheet stays the accessible route to the same verbs,
 *  so the tray is hidden from assistive tech until opened. The tray stays open
 *  after a press (an armed "Confirm" must remain visible); tapping the row closes it. */
export function SwipeRow({
  children,
  actions,
}: {
  children: ReactNode;
  actions: SwipeAction[];
}) {
  const [state, setState] = useState<SwipeState>(() => swipeIdle());
  const stateRef = useRef(state);
  const swallowNextClick = useRef(false);
  const commit = (next: SwipeState) => {
    stateRef.current = next;
    setState(next);
  };
  const open = isOpen(state);
  const dragging = state.phase === "swipe";

  const release = (target: HTMLElement, pointerId: number) => {
    if (target.hasPointerCapture?.(pointerId)) target.releasePointerCapture(pointerId);
    const end = swipeEnd(stateRef.current);
    if (end.swallowClick) swallowNextClick.current = true;
    commit(end.state);
  };

  return (
    <div className="ui-swipe" data-open={open || undefined}>
      <div className="ui-swipe__tray" style={{ width: REVEAL_PX }} aria-hidden={!open} data-testid="swipe-tray">
        {actions.map((a) => (
          <button
            key={a.label}
            type="button"
            className="ui-swipe__action"
            data-tone={a.tone}
            disabled={a.disabled}
            tabIndex={open ? 0 : -1}
            onClick={a.onPress}
          >
            {a.label}
          </button>
        ))}
      </div>
      <div
        className="ui-swipe__content"
        data-dragging={dragging || undefined}
        style={{ transform: `translateX(${state.offset}px)` }}
        onPointerDown={(e) => {
          // A cancelled drag never clicks: don't let its flag eat the next tap.
          swallowNextClick.current = false;
          commit(swipeStart(stateRef.current, e.clientX, e.clientY));
        }}
        onPointerMove={(e) => {
          const before = stateRef.current.phase;
          const next = swipeMove(stateRef.current, e.clientX, e.clientY);
          if (before !== "swipe" && next.phase === "swipe") e.currentTarget.setPointerCapture?.(e.pointerId);
          if (next !== stateRef.current) commit(next);
        }}
        onPointerUp={(e) => release(e.currentTarget, e.pointerId)}
        onPointerCancel={(e) => release(e.currentTarget, e.pointerId)}
        onClickCapture={(e) => {
          // A drag ends in a click on the row: swallow it. A tap on an open
          // row only closes the tray.
          if (swallowNextClick.current) {
            swallowNextClick.current = false;
            e.stopPropagation();
            e.preventDefault();
          } else if (open) {
            e.stopPropagation();
            e.preventDefault();
            commit(swipeIdle());
          }
        }}
      >
        {children}
      </div>
    </div>
  );
}
