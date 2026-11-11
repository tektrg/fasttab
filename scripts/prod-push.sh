#!/usr/bin/env bash
# Runs on the AIR (dev machine). Builds the Mac apps here, ships the finished
# bundles into the Pro's dist/, and restarts them there.
# IOS=1 additionally pushes the source to the Pro and installs the iPhone build
# from there (Xcode exists only on the Pro).
#
# Env: MAC_PRO_SSH (mbp-m4)  MAC_PRO_REPO  APPS ("FastTab AgentBar")  IOS (0)  DRY_RUN (0)
#      IOS_DEVICE — iPhone to install on (default: the owner's iPhone 16e). Explicit, so a second
#      paired phone never makes the target ambiguous; IOS_DEVICE=auto lets build-ios.sh pick
#      (and refuse when more than one phone is paired).
#      SKIP_MAIN_SYNC (0) — deploy a non-main checkout without syncing (loud; for branch testing)
#      IOS_DIRTY_OK ("marketing") — space-separated Pro paths whose uncommitted edits never block
#      the iPhone step (App Store media other sessions work on; not part of the iOS build)
#      ALLOW_STALE_INDIELIBKIT (0) — build even if an IndieLibKit checkout is off main / behind
#
# Preflight (owner decision 2026-11-11): every check that can fail runs BEFORE any app is
# stopped or replaced — all steps run, or the script refuses up front and nothing changes.
#  - IndieLibKit (sibling ../IndieLibKit, used by both builds): the Air's (Mac apps) and the
#    Pro's (IOS=1) must be on main and contain GitHub's main. REFUSE, not warn: a stale branch
#    broke the 2026-11-10 deploy, and a warning scrolls past in a long build log.
#  - IOS=1: Pro reachable, no uncommitted edits outside IOS_DIRTY_OK, tmux GUI session up,
#    no other iPhone build running, the phone paired and reachable.
#
# Guards (user-approved 2026-10-02):
#  1. Main sync first: this checkout must be on a clean `main`; the Pro's `main` is merged in
#     here, then fast-forwarded on the Pro. Anything that can't merge cleanly (conflict here,
#     or the Pro's uncommitted edits in the way) stops BEFORE any build or app restart.
#  3. Never older code (owner decision 2026-11-10): each bundle has a stamp (dist/<App>.app.commit,
#     scripts/deploy-stamp.sh). An app whose Pro stamp is a commit this build doesn't contain —
#     e.g. a branch fix deployed with SKIP_MAIN_SYNC — is skipped with a STOP message; other apps
#     still deploy. Missing stamp: warn and deploy. Override: FORCE_REPLACE="AgentBar" (or "all").
#  2. Signed or nothing: an ad-hoc-signed bundle (signing identity missing from the keychain
#     search list) is refused before it replaces the Pro's copy — ad-hoc loses macOS
#     permissions (Accessibility for the hotkeys).
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

PRO="${MAC_PRO_SSH:-mbp-m4}"
PRO_REPO="${MAC_PRO_REPO:-/Users/trungluong/01_Project/command-bar-macos}"
APPS="${APPS-FastTab AgentBar}"   # APPS= (empty) skips the Mac apps
run() { echo "+ $*"; [[ "${DRY_RUN:-0}" == 1 ]] || "$@"; }
die() { echo "prod-push: STOP — $*" >&2; exit 1; }

pro() { ssh "${PRO}" "$@"; }

# IndieLibKit at <dir> (on host: "local" or "pro") must be on main and contain origin main.
check_indielibkit() {
  local where="$1" dir="$2" want="$3" branch
  if [[ "${where}" == local ]]; then
    branch="$(git -C "${dir}" symbolic-ref --short -q HEAD || echo detached)"
  else
    branch="$(pro "git -C '${dir}' symbolic-ref --short -q HEAD || echo detached")" \
      || die "cannot read the Pro's IndieLibKit (${dir}) — nothing was deployed"
  fi
  local problem=""
  [[ "${branch}" == main ]] || problem="is on '${branch}', not main"
  if [[ -z "${problem}" ]]; then
    if [[ "${where}" == local ]]; then
      git -C "${dir}" merge-base --is-ancestor "${want}" HEAD 2>/dev/null || problem="is behind GitHub main (${want:0:7})"
    else
      pro "git -C '${dir}' merge-base --is-ancestor '${want}' HEAD" 2>/dev/null || problem="is behind GitHub main (${want:0:7}) — pull it there"
    fi
  fi
  if [[ -n "${problem}" ]]; then
    [[ "${ALLOW_STALE_INDIELIBKIT:-0}" == 1 ]] && { echo "!! ALLOW_STALE_INDIELIBKIT: ${where} IndieLibKit ${problem}"; return; }
    die "${where} IndieLibKit (${dir}) ${problem} — the build would use stale shared code; nothing was deployed (override: ALLOW_STALE_INDIELIBKIT=1)"
  fi
  echo "==> ${where} IndieLibKit: main, up to date"
}

