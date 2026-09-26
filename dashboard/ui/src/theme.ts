import { createTheme } from "@mantine/core";

// Design system: "clinical blueprint on frosted paper" (shadcn/ui-style,
// monochromatic + one red accent), light by default with a dark inversion
// that follows the OS setting (MantineProvider defaultColorScheme="auto" in
// main.tsx). See src/index.css :root / [data-mantine-color-scheme='dark']
// for the full token set this mirrors into Mantine's component defaults.
//
// Typography: Avenir everywhere — chrome AND data (no monospace split).
//
// `ink`: a 10-slot custom color standing in for Mantine's built-in palettes,
// used ONLY as primaryColor (never referenced by name elsewhere) — so unlike
// a real color scale it does not need to read as a smooth gradient. Each
// slot is set to whatever Mantine's own CSS variable generator (see
// get-css-color-variables.mjs) actually looks up at that index for a given
// variant + scheme, using Mantine's OWN default primaryShade below:
//   [9] "dark"  → light-scheme SUBTLE-variant text (must read on white)
//   [6] "black" → light-scheme FILLED bg   (the spec's black button)
//   [7]         → light-scheme FILLED hover
//   [0] "light" → dark-scheme  SUBTLE-variant text (must read on near-black)
//   [8] "white" → dark-scheme  FILLED bg   (the inverted, near-white button)
//   [9] again   → dark-scheme  FILLED hover (Mantine reuses the same index
//     it uses for light-scheme subtle text — the one un-avoidable seam: a
//     default-filled ink button's HOVER state in dark mode is near-black,
//     same as its rest-state text, so hovering one (Save/Confirm/Rename)
//     goes momentarily low-contrast. Everything at rest is correct; only
//     that hover flash is a known, accepted gap.)
//
// CRITICAL: primaryShade below must stay at Mantine's own default
// ({light:6, dark:8}), NOT a custom override — primaryShade only ever
// affects `primaryColor` ("ink") here; every other named color (green,
// blue, red, …) ships as static precompiled CSS in @mantine/core/styles.css,
// baked at Mantine's OWN default shade and completely untouched by this
// file. A prior version of this file set primaryShade to {light:9,dark:0}
// on the (wrong) theory that it also governed those named colors — reverted
// because it doesn't; it only ever affected ink.
//
// The real cause of the 2026-09-06/07 unreadable "+ New view" button:
// ViewSwitcher.tsx passed `variant="dashed"` to a Mantine <Button>, which is
// not a valid ButtonVariant ('filled'|'light'|'outline'|'transparent'|
// 'white'|'subtle'|'default'|'gradient' — no "dashed"). An unrecognized
// variant makes defaultVariantColorsResolver return {}, so the button gets
// no --button-bg/--button-color at all and falls back to the CSS defaults:
// bg = var(--mantine-primary-color-filled) (our ink-filled — near-white in
// dark scheme) and text = the literal var(--mantine-color-white) (always
// white). Fixed by using a real variant ("outline") in ViewSwitcher.tsx.
// Verified via a real @mantine/core render in happy-dom (not a static-bundle
// grep, which can't see this — see the theme.ts git history for the test).
export const theme = createTheme({
  fontFamily:
    "Avenir, 'Avenir Next', -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, Helvetica, Arial, sans-serif",
  fontFamilyMonospace:
    "Avenir, 'Avenir Next', -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, Helvetica, Arial, sans-serif",
  primaryColor: "ink",
  primaryShade: { light: 6, dark: 8 },
  autoContrast: true,
  black: "#0a0a0a",
  colors: {
    ink: [
      "#fafafa",
      "#f5f5f5",
      "#e5e5e5",
      "#d4d4d4",
      "#a3a3a3",
      "#737373",
      "#0a0a0a",
      "#262626",
      "#fafafa",
      "#0a0a0a",
    ],
  },
  // Named radii from the spec: small 6 · nested 10 · buttons/inputs/badges 18
  // · cards 24. `defaultRadius` covers buttons/inputs/menus; Card/Paper
  // surfaces opt into radius="xl" (24) explicitly where used.
  radius: { xs: "6px", sm: "10px", md: "14px", lg: "18px", xl: "24px" },
  defaultRadius: "lg",
  shadows: {
    sm: "0 0 0 1px rgba(23,23,23,0.05), 0 1px 3px rgba(0,0,0,0.1), 0 1px 2px -1px rgba(0,0,0,0.1)",
  },
});
