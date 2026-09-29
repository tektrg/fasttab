import { useState, type ReactNode } from "react";
import { Drawer } from "vaul";
import { useVisualViewportOffset } from "../hooks/useVisualViewportOffset";
import "./Sheet.css";

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
  /** Pinned to the bottom (composer / actions). Rides above the keyboard. */
  footer?: ReactNode;
}

export function Sheet({ open, onOpenChange, title, header, children, footer }: SheetProps) {
  const [snap, setSnap] = useState<Snap>(SHEET_SNAPS[0]);
  const keyboardInset = useVisualViewportOffset();
  const isFull = snap === SHEET_SNAPS[1];

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
        <Drawer.Content className="ui-sheet" data-full={isFull || undefined} aria-describedby={undefined}>
          <div className="ui-sheet__grab" aria-hidden="true" />
          <div className="ui-sheet__head">
            {header ?? null}
            <Drawer.Title className={header ? "ui-sheet__sr-title" : "ui-sheet__title"}>{title}</Drawer.Title>
          </div>
          <div className="ui-sheet__body" data-vaul-no-drag={isFull ? "" : undefined}>{children}</div>
          {footer && (
            <div
              className="ui-sheet__footer"
              style={{ transform: keyboardInset > 0 ? `translateY(-${keyboardInset}px)` : undefined }}
            >
              {footer}
            </div>
          )}
        </Drawer.Content>
      </Drawer.Portal>
    </Drawer.Root>
  );
}
