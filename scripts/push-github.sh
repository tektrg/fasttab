#!/usr/bin/env bash
# Push to GitHub (tektrg/fasttab) as the `tektrg` gh account without changing
# the machine's active gh account (which stays the AptusFit one).
# Usage: scripts/push-github.sh [git push args...]   (default: origin main)
set -euo pipefail
[ $# -eq 0 ] && set -- origin main

GH_USER="${GH_PUSH_USER:-tektrg}"
TOKEN="$(gh auth token -u "$GH_USER")" || {
  echo "No saved gh login for '$GH_USER' — run: gh auth login (as $GH_USER)" >&2
  exit 1
}
export GH_PUSH_TOKEN="$TOKEN"

# The token is only handed to this one git process via a credential helper.
git -c credential.helper= \
    -c "credential.helper=!f(){ echo username=$GH_USER; echo \"password=\$GH_PUSH_TOKEN\"; }; f" \
    push "$@"
