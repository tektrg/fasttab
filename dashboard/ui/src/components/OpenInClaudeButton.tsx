import { Button } from "@mantine/core";
import type { AgentRow } from "../types";
import { openInClaudeLink } from "../openInClaude";

/** "Open in Claude" for a Claude Desktop row (see `openInClaudeLink`);
 *  renders nothing for any other row. */
export function OpenInClaudeButton({
  row,
  size = "compact-sm",
  userAgent = typeof navigator === "undefined" ? "" : navigator.userAgent,
}: {
  row: Pick<AgentRow, "openUrl"> | null | undefined;
  size?: string;
  userAgent?: string;
}) {
  const link = openInClaudeLink(row, userAgent);
  if (!link) return null;
  const external = link.href.startsWith("https://");
  return (
    <Button
      component="a"
      href={link.href}
      target={external ? "_blank" : undefined}
      rel={external ? "noopener noreferrer" : undefined}
      variant="light"
      size={size}
      title={link.title}
    >
      {link.label}
    </Button>
  );
}
