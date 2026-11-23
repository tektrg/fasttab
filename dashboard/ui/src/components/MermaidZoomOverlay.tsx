import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import {
  ZOOM_STEP, fitView, panBy, svgSize, wheelPixels, wheelZoomFactor, zoomAt,
  type Size, type View,
} from "./mermaidZoom";

/**
 * Fullscreen pan/zoom viewer for one rendered mermaid diagram. Lazy-loaded by
 * MermaidBlock (its own small chunk), no dependency: pointer events + wheel.
 *
 * - Phone: one finger drags, two fingers pinch (zoom around the midpoint).
 * - Desktop: ctrl/cmd+wheel and trackpad pinch (which browsers report as
 *   ctrl+wheel; Safari's gesture events too) zoom around the cursor; plain
 *   wheel and mouse drag pan.
 * - Buttons + / − / Fit / ×, keys + − 0 Esc. Starts at "fit", 0.25x–8x.
 * - Vector-sharp: the SVG is drawn at natural size × scale (real width and
 *   height), only translated — never a CSS-scaled bitmap.
 * - While open: page scroll locked, focus trapped; on close focus and page
 *   scroll position are restored.
 *
 * Coexisting with the phone sheet (vaul = Radix Dialog, modal): this is
 * portalled to <body>, i.e. OUTSIDE the sheet, so Radix would treat our
 * focus/pointer/Esc as "outside" and close the sheet or steal focus back.
 * Window-capture listeners keep those events away from it while open.
 */

const FOCUSABLE = "button:not([disabled]), [href], [tabindex]:not([tabindex='-1'])";

