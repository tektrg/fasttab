import type { ButtonHTMLAttributes } from "react";
import "./ActionButton.css";

export type ActionVariant = "primary" | "secondary" | "danger" | "ask";
export type ActionSize = "md" | "sm";

interface Props extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ActionVariant;
  /** md = 44 tall; sm = 36 tall drawn inside a 44 hit area. */
  size?: ActionSize;
}

export function ActionButton({ variant = "secondary", size = "md", className, type = "button", ...rest }: Props) {
  return (
    <button
      type={type}
      className={["ui-btn", className].filter(Boolean).join(" ")}
      data-variant={variant}
      data-size={size}
      {...rest}
    />
  );
}
