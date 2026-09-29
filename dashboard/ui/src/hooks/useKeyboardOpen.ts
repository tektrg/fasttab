import { useEffect, useState } from "react";

/** The on-screen keyboard eats at least this much of the viewport. Smaller
 *  changes are Safari's collapsing toolbar, not a keyboard. */
export const KEYBOARD_MIN_PX = 150;

/** True while a soft keyboard is up over a focused text field. iOS shrinks
 *  `visualViewport` but leaves the layout viewport alone, so `position:
 *  fixed; bottom: 0` chrome (the tab bar) is left floating over/under the
 *  keyboard; callers hide it instead. A pinch-zoom also shrinks the visual
 *  viewport (scale > 1) — that is not a keyboard. Sheets need no such hook:
 *  Vaul's own `repositionInputs` lifts the sheet (footer included). */
export function useKeyboardOpen(): boolean {
  const [open, setOpen] = useState(false);
  useEffect(() => {
    const vv = window.visualViewport;
    if (!vv) return;
    const update = () => {
      const el = document.activeElement;
      const typing = el instanceof HTMLElement && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName));
      const eaten = window.innerHeight - vv.height;
      setOpen(typing && vv.scale <= 1.01 && eaten > KEYBOARD_MIN_PX);
    };
    update();
    vv.addEventListener("resize", update);
    document.addEventListener("focusin", update);
    document.addEventListener("focusout", update);
    return () => {
      vv.removeEventListener("resize", update);
      document.removeEventListener("focusin", update);
      document.removeEventListener("focusout", update);
    };
  }, []);
  return open;
}