export default function MermaidZoomOverlay({
  svg,
  onClose,
  returnFocus,
}: {
  svg: string;
  onClose: () => void;
  /** Focused on close when the element focused at open is gone / was <body>. */
  returnFocus?: HTMLElement | null;
}): React.ReactElement {
  const rootRef = useRef<HTMLDivElement>(null);
  const viewportRef = useRef<HTMLDivElement>(null);
  const closeRef = useRef<HTMLButtonElement>(null);
  const natural = useMemo<Size>(() => svgSize(svg), [svg]);
  const boxRef = useRef<Size>({ w: 1, h: 1 });
  const [view, setView] = useState<View>({ scale: 1, x: 0, y: 0 });
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  const measure = useCallback((): Size => {
    const el = viewportRef.current;
    const r = el?.getBoundingClientRect();
    const w = r && r.width > 0 ? r.width : window.innerWidth;
    const h = r && r.height > 0 ? r.height : window.innerHeight;
    boxRef.current = { w, h };
    return boxRef.current;
  }, []);

  const fit = useCallback(() => setView(fitView(natural, measure())), [natural, measure]);
  const zoomCenter = useCallback((factor: number) => {
    const { w, h } = measure();
    setView((v) => zoomAt(v, factor, w / 2, h / 2));
  }, [measure]);

  useLayoutEffect(() => {
    fit();
  }, [fit]);

  // Open/close side effects: scroll lock, focus in + restore, keys, and
  // keeping Radix (the phone sheet) out of our events.
  useEffect(() => {
    const root = rootRef.current!;
    const prevFocus = document.activeElement as HTMLElement | null;
    const scrollX = window.scrollX;
    const scrollY = window.scrollY;
    const body = document.body;
    const html = document.documentElement;
    const prevOverflow = body.style.overflow;
    const prevOverscroll = html.style.overscrollBehavior;
    body.style.overflow = "hidden";
    html.style.overscrollBehavior = "none";
    closeRef.current?.focus({ preventScroll: true });

    const inside = (t: EventTarget | null) => t instanceof Node && root.contains(t);
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        e.stopImmediatePropagation();
        onCloseRef.current();
        return;
      }
      if (e.key === "Tab") {
        const items = Array.from(root.querySelectorAll<HTMLElement>(FOCUSABLE));
        if (items.length === 0) return;
        const first = items[0];
        const last = items[items.length - 1];
        const active = document.activeElement;
        e.preventDefault();
        e.stopImmediatePropagation();
        if (e.shiftKey) (active === first || !inside(active) ? last : items[items.indexOf(active as HTMLElement) - 1]).focus();
        else (active === last || !inside(active) ? first : items[items.indexOf(active as HTMLElement) + 1]).focus();
        return;
      }
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (e.key === "+" || e.key === "=") zoomCenter(ZOOM_STEP);
      else if (e.key === "-" || e.key === "_") zoomCenter(1 / ZOOM_STEP);
      else if (e.key === "0") fit();
      else return;
      e.preventDefault();
      e.stopImmediatePropagation();
    };
    // Radix FocusScope/DismissableLayer listen on document; stop focus moves
    // into the viewer from reaching them (they'd refocus the sheet or close it).
    const onFocusIn = (e: FocusEvent) => {
      if (inside(e.target)) e.stopImmediatePropagation();
    };
    const onFocusOut = (e: FocusEvent) => {
      if (inside(e.relatedTarget)) e.stopImmediatePropagation();
    };
    // Safari pinch outside a pointer pinch would zoom the page.
    const onGesture = (e: Event) => e.preventDefault();
    const onResize = () => measure();

    window.addEventListener("keydown", onKey, true);
    window.addEventListener("focusin", onFocusIn, true);
    window.addEventListener("focusout", onFocusOut, true);
    document.addEventListener("gesturestart", onGesture, { passive: false } as AddEventListenerOptions);
    window.addEventListener("resize", onResize);
    return () => {
      window.removeEventListener("keydown", onKey, true);
      window.removeEventListener("focusin", onFocusIn, true);
      window.removeEventListener("focusout", onFocusOut, true);
      document.removeEventListener("gesturestart", onGesture);
      window.removeEventListener("resize", onResize);
      body.style.overflow = prevOverflow;
      html.style.overscrollBehavior = prevOverscroll;
      const target = prevFocus && prevFocus !== body && prevFocus.isConnected && !root.contains(prevFocus) ? prevFocus : returnFocus;
      target?.focus({ preventScroll: true });
      if (window.scrollX !== scrollX || window.scrollY !== scrollY) window.scrollTo(scrollX, scrollY);
    };
    // Mount/unmount only; handlers read refs / stable callbacks.
  }, []);

  // Pointer pan/pinch + wheel, native listeners (wheel must be non-passive).
  useEffect(() => {
    const vp = viewportRef.current!;
    const root = rootRef.current!;
    const pts = new Map<number, { x: number; y: number }>();
    const local = (e: { clientX: number; clientY: number }) => {
      const r = vp.getBoundingClientRect();
      return { x: e.clientX - r.left, y: e.clientY - r.top };
    };
    const pair = () => {
      const [a, b] = Array.from(pts.values());
      return { d: Math.hypot(b.x - a.x, b.y - a.y), mx: (a.x + b.x) / 2, my: (a.y + b.y) / 2 };
    };
    const down = (e: PointerEvent) => {
      if (e.button !== undefined && e.button > 0) return;
      pts.set(e.pointerId, local(e));
      try {
        vp.setPointerCapture(e.pointerId);
      } catch {
        /* synthetic / already released */
      }
      vp.classList.add("is-dragging");
    };
    const move = (e: PointerEvent) => {
      const prev = pts.get(e.pointerId);
      if (!prev) return;
      const next = local(e);
      if (pts.size >= 2) {
        const before = pair();
        pts.set(e.pointerId, next);
        const after = pair();
        if (before.d > 0) {
          setView((v) => panBy(zoomAt(v, after.d / before.d, before.mx, before.my), after.mx - before.mx, after.my - before.my));
        }
      } else {
        pts.set(e.pointerId, next);
        setView((v) => panBy(v, next.x - prev.x, next.y - prev.y));
      }
      e.preventDefault();
    };
    const up = (e: PointerEvent) => {
      pts.delete(e.pointerId);
      if (pts.size === 0) vp.classList.remove("is-dragging");
    };
    const wheel = (e: WheelEvent) => {
      e.preventDefault();
      if (e.ctrlKey || e.metaKey) {
        const p = local(e);
        setView((v) => zoomAt(v, wheelZoomFactor(e.deltaY, e.deltaMode), p.x, p.y));
      } else {
        setView((v) => panBy(v, -wheelPixels(e.deltaX, e.deltaMode), -wheelPixels(e.deltaY, e.deltaMode)));
      }
    };
    // Safari (macOS trackpad) pinch = gesture events, no ctrl+wheel. iOS fires
    // them alongside the two-pointer pinch, so they only zoom with < 2 pointers.
    let gestureStart = 1;
    let gestureScale = 1;
    const gStart = (e: Event) => {
      e.preventDefault();
      gestureStart = (e as unknown as { scale?: number }).scale ?? 1;
      gestureScale = gestureStart;
    };
    const gChange = (e: Event) => {
      e.preventDefault();
      if (pts.size >= 2) return;
      const ge = e as unknown as { scale?: number; clientX?: number; clientY?: number };
      const s = ge.scale ?? 1;
      const factor = s / gestureScale;
      gestureScale = s;
      const { w, h } = boxRef.current;
      const p = ge.clientX !== undefined ? local({ clientX: ge.clientX, clientY: ge.clientY ?? 0 }) : { x: w / 2, y: h / 2 };
      setView((v) => zoomAt(v, factor, p.x, p.y));
    };
    // Keep Radix's "pointer down outside the sheet" (which closes it) away.
    const shield = (e: Event) => e.stopPropagation();
    // The toolbar area must not scroll/zoom the page either.
    const swallowWheel = (e: WheelEvent) => e.preventDefault();

    vp.addEventListener("pointerdown", down);
    vp.addEventListener("pointermove", move);
    vp.addEventListener("pointerup", up);
    vp.addEventListener("pointercancel", up);
    vp.addEventListener("wheel", wheel, { passive: false });
    vp.addEventListener("gesturestart", gStart);
    vp.addEventListener("gesturechange", gChange);
    root.addEventListener("pointerdown", shield);
    root.addEventListener("mousedown", shield);
    root.addEventListener("touchstart", shield, { passive: true });
    root.addEventListener("wheel", swallowWheel, { passive: false });
    return () => {
      vp.removeEventListener("pointerdown", down);
      vp.removeEventListener("pointermove", move);
      vp.removeEventListener("pointerup", up);
      vp.removeEventListener("pointercancel", up);
      vp.removeEventListener("wheel", wheel);
      vp.removeEventListener("gesturestart", gStart);
      vp.removeEventListener("gesturechange", gChange);
      root.removeEventListener("pointerdown", shield);
      root.removeEventListener("mousedown", shield);
      root.removeEventListener("touchstart", shield);
      root.removeEventListener("wheel", swallowWheel);
    };
  }, []);

  const pct = Math.round(view.scale * 100);
  return createPortal(
    <div ref={rootRef} className="mmz" role="dialog" aria-modal="true" aria-label="Diagram viewer">
      <div ref={viewportRef} className="mmz-viewport">
        {/* Same scrubbed SVG as inline (MermaidBlock/scrubSvg). */}
        <div
          className="mmz-canvas"
          data-scale={view.scale}
          data-x={view.x}
          data-y={view.y}
          style={{
            width: `${natural.w * view.scale}px`,
            height: `${natural.h * view.scale}px`,
            transform: `translate(${view.x}px, ${view.y}px)`,
          }}
          dangerouslySetInnerHTML={{ __html: svg }}
        />
      </div>
      <div className="mmz-toolbar">
        <button type="button" aria-label="Zoom out" onClick={() => zoomCenter(1 / ZOOM_STEP)}>−</button>
        <span className="mmz-pct" aria-live="polite">{pct}%</span>
        <button type="button" aria-label="Zoom in" onClick={() => zoomCenter(ZOOM_STEP)}>+</button>
        <button type="button" aria-label="Fit to screen" onClick={fit}>fit</button>
        <button type="button" aria-label="Close diagram" ref={closeRef} onClick={() => onCloseRef.current()}>×</button>
      </div>
    </div>,
    document.body,
  );
}
