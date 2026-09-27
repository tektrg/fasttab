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

describe("phone PWA — iOS-specific CSS", () => {
  test("the phone header gets a safe-area-inset-top allowance", () => {
    const rule = /\.phone-app\s+header\s*\{[^}]*env\(safe-area-inset-top\)[^}]*\}/;
    expect(css).toMatch(rule);
  });

  test("the phone sheet's composer input is at least 16px (no iOS auto-zoom)", () => {
    const rule = /\.phone-sheet-footer\s+input\s*\{[^}]*font-size:\s*16px[^}]*\}/;
    expect(css).toMatch(rule);
  });
});
