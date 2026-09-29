/**
 * QA pass 2 (phase 2, phone PWA) — two iOS-specific CSS rules that have no
 * meaningful DOM-level assertion in happy-dom (it doesn't evaluate
 * `env(safe-area-inset-*)` or apply auto-zoom heuristics), so this pins
 * the source rules directly against regression:
 *
 *  1. Standalone-mode status bar overlap: apple-mobile-web-app-status-bar-
 *     style is "black-translucent" (index.html), which draws the installed
 *     icon's content edge-to-edge under the status bar. The phone header
 *     is `position: sticky; top: 0` with no inset, so without a safe-area
 *     top padding the clock/title render behind the status bar in
 *     standalone mode (Safari tabs are unaffected — the env() is a no-op
 *     there).
 *  2. iOS Safari auto-zooms the page on focus of any text input under
 *     16px. Mantine's default TextInput (Composer, mounted in the phone
 *     sheet's footer) is 14px.
 */
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const css = readFileSync(join(import.meta.dir, "../index.css"), "utf8");
const sheetCss = readFileSync(join(import.meta.dir, "../ui/Sheet.css"), "utf8");
const phoneCss = readFileSync(join(import.meta.dir, "../components/phone/phone.css"), "utf8");
const html = readFileSync(join(import.meta.dir, "../../index.html"), "utf8");

describe("phone PWA — iOS-specific CSS", () => {
  test("the phone header gets a safe-area-inset-top allowance", () => {
    const rule = /\.phone-app\s+header\s*\{[^}]*env\(safe-area-inset-top(,[^)]*)?\)[^}]*\}/;
    expect(phoneCss).toMatch(rule);
  });

  test("the phone sheet's composer input is at least 16px (no iOS auto-zoom)", () => {
    const rule = /\.ui-sheet__footer\s+input\s*\{[^}]*font-size:\s*16px[^}]*\}/;
    expect(phoneCss).toMatch(rule);
  });

  // The sheet (src/ui/Sheet.css) is portalled to the document root — it does
  // NOT inherit .phone-app's insets, so it pads every edge itself; the tab
  // bar (fixed to the bottom) owns the home-indicator inset.
  test("the sheet footer respects the bottom safe-area inset", () => {
    expect(sheetCss).toMatch(/\.ui-sheet__footer\s*\{[^}]*env\(safe-area-inset-bottom/);
  });

  test("the sheet respects left/right safe-area insets", () => {
    expect(sheetCss).toMatch(/\.ui-sheet\s*\{[^}]*env\(safe-area-inset-left/);
    expect(sheetCss).toMatch(/\.ui-sheet\s*\{[^}]*env\(safe-area-inset-right/);
  });

  test("the tab bar respects the bottom safe-area inset and sets the toast offset", () => {
    expect(phoneCss).toMatch(/\.phone-tabbar\s*\{[^}]*env\(safe-area-inset-bottom/);
    expect(phoneCss).toMatch(/--ui-tabbar-height:\s*\d+px/);
  });

  // Broad fix: every input/textarea/select at phone width is >=16px, not
  // just the composer — including Mantine's own input classes, and NOT
  // scoped to .phone-app/.phone-sheet-*, because the phone sheet Modal is
  // portalled to the document root and sits outside .phone-app.
  test("every input/textarea/select is >=16px at phone width (no iOS auto-zoom anywhere)", () => {
    // 640px, not 480px: must match usePhoneLayout's own breakpoint, since
    // that's what actually mounts the phone sheet Modal these inputs live in.
    const media = css.match(/@media \(max-width:\s*640px\)\s*\{([\s\S]*?)\n\}/);
    expect(media).not.toBeNull();
    const block = media![1];
    expect(block).toMatch(/font-size:\s*16px\s*!important/);
    for (const sel of ["input", "textarea", "select"]) {
      expect(block).toMatch(new RegExp(`(^|,|\\s)${sel}(,|\\s|\\{)`));
    }
    for (const cls of [
      "mantine-TextInput-input",
      "mantine-Textarea-input",
      "mantine-Autocomplete-input",
      "mantine-Select-input",
    ]) {
      expect(block).toContain(`.${cls}`);
    }
  });

  test("index.html sets maximum-scale=1 without disabling pinch-zoom", () => {
    const viewport = html.match(/<meta name="viewport" content="([^"]*)"/);
    expect(viewport).not.toBeNull();
    expect(viewport![1]).toMatch(/maximum-scale=1(\.0)?/);
    expect(viewport![1]).not.toMatch(/user-scalable=no/);
  });
});
