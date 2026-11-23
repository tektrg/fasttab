/**
 * Pure pan/zoom math for the fullscreen diagram viewer (MermaidZoomOverlay).
 * A `View` places the diagram inside the viewer: the SVG is drawn at
 * `natural size × scale` (real width/height, so it stays vector-sharp — never
 * a CSS-scaled bitmap) with its top-left corner at (x, y) in viewer pixels.
 */

export const MIN_SCALE = 0.25;
export const MAX_SCALE = 8;
/** One +/− button press or key press. */
export const ZOOM_STEP = 1.25;
/** Empty margin around a "fit" diagram, px. */
const FIT_PAD = 24;

export type View = { scale: number; x: number; y: number };
export type Size = { w: number; h: number };

export function clampScale(s: number): number {
  if (!Number.isFinite(s)) return 1;
  return Math.min(MAX_SCALE, Math.max(MIN_SCALE, s));
}

/** Whole diagram visible and centered (scale still within the bounds). */
export function fitView(content: Size, box: Size): View {
  const availW = Math.max(1, box.w - FIT_PAD * 2);
  const availH = Math.max(1, box.h - FIT_PAD * 2);
  const scale = clampScale(Math.min(availW / content.w, availH / content.h));
  return { scale, x: (box.w - content.w * scale) / 2, y: (box.h - content.h * scale) / 2 };
}

/** Zoom by `factor`, keeping the diagram point under (px, py) where it is. */
export function zoomAt(v: View, factor: number, px: number, py: number): View {
  const scale = clampScale(v.scale * factor);
  const k = scale / v.scale;
  return { scale, x: px - (px - v.x) * k, y: py - (py - v.y) * k };
}

export function panBy(v: View, dx: number, dy: number): View {
  return { scale: v.scale, x: v.x + dx, y: v.y + dy };
}

/** Wheel delta in pixels (line/page modes converted). */
export function wheelPixels(delta: number, deltaMode: number): number {
  if (deltaMode === 1) return delta * 16;
  if (deltaMode === 2) return delta * 400;
  return delta;
}

/** Zoom factor for a ctrl/cmd+wheel or trackpad-pinch event. */
export function wheelZoomFactor(deltaY: number, deltaMode: number): number {
  const px = Math.max(-100, Math.min(100, wheelPixels(deltaY, deltaMode)));
  return Math.exp(-px * 0.01);
}

/** The diagram's natural size, from the SVG's viewBox (else width/height
 *  attributes, else a default). */
export function svgSize(svg: string): Size {
  const open = /<svg\b[^>]*>/i.exec(svg)?.[0] ?? "";
  const vb = /\bviewBox\s*=\s*["']\s*([-\d.eE]+)[\s,]+([-\d.eE]+)[\s,]+([\d.eE]+)[\s,]+([\d.eE]+)/.exec(open);
  if (vb) {
    const w = Number(vb[3]);
    const h = Number(vb[4]);
    if (w > 0 && h > 0) return { w, h };
  }
  const w = Number(/\bwidth\s*=\s*["']([\d.]+)(px)?["']/.exec(open)?.[1]);
  const h = Number(/\bheight\s*=\s*["']([\d.]+)(px)?["']/.exec(open)?.[1]);
  if (w > 0 && h > 0) return { w, h };
  return { w: 800, h: 600 };
}
