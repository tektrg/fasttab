import { useEffect, useState } from "react";

/** Pixels the iOS on-screen keyboard has eaten off the bottom of the
 *  layout viewport, right now. iOS Safari shrinks `visualViewport` (not the
 *  layout viewport a `position: fixed` element is anchored to) when the
 *  keyboard opens, so a naive `position: fixed; bottom: 0` composer ends up
 *  UNDER the keyboard instead of pinned above it. Reading this offset and
 *  translating the pinned bar up by it is the standard workaround (there is
 *  no CSS-only fix as of iOS 18). Returns 0 (no-op) when `visualViewport`
 *  is unsupported — the bar just sits at the safe-area edge as it would on
 *  any other browser. */
export function useVisualViewportOffset(): number {
  const [offset, setOffset] = useState(0);

  useEffect(() => {
    const vv = window.visualViewport;
    if (!vv) return;
    const update = () => {
      const keyboardInset = window.innerHeight - vv.height - vv.offsetTop;
      setOffset(Math.max(0, Math.round(keyboardInset)));
    };
    update();
    vv.addEventListener("resize", update);
    vv.addEventListener("scroll", update);
    return () => {
      vv.removeEventListener("resize", update);
      vv.removeEventListener("scroll", update);
    };
  }, []);

  return offset;
}
