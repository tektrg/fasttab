#!/usr/bin/env bash
# Runs scripts/build-ios.sh inside a tmux session and waits for it, returning its exit code.
# Why: over a bare ssh session Xcode can't reach the login keychain (CodeSign fails with
# errSecInternalComponent). A tmux server started from the GUI login session can, so new
# sessions on it inherit keychain access. Requires that tmux server to already be running.
#
# Usage: scripts/build-ios-in-gui-session.sh [build-ios.sh args]
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH}"
log="/tmp/fasttab-ios-push.log"
rm -f "${log}.exit"
tmux has-session 2>/dev/null || { echo "build-ios-in-gui-session: no tmux server in the GUI session; open a terminal on the Pro once" >&2; exit 1; }
tmux kill-session -t fasttab-ios-push 2>/dev/null || true
tmux new-session -d -s fasttab-ios-push \
  "cd '${repo_root}' && scripts/build-ios.sh $* > '${log}' 2>&1; echo \$? > '${log}.exit'; tmux wait-for -S fasttab-ios-push-done"
tmux wait-for fasttab-ios-push-done
tail -5 "${log}"
exit "$(cat "${log}.exit")"
