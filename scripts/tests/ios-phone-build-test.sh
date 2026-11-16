#!/usr/bin/env bash
# Tests for the phone-only iPhone deploy:
#   scripts/ios-phone-build.sh  (runs on the Pro: temp clean copy -> build -> remove copy)
#   PHONE_ONLY=1 scripts/prod-push.sh  (runs on the Air: no merge, no Mac apps)
# Local only: throwaway git repos under a temp dir, stub `ssh`/`tmux`/build command on PATH.
# Usage: scripts/tests/ios-phone-build-test.sh   (prints PASS/FAIL per case, exit 1 on any FAIL)
set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="${repo_root}/scripts/ios-phone-build.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/ios-phone-build-test.XXXXXX")"
trap 'rm -rf "${T}"' EXIT
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails + 1)); }
g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

# Two sibling repos like the Pro's ~/01_Project, each on another session's branch with dirty work.
setup() {
  rm -rf "${T}/w"; mkdir -p "${T}/w/proj" "${T}/w/tmproot" "${T}/w/bin" "${T}/w/seed/SourcePackages"
  local app="${T}/w/proj/command-bar-macos" lib="${T}/w/proj/IndieLibKit"
  g init -q "${app}"; mkdir -p "${app}/ios" "${app}/scripts"
  echo v1 > "${app}/ios/file"; g -C "${app}" add -A; g -C "${app}" commit -qm app1
  echo v2 > "${app}/ios/file"; g -C "${app}" commit -qam app2
  g -C "${app}" checkout -qb feat/other-session; echo dirty > "${app}/ios/file"
  g init -q "${lib}"; echo l1 > "${lib}/f"; g -C "${lib}" add -A; g -C "${lib}" commit -qm lib1
  echo l2 > "${lib}/f"; g -C "${lib}" commit -qam lib2
  g -C "${lib}" checkout -qb feat/lib-other; echo libdirty > "${lib}/f"
  echo seeded > "${T}/w/seed/SourcePackages/marker"
  APP="${app}"; LIB="${lib}"
  APP_SHA="$(git -C "${app}" rev-parse HEAD~1)"; LIB_SHA="$(git -C "${lib}" rev-parse HEAD~1)"
  # Build stub: records where it ran and what it saw.
  cat > "${T}/w/bin/build-stub" <<'EOF'
#!/usr/bin/env bash
{ echo "pwd=$(pwd -P)"; echo "head=$(git rev-parse HEAD)"; echo "lib=$(git -C ../IndieLibKit rev-parse HEAD)"
  echo "seed=$(cat ios/build/SourcePackages/marker 2>/dev/null)"; echo "args=$*"; } > "${STUB_LOG}"
exit "${STUB_EXIT:-0}"
EOF
  # tmux stub: "a build is still running" only when STUB_TMUX_ALIVE=1.
  printf '#!/usr/bin/env bash\n[[ "${STUB_TMUX_ALIVE:-0}" == 1 ]]\n' > "${T}/w/bin/tmux"
  chmod +x "${T}/w/bin/build-stub" "${T}/w/bin/tmux"
  export STUB_LOG="${T}/w/stub.log"; rm -f "${STUB_LOG}"
}

run_helper() {
  PATH="${T}/w/bin:${PATH}" PHONE_BUILD_CMD="${T}/w/bin/build-stub" PHONE_TMP_ROOT="${T}/w/tmproot" \
    PHONE_SEED_DIR="${T}/w/seed/SourcePackages" \
    bash "${helper}" --app-repo "${APP}" --lib-repo "${LIB}" --app-sha "${APP_SHA}" --lib-sha "${LIB_SHA}" \
    --device DEV123 > "${T}/w/out.log" 2>&1
}

untouched() {  # the other sessions' branches + dirty files are exactly as they were
  [[ "$(git -C "${APP}" symbolic-ref --short HEAD)" == feat/other-session && "$(cat "${APP}/ios/file")" == dirty \
    && "$(git -C "${LIB}" symbolic-ref --short HEAD)" == feat/lib-other && "$(cat "${LIB}/f")" == libdirty ]]
}
no_temp_left() {
  [[ -z "$(ls -A "${T}/w/tmproot")" && "$(git -C "${APP}" worktree list | wc -l)" -eq 1 \
    && "$(git -C "${LIB}" worktree list | wc -l)" -eq 1 ]]
}

