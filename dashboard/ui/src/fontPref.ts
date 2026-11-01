// Font preference (Settings tab): Avenir Next (default) or the system font.
// Stored per browser; index.css switches --sans on <html data-font="system">.
export type FontPref = "avenir" | "system";
const KEY = "agentbar.font";

export function getFontPref(): FontPref {
  try {
    return localStorage.getItem(KEY) === "system" ? "system" : "avenir";
  } catch {
    return "avenir";
  }
}

export function applyFontPref(pref: FontPref = getFontPref()): void {
  document.documentElement.dataset.font = pref;
}

export function setFontPref(pref: FontPref): void {
  try {
    localStorage.setItem(KEY, pref);
  } catch {
    /* private mode: applies for this page load only */
  }
  applyFontPref(pref);
}

// Text size: page zoom (every size in index.css is px, so zoom scales all of it).
const SCALE_KEY = "agentbar.fontScale";
export const FONT_SCALES = [0.85, 0.9, 1, 1.1, 1.2, 1.3] as const;

export function getFontScale(): number {
  try {
    const v = Number(localStorage.getItem(SCALE_KEY));
    return v >= 0.8 && v <= 1.4 ? v : 1;
  } catch {
    return 1;
  }
}

export function applyFontScale(scale: number = getFontScale()): void {
  document.documentElement.style.setProperty("zoom", scale === 1 ? "" : String(scale));
}

export function setFontScale(scale: number): void {
  try {
    localStorage.setItem(SCALE_KEY, String(scale));
  } catch {
    /* applies for this page load only */
  }
  applyFontScale(scale);
}
