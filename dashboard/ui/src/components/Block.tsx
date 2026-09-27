import React from "react";
import { Paper } from "@mantine/core";

/** Shared chrome for a content block (latest message / plan / form /
 *  review card): a bordered, shadowed `Paper` on desktop (unchanged look),
 *  or — when `phone` is set — a plain edge-to-edge block with minimal
 *  horizontal padding and a thin top divider instead of a boxed card, to
 *  maximize width on a 375px screen. Same DOM class names either way, so
 *  existing tests that query by class (e.g. `.form-card`) keep working. */
export function Block({
  phone,
  className,
  children,
}: {
  phone?: boolean;
  className?: string;
  children: React.ReactNode;
}): React.ReactElement {
  if (phone) {
    return <div className={["phone-block", className].filter(Boolean).join(" ")}>{children}</div>;
  }
  return (
    <Paper withBorder radius="xl" shadow="sm" p="sm" className={className}>
      {children}
    </Paper>
  );
}
