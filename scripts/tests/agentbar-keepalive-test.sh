#!/usr/bin/env bash
# Tests for the AgentBar keep-alive decision (scripts/agentbar-keepalive.sh) and app-lifecycle.sh's
# deploy marker. Local only: stub `pgrep`/`open`/`pkill` on PATH, temp dirs; never touches a real app.
# Usage: scripts/tests/agentbar-keepalive-test.sh   (PASS/FAIL per case, exit 1 on any FAIL)
set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ka="${repo_root}/scripts/agentbar-keepalive.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/keepalive-test.XXXXXX")"
trap 'rm -rf "${T}"' EXIT
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails + 1)); }

setup() {
  rm -rf "${T}/w"; mkdir -p "${T}/w/bin" "${T}/w/support" "${T}/w/state" "${T}/w/AgentBar.app"
  # pgrep: "running" iff the file exists. open: records its argument.
  printf '#!/bin/sh\n[ -f "%s/w/running" ]\n' "${T}" > "${T}/w/bin/pgrep"
  printf '#!/bin/sh\necho "$@" >> "%s/w/opened"\n' "${T}" > "${T}/w/bin/open"
  chmod +x "${T}/w/bin/"*
}
run_ka() {
  PATH="${T}/w/bin:/usr/bin:/bin" AGENTBAR_APP="${T}/w/AgentBar.app" AGENTBAR_SUPPORT_DIR="${T}/w/support" \
    LIFECYCLE_STATE_DIR="${T}/w/state" "$@" bash "${ka}"
}
opened() { [[ -f "${T}/w/opened" ]]; }

setup; touch "${T}/w/running"; run_ka
opened && fail running "relaunched a running app" || pass "running -> nothing"

setup; run_ka
if opened && grep -q "relaunched AgentBar: not running, no clean-quit marker" "${T}/w/state/keepalive.log" \
  && [[ "$(wc -l < "${T}/w/state/keepalive.log")" -eq 1 ]]; then pass "killed -> relaunch + one log line"
else fail killed "no relaunch/log: $(cat "${T}/w/state/keepalive.log" 2>/dev/null)"; fi

setup; touch "${T}/w/support/clean-quit"; run_ka
opened && fail cleanquit "relaunched after a clean quit" || pass "clean quit -> stays down"

setup; echo 1000 > "${T}/w/state/AgentBar.deploying"; run_ka env NOW=1100
opened && fail deploying "relaunched mid-deploy" || pass "deploy in progress -> waits"

setup; echo 1000 > "${T}/w/state/AgentBar.deploying"; run_ka env NOW=2000
opened && grep -q "deploy marker stale" "${T}/w/state/keepalive.log" && pass "stale deploy marker -> relaunch" \
  || fail stale "no relaunch after a stale deploy marker"

setup; rm -rf "${T}/w/AgentBar.app"; run_ka
opened && fail missing "opened a missing bundle" || pass "missing bundle -> no open, logged"

# app-lifecycle.sh: stop sets the deploy marker (so the keep-alive waits), a failed start keeps it
# (keep-alive relaunches once stale) and exits non-zero with a STOP line.
setup; mkdir -p "${T}/w/repo/scripts" "${T}/w/repo/dist/AgentBar.app"
cp "${repo_root}/scripts/app-lifecycle.sh" "${T}/w/repo/scripts/"
printf '#!/bin/sh\nexit 1\n' > "${T}/w/bin/pkill"; printf '#!/bin/sh\nexit 1\n' > "${T}/w/bin/pgrep"; chmod +x "${T}/w/bin/"*
L() { PATH="${T}/w/bin:/usr/bin:/bin" LIFECYCLE_STATE_DIR="${T}/w/state" START_TIMEOUT=1 bash "${T}/w/repo/scripts/app-lifecycle.sh" "$@"; }
L stop AgentBar >/dev/null
[[ -f "${T}/w/state/AgentBar.deploying" ]] && pass "lifecycle stop -> deploy marker" || fail stopmarker "no marker"
out="$(L start AgentBar 2>&1)"; rc=$?
(( rc != 0 )) && [[ "${out}" == *"STOP"* ]] && [[ -f "${T}/w/state/AgentBar.deploying" ]] \
  && pass "lifecycle start, app never appears -> STOP, exit ${rc}" || fail startfail "rc=${rc} out=${out}"
# Two processes after start -> the newer is killed, marker cleared, exit 0.
printf '#!/bin/sh\necho 222; echo 111\n' > "${T}/w/bin/pgrep"; printf '#!/bin/sh\necho "$@" >> "%s/w/killed"\n' "${T}" > "${T}/w/bin/kill"
chmod +x "${T}/w/bin/"*
out="$(PATH="${T}/w/bin:/usr/bin:/bin" L start AgentBar 2>&1)"; rc=$?
(( rc == 0 )) && [[ "${out}" == *"pid 111, exactly one"* && "${out}" == *"killed the newer: 222"* ]] \
  && [[ ! -f "${T}/w/state/AgentBar.deploying" ]] && pass "lifecycle start, two processes -> newer killed" \
  || fail extras "rc=${rc} out=${out}"

# Streamed the way prod-push.sh runs it on the Pro (`cd scripts && bash -s`): must find dist/.
printf '#!/bin/sh\necho 111\n' > "${T}/w/bin/pgrep"; chmod +x "${T}/w/bin/pgrep"
out="$(cd "${T}/w/repo/scripts" && PATH="${T}/w/bin:/usr/bin:/bin" LIFECYCLE_STATE_DIR="${T}/w/state" START_TIMEOUT=1 \
  bash -s -- start AgentBar < "${repo_root}/scripts/app-lifecycle.sh" 2>&1)"; rc=$?
(( rc == 0 )) && [[ "${out}" == *"exactly one"* ]] && pass "lifecycle streamed via bash -s finds the bundle" || fail streamed "rc=${rc} out=${out}"

(( fails == 0 )) && echo "ALL PASS" || { echo "${fails} FAILED"; exit 1; }
