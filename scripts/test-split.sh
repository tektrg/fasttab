#!/usr/bin/env bash

set -euo pipefail

# Builds tests once, then runs FastTabTests and AgentBarTests as separate,
# time-boxed `swift test` runs in the given checkout (default: cwd).
#
# Why split + filtered: plain `swift test` exits 1 even when everything passes
# (the XCTest loader looks for x86_64 bundles), and AgentBarTests sometimes
# hangs, leaving a swiftpm-testing-helper at 0% CPU.
#
# Per suite: run under `timeout`; kill orphaned swiftpm-testing-helper
# processes of this checkout's .build (orphaned = parent is launchd, so another
# session's live run is never touched); retry once if it timed out without a
# result. Pass/fail is read from the "Test run with ... tests" line, not the
# exit code.
#
# Usage:
#   scripts/test-split.sh [checkout-dir]
# Exit: 0 all suites passed | 1 test failures / no result | 2 build failed

die() { echo "ERROR: $*" >&2; exit 2; }
step() { echo "==> $*"; }

dir="${1:-${PWD}}"
[[ -d "${dir}" ]] || die "no such directory: ${dir}"
dir="$(cd -P "${dir}" && pwd)"
[[ -f "${dir}/Package.swift" ]] || die "${dir} has no Package.swift"
build_dir="${dir}/.build"
cd "${dir}"

log_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-split.XXXXXX")"
echo "    logs: ${log_dir}"

# Kills swiftpm-testing-helper processes whose command line contains this
# checkout's .build and whose parent is launchd (pid 1): leftovers of a run
# whose swift-test is gone. Live runs (parent = swift-test) are left alone.
kill_leftover_helpers() {
  local pids
  sleep 1  # let a just-killed swift-test release its helper first
  pids="$(ps -axo pid=,ppid=,command= | awk -v b="${build_dir}/" \
    '$2 == 1 && index($0, "swiftpm-testing-helper") && index($0, b) {print $1}')"
  [[ -n "${pids}" ]] || return 0
  echo "    killing leftover swiftpm-testing-helper: $(echo "${pids}" | tr '\n' ' ')"
  # shellcheck disable=SC2086  # intentional word splitting of the pid list
  kill ${pids} 2>/dev/null || true
  sleep 2
  # shellcheck disable=SC2086
  kill -9 ${pids} 2>/dev/null || true
}

# 1. Build ---------------------------------------------------------------------
step "Building tests in ${dir} (timeout 900s)"
set +e
timeout 900 swift build --build-tests 2>&1 | tee "${log_dir}/build.log"
build_rc=${PIPESTATUS[0]}
set -e
if (( build_rc != 0 )); then
  (( build_rc == 124 )) && echo "BUILD: timed out after 900s" || echo "BUILD: failed (exit ${build_rc})"
  grep -E 'error:' "${log_dir}/build.log" | head -20 || true
  exit 2
fi

# 2. Suites --------------------------------------------------------------------
summaries=()
failed=0

# run_suite <filter> <timeout-seconds>
run_suite() {
  local name="$1" limit="$2" attempt rc log line verdict
  for attempt in 1 2; do
    log="${log_dir}/${name}.${attempt}.log"
    step "${name}: attempt ${attempt} (timeout ${limit}s)"
    set +e
    timeout "${limit}" swift test --skip-build --filter "${name}" 2>&1 | tee "${log}"
    rc=${PIPESTATUS[0]}
    set -e
    kill_leftover_helpers

    # swift-testing summary, e.g. "✔ Test run with 312 tests in 40 suites passed after 9.1 seconds."
    line="$(grep -E 'Test run with [0-9]+ tests?' "${log}" | tail -1 | sed -E 's/^[^A-Za-z]*//' || true)"
    if [[ -n "${line}" ]]; then
      if [[ "${line}" == *" passed"* ]]; then
        verdict="PASS"
      else
        verdict="FAIL"
      fi
      (( rc == 124 )) && line="${line} (hung after finishing; killed)"
      break
    fi
    if (( rc == 124 )); then
      line="timed out after ${limit}s with no result"
      verdict="FAIL"
      (( attempt == 1 )) && echo "    ${name} timed out without a result; retrying once"
      continue
    fi
    verdict="FAIL"
    line="no 'Test run with' line (exit ${rc}); see ${log}"
    break
  done
  summaries+=("${verdict} ${name}: ${line}")
  [[ "${verdict}" == "PASS" ]] || failed=1
}

run_suite FastTabTests 500
run_suite AgentBarTests 240

# 3. Summary -------------------------------------------------------------------
step "Summary (${dir})"
printf '    %s\n' "${summaries[@]}"
exit "${failed}"
