import { describe, expect, test } from "bun:test";
import { REVEAL_PX, SLOP_PX, isOpen, swipeEnd, swipeIdle, swipeMove, swipeStart } from "../components/phone/swipeGesture";

const drag = (open: boolean, path: [number, number][]) => {
  let s = swipeStart(swipeIdle(open), 200, 100);
  for (const [x, y] of path) s = swipeMove(s, x, y);
  return s;
};

describe("swipe gesture", () => {
  test("under the slop nothing is decided", () => {
    const s = drag(false, [[200 - (SLOP_PX - 1), 100]]);
    expect(s.phase).toBe("pending");
    expect(swipeEnd(s).swallowClick).toBe(false);
  });
  test("mostly vertical commits to scroll and never moves the row", () => {
    const s = drag(false, [[195, 130], [100, 200]]);
    expect(s.phase).toBe("scroll");
    expect(s.offset).toBe(0);
    expect(swipeEnd(s)).toEqual({ state: swipeIdle(false), swallowClick: false });
  });
  test("horizontal commits to swipe and follows the finger, clamped", () => {
    expect(drag(false, [[150, 102]]).offset).toBe(-50);
    expect(drag(false, [[-100, 102]]).offset).toBe(-REVEAL_PX);
    expect(drag(false, [[300, 102]]).offset).toBe(0);
  });
  test("release past the threshold snaps open and swallows the click", () => {
    const end = swipeEnd(drag(false, [[100, 101]]));
    expect(end.swallowClick).toBe(true);
    expect(end.state.offset).toBe(-REVEAL_PX);
    expect(isOpen(end.state)).toBe(true);
  });
  test("short drag snaps back closed", () => {
    const end = swipeEnd(drag(false, [[170, 101]]));
    expect(end.state.offset).toBe(0);
    expect(isOpen(end.state)).toBe(false);
  });
  test("from open, dragging right past the threshold closes", () => {
    const end = swipeEnd(drag(true, [[330, 100]]));
    expect(end.state.offset).toBe(0);
  });
  test("a tap or scroll while open keeps it open", () => {
    expect(swipeEnd(swipeStart(swipeIdle(true), 5, 5)).state.offset).toBe(-REVEAL_PX);
    expect(swipeEnd(drag(true, [[200, 160]])).state.offset).toBe(-REVEAL_PX);
  });
  test("moves after a scroll commit are ignored", () => {
    let s = drag(false, [[200, 140]]);
    s = swipeMove(s, 0, 140);
    expect(s.offset).toBe(0);
  });
});