# 1. Builds the requested commits in a temp copy laid out like ~/01_Project, then removes it.
setup; run_helper; rc=$?
if [[ ${rc} -eq 0 ]] && grep -q "^head=${APP_SHA}$" "${STUB_LOG}" && grep -q "^lib=${LIB_SHA}$" "${STUB_LOG}" \
  && grep -q "^pwd=$(cd "${T}/w/tmproot" && pwd -P)/.*/command-bar-macos$" "${STUB_LOG}" \
  && grep -q "^seed=seeded$" "${STUB_LOG}" && grep -q "^args=--device DEV123$" "${STUB_LOG}"; then
  pass "builds requested app+lib commits in a temp copy (seeded, device passed)"
else fail "builds requested commits" "rc=${rc}; $(cat "${STUB_LOG}" 2>/dev/null); $(tail -5 "${T}/w/out.log")"; fi
no_temp_left && pass "temp copy removed after success" || fail "temp copy removed after success" "$(ls "${T}/w/tmproot"; git -C "${APP}" worktree list)"
untouched && pass "other sessions' branches + uncommitted work untouched" || fail "untouched" "branch/dirty changed"

# 2. Build failure: non-zero exit, temp copy still removed.
setup; STUB_EXIT=3 run_helper; rc=$?
[[ ${rc} -ne 0 ]] && pass "build failure exits non-zero" || fail "build failure exits non-zero" "rc=${rc}"
no_temp_left && pass "temp copy removed after failure" || fail "temp copy removed after failure" "$(ls "${T}/w/tmproot")"
untouched || fail "untouched after failure" "branch/dirty changed"

# 3. A build still running (tmux session alive, e.g. timeout or dropped ssh): keep the copy it uses.
setup; STUB_EXIT=1 STUB_TMUX_ALIVE=1 run_helper
[[ -n "$(ls -A "${T}/w/tmproot")" ]] && grep -q "kept" "${T}/w/out.log" \
  && pass "copy kept while a build still runs in it" || fail "copy kept while build runs" "$(cat "${T}/w/out.log")"

# 4. Refuses an unknown commit before creating anything.
setup; APP_SHA=0123456789abcdef0123456789abcdef01234567 run_helper; rc=$?
[[ ${rc} -ne 0 && -z "$(ls -A "${T}/w/tmproot")" && ! -e "${STUB_LOG}" ]] \
  && pass "unknown commit refused, nothing created" || fail "unknown commit refused" "rc=${rc}"

# 5. prod-push PHONE_ONLY=1 DRY_RUN=1: no merge, no Mac app stop/replace, helper gets the right commits.
setup
cat > "${T}/w/bin/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh $*" >> "${SSH_LOG}"
case "$*" in
  *"df -Pk"*) echo 99999999 ;;
  *"has-session -t fasttab-ios-push"*) exit 1 ;;   # no other iPhone build running
esac
exit 0
EOF
chmod +x "${T}/w/bin/ssh"
export SSH_LOG="${T}/w/ssh.log"; : > "${SSH_LOG}"
want_app="$(git -C "${repo_root}" rev-parse HEAD)"
out="$(cd "${repo_root}" && PATH="${T}/w/bin:${PATH}" PHONE_ONLY=1 DRY_RUN=1 PHONE_REF=HEAD INDIELIBKIT_SHA="${LIB_SHA}" \
  MAC_PRO_SSH=stubpro bash scripts/prod-push.sh 2>&1)"; rc=$?
all="${out}
$(cat "${SSH_LOG}")"
if [[ ${rc} -eq 0 ]] && grep -q -- "--app-sha ${want_app}" <<<"${all}" && grep -q -- "--lib-sha ${LIB_SHA}" <<<"${all}" \
  && grep -q -- "--device 243A482F-26DD-5381-8067-41B9DFD7A8CC" <<<"${all}" \
  && ! grep -qE "git merge |merge --ff-only|app-lifecycle|rsync |prod-push-sync|fasttab-build-mac-app|build-agentbar-app" <<<"${all}"; then
  pass "PHONE_ONLY dry run: no merge / Mac apps; helper gets app+lib commit + 16e"
else fail "PHONE_ONLY dry run" "rc=${rc}; ${all}"; fi

echo; (( fails == 0 )) && echo "ALL PASS" || { echo "${fails} FAILED"; exit 1; }