preflight() {
  echo "==> preflight (nothing is stopped or replaced until all checks pass)"
  pro true || die "cannot reach the Pro (${PRO}) — nothing was deployed"
  local lib="${repo_root}/../IndieLibKit" pro_lib want
  pro_lib="$(dirname "${PRO_REPO}")/IndieLibKit"
  want="$(git ls-remote "$(git -C "${lib}" remote get-url origin)" refs/heads/main 2>/dev/null | cut -f1)"
  if [[ -z "${want}" ]]; then
    want="$(git -C "${lib}" rev-parse origin/main)"
    echo "!! could not reach GitHub for IndieLibKit main; comparing against last fetched ${want:0:7}"
  fi
  [[ -z "${APPS}" ]] || check_indielibkit local "${lib}" "${want}"
  [[ "${IOS:-0}" == 1 ]] || return 0
  check_indielibkit pro "${pro_lib}" "${want}"
  local excl="" p dirty
  for p in ${IOS_DIRTY_OK-marketing}; do excl+=" ':(exclude)${p}'"; done
  dirty="$(pro "git -C '${PRO_REPO}' status --porcelain --untracked-files=no -- .${excl}")" \
    || die "cannot read the Pro's checkout — nothing was deployed"
  [[ -z "${dirty}" ]] || die "the Pro's checkout has uncommitted edits the iPhone would get (commit or move them there; never discarded):
${dirty}"
  pro "export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH; tmux has-session" 2>/dev/null \
    || die "no tmux server in the Pro's GUI session (open a terminal on the Pro once) — nothing was deployed"
  ! pro "export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH; tmux has-session -t fasttab-ios-push" 2>/dev/null \
    || die "another iPhone build is running on the Pro (tmux session fasttab-ios-push) — nothing was deployed"
  # Streams this checkout's build-ios.sh (the Pro's copy may predate --check-only until synced);
  # run from scripts/ so its repo_root (parent of the script dir) resolves to PRO_REPO.
  pro "cd '${PRO_REPO}/scripts' && bash -s -- --check-only${device_arg}" < scripts/build-ios.sh \
    || die "the iPhone (${device}) isn't reachable from the Pro — unlock it / same Wi-Fi; nothing was deployed"
  echo "==> preflight OK"
}

