import { useEffect, useState, type CSSProperties, type FocusEvent, type ReactNode } from "react";
import { Drawer } from "vaul";
import { useKeyboardOpen } from "../hooks/useKeyboardOpen";
import "./Sheet.css";

/** SCROLL RULE: `.ui-sheet__body` is the ONLY scroll area in a sheet. Content
 *  placed inside must never declare its own `overflow-y: auto|scroll` or a
 *  `max-height` (nested scrollers fight the drag gesture and collapse to one
 *  line when the keyboard shrinks the sheet). Long content grows, or collapses
 *  behind a "Show more" toggle. Enforced by __tests__/sheet-single-scroll.
 *
 *  KEYBOARD: while a soft keyboard is up the sheet gets `data-keyboard` and
 *  `--ui-vvh` (visual viewport height); phone.css hides everything in the
 *  footer except the message field. Vaul still owns the lift (see `footer`).
 *  `interactive-widget=resizes-content` is deliberately NOT in the viewport
 *  meta: it only affects Android Chrome and would shrink the layout viewport
 *  so Vaul's `innerHeight - visualViewport.height` diff reads 0 there.
 *
 *  PEEK: at the 60% snap Vaul slides the full-height sheet down by the
 *  hidden 40% of the screen, which would put the footer off screen. The
 *  sheet pads its bottom by `--ui-peek-hidden` so the footer sits at the
 *  visible edge; the padding drops at full height and while typing. */
/** Peek = ~60% of the screen; full = fully open. */
export const SHEET_SNAPS = [0.6, 1] as const;
type Snap = number | string | null;

interface SheetProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  /** Accessible name; also rendered as the header when `header` is omitted. */
  title: string;
  /** Custom header content (avatar, name, status). Falls back to `title`. */
  header?: ReactNode;
  children: ReactNode;
  /** Pinned to the bottom (composer / actions). Rides above the keyboard: Vaul's `repositionInputs` (default on) lifts the whole sheet by the keyboard height — do NOT also translate the footer (double lift). */
  footer?: ReactNode;
}

export function Sheet({ open, onOpenChange, title, header, children, footer }: SheetProps) {
  const [snap, setSnap] = useState<Snap>(SHEET_SNAPS[0]);
  const isFull = snap === SHEET_SNAPS[1];
  const keyboard = useKeyboardOpen();
  const [vvh, setVvh] = useState<number | null>(null);
  useEffect(() => {
    const vv = window.visualViewport;
    if (!keyboard || !vv) {
      setVvh(null);
      return;
    }
    const sync = () => setVvh(Math.round(vv.height));
    sync();
    vv.addEventListener("resize", sync);
    return () => vv.removeEventListener("resize", sync);
  }, [keyboard]);
  // Typing needs room: any text field gaining focus opens the sheet fully.
  const onFocusCapture = (e: FocusEvent<HTMLElement>) => {
    const t = e.target;
    if (t instanceof HTMLElement && (t.isContentEditable || /^(INPUT|TEXTAREA)$/.test(t.tagName))) setSnap(SHEET_SNAPS[1]);
  };

  return (
    <Drawer.Root
      open={open}
      onOpenChange={(next) => {
        if (!next) setSnap(SHEET_SNAPS[0]);
        onOpenChange(next);
      }}
      snapPoints={[...SHEET_SNAPS]}
      activeSnapPoint={snap}
      setActiveSnapPoint={setSnap}
      fadeFromIndex={0}
    >
      <Drawer.Portal>
        <Drawer.Overlay className="ui-sheet__scrim" />
        <Drawer.Content className="ui-sheet" data-full={isFull || undefined}
          data-keyboard={keyboard || undefined}
          style={{ "--ui-peek-hidden": `${(1 - SHEET_SNAPS[0]) * 100}dvh`, ...(keyboard && vvh ? { "--ui-vvh": `${vvh}px` } : {}) } as CSSProperties}
          onFocusCapture={onFocusCapture}
          aria-describedby={undefined}
        >
          <div className="ui-sheet__grab" aria-hidden="true" />
          <div className="ui-sheet__head">
            {header ?? null}
            <Drawer.Title className={header ? "ui-sheet__sr-title" : "ui-sheet__title"}>{title}</Drawer.Title>
          </div>
          <div className="ui-sheet__body" data-vaul-no-drag={isFull ? "" : undefined}>{children}</div>
          {footer && (
            <div className="ui-sheet__footer">{footer}</div>
          )}
        </Drawer.Content>
      </Drawer.Portal>
    </Drawer.Root>
  );
}
