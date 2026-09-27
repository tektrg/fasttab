import { useMediaQuery } from "@mantine/hooks";

/** Below this, the desktop board (table/kanban/bulk bar/column menus/view
 *  switcher) stops being usable by touch — the phone layout takes over
 *  instead of shrinking the same chrome. ~640px covers every iPhone in
 *  portrait (the widest, Pro Max, is 430pt) with headroom for a small
 *  Android phone in landscape, while leaving iPad (768pt+) on desktop. */
const PHONE_BREAKPOINT = "(max-width: 640px)";

/** True on a phone-width viewport. SSR-safe default (false) doesn't apply
 *  here (no SSR in this app), but useMediaQuery still needs one. */
export function usePhoneLayout(): boolean {
  return useMediaQuery(PHONE_BREAKPOINT, false, { getInitialValueInEffect: false });
}
