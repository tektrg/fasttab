import type { AnchorHTMLAttributes, ButtonHTMLAttributes, ReactNode } from "react";
import "./IconButton.css";

type Common = { children: ReactNode; "aria-label": string };

/** 44x44 icon-only control (header actions). Renders a link when `href` is
 *  given, a button otherwise; the accessible name is required. */
export function IconButton(
  props: (Common & ButtonHTMLAttributes<HTMLButtonElement> & { href?: undefined }) | (Common & AnchorHTMLAttributes<HTMLAnchorElement> & { href: string }),
) {
  const { className, ...rest } = props;
  const cls = ["ui-icon-btn", className].filter(Boolean).join(" ");
  if (rest.href !== undefined) return <a className={cls} {...(rest as AnchorHTMLAttributes<HTMLAnchorElement>)} />;
  return <button type="button" className={cls} {...(rest as ButtonHTMLAttributes<HTMLButtonElement>)} />;
}
