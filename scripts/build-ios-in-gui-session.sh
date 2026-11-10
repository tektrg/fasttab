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
tmux has-session 2>/dev/null || { echo "build-ios-in-gui-session: no tmux server in the GUI session; open a terminal on the Pro once" >&2; exit 1; }
# A live session means another iPhone build is still running: never kill it mid-install.
tmux has-session -t fasttab-ios-push 2>/dev/null && { echo "build-ios-in-gui-session: another iPhone build is running (tmux session fasttab-ios-push); wait for it" >&2; exit 1; }
rm -f "${log}.exit"; : > "${log}"   # no stale lines from an earlier run
args=""; (( $# )) && args="$(printf ' %q' "$@")"
tmux new-session -d -s fasttab-ios-push \
  "cd '${repo_root}' && scripts/build-ios.sh${args} > '${log}' 2>&1; echo \$? > '${log}.exit'"
# Poll instead of `tmux wait-for`: a session killed before it signals would hang forever.
deadline=$(( SECONDS + 45 * 60 ))
while [[ ! -s "${log}.exit" ]] && tmux has-session -t fasttab-ios-push 2>/dev/null && (( SECONDS < deadline )); do
  sleep 3
done
if [[ ! -s "${log}.exit" ]] && tmux has-session -t fasttab-ios-push 2>/dev/null; then
  echo "build-ios-in-gui-session: TIMED OUT after 45 min; the build is still running in tmux session fasttab-ios-push (kill it to retry). Log: ${log}" >&2
  exit 1
fi
tail -5 "${log}"
code="$(cat "${log}.exit" 2>/dev/null || true)"
if [[ "${code}" != 0 ]]; then
  echo "build-ios-in-gui-session: iPhone install FAILED (exit ${code:-unknown}); full log: ${log}" >&2
  exit 1
fi
echo "==> iPhone install OK ($(git -C "${repo_root}" log --oneline -1))"