sync_main_with_pro() {
  if [[ "${SKIP_MAIN_SYNC:-0}" == 1 ]]; then
    echo "!! SKIP_MAIN_SYNC=1: deploying $(git rev-parse --abbrev-ref HEAD) WITHOUT syncing main"
    return
  fi
  [[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] \
    || die "this checkout is on '$(git rev-parse --abbrev-ref HEAD)', not main (use a main worktree, or SKIP_MAIN_SYNC=1 for a branch test)"
  [[ -z "$(git status --porcelain --untracked-files=no)" && -z "$(git status --porcelain -- Sources Package.swift Package.resolved)" ]] \
    || die "uncommitted changes here (incl. new files under Sources/) — commit them first"
  run git fetch pro main
  if ! git merge-base --is-ancestor pro/main HEAD; then
    echo "+ git merge pro/main"
    if [[ "${DRY_RUN:-0}" != 1 ]] && ! git merge --no-edit -m "Merge Pro's main (prod-push sync)" pro/main; then
      git merge --abort || true
      die "Air and Pro main don't merge cleanly — resolve by hand, nothing was deployed"
    fi
  fi
  # Fast-forward the Pro: a side branch, then --ff-only there (fails, leaving the Pro as it was,
  # if its checkout isn't on main or its own uncommitted edits touch incoming files).
  run git push pro "+HEAD:refs/heads/prod-push-sync"   # throwaway: a leftover never blocks
  run ssh "${PRO}" "cd '${PRO_REPO}' && [ \"\$(git rev-parse --abbrev-ref HEAD)\" = main ] && git merge --ff-only prod-push-sync; rc=\$?; git branch -D prod-push-sync >/dev/null; exit \$rc" \
    || die "the Pro's main can't fast-forward (not on main, moved meanwhile, or its uncommitted edits are in the way) — nothing was deployed"
  echo "==> main synced: Air and Pro at $(git rev-parse --short HEAD)"
}

require_signed() {
  local app_path="$1"
  [[ "${DRY_RUN:-0}" == 1 ]] && return
  if codesign -dv "${app_path}" 2>&1 | grep -q "Signature=adhoc"; then
    die "${app_path} is ad-hoc signed (identity not in the keychain search list? see CLAUDE.md 'Air signing') — not deployed"
  fi
}

device="${IOS_DEVICE:-243A482F-26DD-5381-8067-41B9DFD7A8CC}"   # iPhone 16e (two phones are paired)
device_arg=""; [[ "${device}" == auto ]] || device_arg=" --device ${device}"

preflight
sync_main_with_pro

# ssh sessions can't unlock the login keychain (codesign → errSecInternalComponent), so
# signing uses a dedicated keychain holding only the dev identity, unlocked from files
# under ~/.config (keychain password + identity hash). One-time setup: see CLAUDE.md.
sign_dir="${HOME}/.config"
if [[ -f "${sign_dir}/fasttab-signing.kcpw" ]]; then
  echo "+ unlock fasttab-signing keychain"
  [[ "${DRY_RUN:-0}" == 1 ]] || security unlock-keychain -p "$(cat "${sign_dir}/fasttab-signing.kcpw")" \
    "${HOME}/Library/Keychains/fasttab-signing.keychain-db"
  export FASTTAB_SIGN_IDENTITY="${FASTTAB_SIGN_IDENTITY:-$(cat "${sign_dir}/fasttab-signing.identity")}"
fi
# Fail fast, before a long build: the identity must be findable (the build scripts silently
# fall back to ad-hoc otherwise — how 2026-10-01's push went out unsigned).
if [[ -n "${APPS}" && "${DRY_RUN:-0}" != 1 ]]; then
  security find-identity -v -p codesigning | grep -q "${FASTTAB_SIGN_IDENTITY:-SELAV8N2B9}" \
    || die "signing identity ${FASTTAB_SIGN_IDENTITY:-SELAV8N2B9} not in the keychain search list (security list-keychains -d user; see CLAUDE.md 'Air signing')"
fi

# Guard 3: drop any app whose Pro copy runs code this build doesn't contain (before building it).
head_sha="$(git rev-parse HEAD)"
git fetch -q pro 2>/dev/null || true   # so a commit built on the Pro's own branches is known here
refused=""
deploy_apps=""
for app in ${APPS}; do
  # A failed read must not look like "no stamp" (that would wave the app through).
  stamp="$(ssh "${PRO}" "f='${PRO_REPO}/dist/${app}.app.commit'; if [ -f \"\$f\" ]; then cat \"\$f\"; fi")" \
    || die "cannot read ${app}'s deploy stamp on the Pro (${PRO}) — nothing was deployed"
  rc=0; verdict="$(scripts/deploy-stamp.sh verdict "${stamp}" "${head_sha}" "${app}")" || rc=$?
  if (( rc == 3 )) && [[ " ${FORCE_REPLACE:-} " != *" ${app} "* && "${FORCE_REPLACE:-}" != all ]]; then
    echo "prod-push: STOP ${app} — ${verdict}" >&2
    refused+=" ${app}"
    continue
  fi
  (( rc == 0 || rc == 3 )) || die "deploy stamp check failed for ${app}"
  (( rc == 3 )) && echo "!! FORCE_REPLACE: replacing ${app} anyway — ${verdict}" || echo "==> ${app}: ${verdict}"
  deploy_apps+=" ${app}"
done
APPS="${deploy_apps# }"

# iOS: the Pro must build exactly this commit — checked now, before any Mac app is stopped.
if [[ "${IOS:-0}" == 1 ]]; then
  run git push pro "$(git rev-parse --abbrev-ref HEAD)" || die "push to the Pro failed (its checkout dirty?) — nothing was deployed"
  head="$(git rev-parse HEAD)"
  pro_head="$(pro "git -C '${PRO_REPO}' rev-parse HEAD")" || die "cannot reach the Pro (${PRO}) — nothing was deployed"
  [[ "${DRY_RUN:-0}" == 1 || "${pro_head}" == "${head}" ]] \
    || die "the Pro's checkout is at ${pro_head:0:7}, not ${head:0:7} — the iPhone would get other code; nothing was deployed"
fi

for app in ${APPS}; do
  case "${app}" in
    FastTab)  run scripts/fasttab-build-mac-app.sh --no-open ;;
    AgentBar) run scripts/build-agentbar-app.sh --no-open ;;
    *) echo "prod-push: unknown app ${app}" >&2; exit 1 ;;
  esac
done

for app in ${APPS}; do require_signed "dist/${app}.app"; done

for app in ${APPS}; do
  run ssh "${PRO}" "cd '${PRO_REPO}' && scripts/app-lifecycle.sh stop ${app}"
  run rsync -aE --delete "dist/${app}.app/" "${PRO}:${PRO_REPO}/dist/${app}.app/"
  # Stamp via ssh, not rsync (openrsync mangles single-file targets).
  [[ "${DRY_RUN:-0}" == 1 ]] || ssh "${PRO}" "cat > '${PRO_REPO}/dist/${app}.app.commit'" < "dist/${app}.app.commit" \
    || echo "!! could not write ${app}'s deploy stamp on the Pro — next deploy will only warn" >&2
  run ssh "${PRO}" "cd '${PRO_REPO}' && scripts/app-lifecycle.sh start ${app}"
done

if [[ "${IOS:-0}" == 1 ]]; then
  # Via a tmux session on the Pro so Xcode can sign (see build-ios-in-gui-session.sh).
  rc=0; run ssh "${PRO}" "cd '${PRO_REPO}' && scripts/build-ios-in-gui-session.sh${device_arg}" || rc=$?
  (( rc == 255 )) && die "lost the ssh connection to the Pro — the build may still be running; check /tmp/fasttab-ios-push.log there"
  (( rc == 0 )) || die "iPhone install FAILED on ${device} (log on the Pro: /tmp/fasttab-ios-push.log). Mac apps (if any) were already deployed."
fi
[[ -z "${refused}" ]] || die "not replaced (Pro runs code this build lacks):${refused} — see STOP lines above"
echo "==> prod-push done"
