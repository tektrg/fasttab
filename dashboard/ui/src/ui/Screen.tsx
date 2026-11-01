import { useEffect, useRef, useState, type CSSProperties, type ReactNode, type TouchEvent } from "react";
import { createPortal } from "react-dom";
import { useKeyboardOpen } from "../hooks/useKeyboardOpen";
import "./Screen.css";

/** A full-screen phone screen pushed in from the right (iOS navigation
 *  style): header with a back button, ONE scroll area (`.ui-screen__body`),
 *  a footer pinned at the bottom. Replaces the Vaul bottom sheet on the phone
 *  because the sheet's keyboard lift hid focused fields under the keyboard.
 *
 *  KEYBOARD: while a soft keyboard is up the screen's box follows the visual
 *  viewport (height + offsetTop), so the footer sits right above the keyboard;
 *  any focused field is scrolled into view. `data-keyboard` lets CSS slim the
 *  footer down.
 *
 *  BACK: opening pushes a history entry, so the browser / OS back gesture
 *  closes the screen; the back button and a swipe from the left edge do too.
 *
 *  SCROLL RULE: content inside must not declare its own `overflow-y:
 *  auto|scroll` or `max-height` (enforced by __tests__/screen-layout). */
interface ScreenProps {
  open: boolean;
  onClose: () => void;
  /** Accessible name; also rendered as the header text when `header` is omitted. */
  title: string;
  /** Custom header content (avatar, name, status, actions). */
  header?: ReactNode;
  children: ReactNode;
  /** Pinned to the bottom (composer / actions); rides above the keyboard. */
  footer?: ReactNode;
}

const EXIT_MS = 220;
/** A touch starting this close to the left edge and dragging this far right goes back. */
const EDGE_PX = 24;
const SWIPE_BACK_PX = 80;
const HISTORY_MARK = "uiScreen";

/** The visual viewport box while the keyboard is up; null otherwise. */
function useKeyboardBox(keyboard: boolean): { top: number; height: number } | null {
  const [box, setBox] = useState<{ top: number; height: number } | null>(null);
  useEffect(() => {
    const vv = window.visualViewport;
    if (!keyboard || !vv) {
      setBox(null);
      return;
    }
    const sync = () => setBox({ top: Math.round(vv.offsetTop), height: Math.round(vv.height) });
    sync();
    vv.addEventListener("resize", sync);
    vv.addEventListener("scroll", sync);
    return () => {
      vv.removeEventListener("resize", sync);
      vv.removeEventListener("scroll", sync);
    };
  }, [keyboard]);
  return box;
}

/** Back = one history entry per open screen. The deferred `back()` survives
 *  React StrictMode's unmount/remount (the remount sees the entry and keeps it). */
function useHistoryBack(open: boolean, onClose: () => void) {
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;
  const openRef = useRef(open);
  openRef.current = open;
  useEffect(() => {
    if (!open) return;
    if (!window.history.state?.[HISTORY_MARK]) window.history.pushState({ ...window.history.state, [HISTORY_MARK]: true }, "");
    let popped = false;
    const onPop = () => {
      popped = true;
      onCloseRef.current();
    };
    window.addEventListener("popstate", onPop);
    return () => {
      window.removeEventListener("popstate", onPop);
      if (popped) return;
      setTimeout(() => {
        if (!openRef.current && window.history.state?.[HISTORY_MARK]) window.history.back();
      }, 0);
    };
  }, [open]);
}

export function Screen({ open, onClose, title, header, children, footer }: ScreenProps) {
  const [mounted, setMounted] = useState(open);
  useEffect(() => {
    if (open) {
      setMounted(true);
      return;
    }
    const t = setTimeout(() => setMounted(false), EXIT_MS);
    return () => clearTimeout(t);
  }, [open]);
  useHistoryBack(open, onClose);
  const keyboard = useKeyboardOpen();
  const box = useKeyboardBox(keyboard && open);

  // Keep the focused field visible once the keyboard has resized the box.
  useEffect(() => {
    if (!box) return;
    const el = document.activeElement;
    if (el instanceof HTMLElement && el.closest(".ui-screen")) el.scrollIntoView?.({ block: "nearest" });
  }, [box]);

  const swipe = useRef<{ x: number; y: number } | null>(null);
  const onTouchStart = (e: TouchEvent) => {
    const t = e.touches[0];
    swipe.current = t && t.clientX <= EDGE_PX ? { x: t.clientX, y: t.clientY } : null;
  };
  const onTouchEnd = (e: TouchEvent) => {
    const start = swipe.current;
    swipe.current = null;
    const t = e.changedTouches[0];
    if (start && t && t.clientX - start.x > SWIPE_BACK_PX && Math.abs(t.clientY - start.y) < t.clientX - start.x) onClose();
  };

  if (!mounted && !open) return null;
  const style = box ? ({ top: `${box.top}px`, height: `${box.height}px`, bottom: "auto" } as CSSProperties) : undefined;
  return createPortal(
    <div
      className="ui-screen"
      role="dialog"
      aria-modal="true"
      aria-label={title}
      data-state={open ? "open" : "closed"}
      data-keyboard={(keyboard && open) || undefined}
      style={style}
      onTouchStart={onTouchStart}
      onTouchEnd={onTouchEnd}
    >
      <div className="ui-screen__head">
        <button type="button" className="ui-screen__back" aria-label="Back" onClick={onClose}>
          <svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true"><path d="M15 5l-7 7 7 7" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" /></svg>
        </button>
        {header ?? <h2 className="ui-screen__title">{title}</h2>}
      </div>
      <div className="ui-screen__body">{children}</div>
      {footer && <div className="ui-screen__footer">{footer}</div>}
    </div>,
    document.body,
  );
}
