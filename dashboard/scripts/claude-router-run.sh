#!/usr/bin/env bash
# Run claude-router in the foreground (the LaunchAgent calls this; also fine by hand).
# Port: CLAUDE_ROUTER_PORT (default 4720). Config: ~/.config/agent-dashboard/accounts.json.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
exec /usr/bin/python3 "$here/server/claude_router.py"
