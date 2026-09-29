import { createTheme, type CSSVariablesResolver } from "@mantine/core";

// Mantine side of the AgentBar Remote design system. src/index.css owns the
// tokens (:root + [data-mantine-color-scheme='dark']); this file only maps
// Mantine onto them. Light by default, dark follows the OS
// (MantineProvider defaultColorScheme="auto" in main.tsx).
//
// Fonts/radii are CSS var() references, so Mantine components follow the
// tokens directly. Theme COLORS cannot be var(): Mantine computes contrast
// and tints from them in JS, so `ink` holds literal hex copies of the token
// values (comments name the token each slot mirrors).
//
// `ink`: a 10-slot custom color used ONLY as primaryColor — not a smooth
// ramp. Each slot is whatever Mantine's CSS variable generator
// (get-css-color-variables.mjs) looks up at that index for a variant +
// scheme, with Mantine's OWN default primaryShade {light:6, dark:8}:
//   [9] light-scheme LIGHT/SUBTLE text (must read on white)
//   [6] light-scheme FILLED bg · [7] light-scheme FILLED hover
//   [0] dark-scheme LIGHT/SUBTLE text (must read on near-black)
//   [4] dark-scheme text + OUTLINE colour
//   [8] dark-scheme FILLED bg (the inverted, near-white button)
//   [9] dark-scheme FILLED hover — the same slot as light-scheme text, so it
//       is near-black; that made hovering a filled ink button in dark mode
//       (Save/Confirm/Rename) go low-contrast. cssVariablesResolver below
//       overrides that one variable to --ink-2 (a lighter step), fixing it.
//
// CRITICAL: keep primaryShade at Mantine's default. It only affects
// `primaryColor` ("ink"); every other named color (green, blue, red, …)
// ships as static precompiled CSS in @mantine/core/styles.css.
//
// Historical: the 2026-09-06/07 unreadable "+ New view" button was an
// invalid `variant="dashed"` in ViewSwitcher.tsx (no --button-bg/-color at
// all), not a theme problem — fixed by using variant="outline".
export const theme = createTheme({
  fontFamily: "var(--sans)",
  fontFamilyMonospace: "var(--mono)",
  headings: { fontFamily: "var(--sans)" },
  primaryColor: "ink",
  primaryShade: { light: 6, dark: 8 },
  autoContrast: true,
  black: "#0d0f14", // --ink (light)
  colors: {
    ink: [
      "#f1f3f7", // [0] --ink (dark)
      "#eceef2", // [1] --sunken (light)
      "#e2e4e9", // [2] --hair (light)
      "#9aa0ad", // [3] --ink-4 (light)
      "#c3c8d2", // [4] --ink-2 (dark)
      "#6b7180", // [5] --ink-3 (light)
      "#0d0f14", // [6] --ink (light)
      "#3a3f4b", // [7] --ink-2 (light)
      "#f1f3f7", // [8] --ink (dark)
      "#0d0f14", // [9] --ink (light)
    ],
  },
  // Token radii: sm 6 · md 12 (buttons/inputs, the default) · lg 20
  // (cards; Paper surfaces pass radius="xl").
  radius: {
    xs: "var(--r-sm)",
    sm: "var(--r-sm)",
    md: "var(--r-md)",
    lg: "var(--r-lg)",
    xl: "var(--r-lg)",
  },
  defaultRadius: "md",
  shadows: { sm: "var(--shadow-float)" },
});

// Mantine's surface/text/border variables, pointed at the tokens. The same
// map serves both schemes because the tokens themselves switch with the
// scheme; Mantine emits its own defaults per scheme, so both are overridden.
const tokenSurfaces = {
  "--mantine-color-body": "var(--paper)",
  "--mantine-color-text": "var(--ink)",
  "--mantine-color-dimmed": "var(--ink-3)",
  "--mantine-color-placeholder": "var(--ink-4)",
  "--mantine-color-error": "var(--need)",
  "--mantine-color-default": "var(--paper)",
  "--mantine-color-default-hover": "var(--sunken)",
  "--mantine-color-default-color": "var(--ink)",
  "--mantine-color-default-border": "var(--hair)",
};

export const cssVariablesResolver: CSSVariablesResolver = () => ({
  variables: {},
  light: tokenSurfaces,
  dark: { ...tokenSurfaces, "--mantine-color-ink-filled-hover": "var(--ink-2)" },
});
