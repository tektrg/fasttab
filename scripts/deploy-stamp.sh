#!/usr/bin/env bash
# Deploy stamp: which commit a Mac app bundle in dist/ was built from.
# Lives NEXT to the bundle (dist/<App>.app.commit), not inside it, so the signature is untouched.
# Format, one line: "<full sha> <branch>[ dirty]"
#
# Why: a branch build deployed to the Pro was silently replaced by a later main build that
# lacked the fix (2026-11-10, AgentBar recap wrap). The deploy scripts read the target's stamp
# and refuse to replace code the incoming build doesn't contain.
#
#   scripts/deploy-stamp.sh write <App>                 stamp dist/<App>.app with this checkout's HEAD
#   scripts/deploy-stamp.sh verdict "<stamp line>" <sha>
#       ok      (exit 0)  stamp's commit is an ancestor of <sha> (or the same)
#       warn    (exit 0)  no / unreadable stamp: first deploy after the guard, let it through
#       refuse  (exit 3)  the running app has code <sha> doesn't contain; prints why
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

case "${1:-}" in
  write)
    app="${2:?usage: deploy-stamp.sh write <App>}"
    # Dirty = uncommitted (incl. new untracked) edits to what the Mac apps are built from.
    # iOS-only edits don't count: the Pro's checkout often carries those.
    dirty=""; [[ -n "$(git status --porcelain -- Sources Package.swift Package.resolved)" ]] && dirty=" dirty"
    echo "$(git rev-parse HEAD) $(git rev-parse --abbrev-ref HEAD)${dirty}" > "dist/${app}.app.commit"
    echo "==> stamped dist/${app}.app.commit: $(cat "dist/${app}.app.commit")"
    ;;
  verdict)
    line="${2-}"; target="${3:?usage: deploy-stamp.sh verdict <stamp line> <sha>}"
    sha="$(echo "${line}" | awk '{print $1}')"
    branch="$(echo "${line}" | awk '{print $2}')"
    dirty="$(echo "${line}" | awk '{print $3}')"
    if [[ ! "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
      echo "warn: no deploy stamp on the target (first deploy since the guard) — replacing it"
      exit 0
    fi
    if ! git cat-file -e "${sha}^{commit}" 2>/dev/null; then
      echo "refuse: the running app was built from ${sha:0:7} (${branch:-unknown branch}), a commit this checkout doesn't have — \`git fetch pro\`/merge it first, or override with FORCE_REPLACE=<App>"
      exit 3
    fi
    if [[ "${dirty}" == dirty ]]; then
      echo "refuse: the running app was built from UNCOMMITTED edits on '${branch}' (${sha:0:7}) — commit + merge them first, or override with FORCE_REPLACE=<App>"
      exit 3
    fi
    if git merge-base --is-ancestor "${sha}" "${target}"; then
      echo "ok: running ${sha:0:7} (${branch}) is contained in ${target:0:7}"
      exit 0
    fi
    echo "refuse: the running app was built from ${sha:0:7} on '${branch}', which ${target:0:7} doesn't contain — merge '${branch}' into main first, or override with FORCE_REPLACE=<App>"
    exit 3
    ;;
  *) echo "usage: deploy-stamp.sh write <App> | verdict <stamp line> <sha>" >&2; exit 2 ;;
esac
