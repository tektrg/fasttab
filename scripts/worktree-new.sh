#!/usr/bin/env bash

set -euo pipefail

# Creates a ready-to-build worktree next to the main checkout:
#   ../<repo>-wt-<slug>  on new branch feat/<slug> (or $BRANCH), from <base>.
#
# Steps: disk preflight -> fast-forward ../IndieLibKit -> fetch + worktree add
#        -> seed the SwiftPM cache from the main checkout -> next steps.
#
# The seed copies .build/{artifacts,checkouts,repositories} and a rewritten
# workspace-state.json, so the first build does not re-download binary
# artifacts (SwiftPM's Lottie download can hang forever at 0% CPU).
#
# Usage:
#   scripts/worktree-new.sh <slug> [base=origin/main]
# Env:
#   BRANCH=<name>      branch to create (default feat/<slug>)
#   ALLOW_LOW_DISK=1   skip the 6 GB free-space refusal

MIN_FREE_GB=6

die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }
step() { echo "==> $*"; }
on_err() { echo "ERROR: worktree-new.sh failed at line $1: ${2%%$'\n'*}" >&2; }
trap 'on_err "${LINENO}" "${BASH_COMMAND}"' ERR

usage() { echo "Usage: $0 <slug> [base=origin/main]   (env: BRANCH=, ALLOW_LOW_DISK=1)"; }

[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 1; }
[[ "$1" == "-h" || "$1" == "--help" ]] && { usage; exit 0; }

slug="$1"
base="${2:-origin/main}"
[[ "${slug}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || die "slug '${slug}' must be letters, digits, '.', '_' or '-' (it becomes a folder name)"
branch="${BRANCH:-feat/${slug}}"

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The first entry of `git worktree list` is always the main checkout, even when
# this script runs from inside another worktree.
main_root="$(git -C "${script_dir}" worktree list --porcelain | sed -n '1s/^worktree //p')"
[[ -d "${main_root}" ]] || die "could not locate the main checkout from ${script_dir}"
parent_dir="$(dirname "${main_root}")"
wt="${parent_dir}/$(basename "${main_root}")-wt-${slug}"
indielib="${parent_dir}/IndieLibKit"

# 1. Disk preflight ----------------------------------------------------------
step "Preflight: free disk space on /"
avail_kb="$(df -k / | awk 'NR==2 {print $4}')"
avail_h="$(df -h / | awk 'NR==2 {print $4}')"
avail_gb=$((avail_kb / 1024 / 1024))
echo "    free: ${avail_h} (need ${MIN_FREE_GB} GB; the seeded cache alone is ~800 MB, a debug build several GB)"
if (( avail_gb < MIN_FREE_GB )); then
  if [[ "${ALLOW_LOW_DISK:-}" == "1" ]]; then
    warn "only ${avail_h} free, continuing because ALLOW_LOW_DISK=1"
  else
    die "only ${avail_h} free on / (< ${MIN_FREE_GB} GB). Free space first, or rerun with ALLOW_LOW_DISK=1"
  fi
fi

[[ ! -e "${wt}" ]] || die "${wt} already exists"
if git -C "${main_root}" show-ref --verify --quiet "refs/heads/${branch}"; then
  die "branch ${branch} already exists (pick another slug or set BRANCH=)"
fi

# 2. IndieLibKit -------------------------------------------------------------
step "IndieLibKit: bring ${indielib} up to origin/main"
if [[ ! -d "${indielib}/.git" && ! -f "${indielib}/.git" ]]; then
  warn "${indielib} is not a git checkout; the build will fail without it"
else
  lib_branch="$(git -C "${indielib}" rev-parse --abbrev-ref HEAD)"
  if [[ "${lib_branch}" != "main" ]]; then
    warn "IndieLibKit is on '${lib_branch}', not main; leaving it alone"
  elif ! git -C "${indielib}" fetch origin --quiet; then
    warn "could not fetch IndieLibKit origin; leaving it as is"
  else
    behind="$(git -C "${indielib}" rev-list --count HEAD..origin/main)"
    if (( behind == 0 )); then
      echo "    already up to date with origin/main"
    else
      echo "    ${behind} commit(s) behind origin/main, fast-forwarding"
      # --ff-only never rewrites history; git refuses (and we warn) if a local
      # uncommitted change would be overwritten.
      git -C "${indielib}" pull --ff-only --quiet origin main \
        || warn "IndieLibKit fast-forward failed (diverged or local changes in the way); continuing on the old head"
    fi
  fi
  echo "    IndieLibKit head: $(git -C "${indielib}" log -1 --format='%h %s' HEAD) [${lib_branch}]"
fi

# 3. Fetch + worktree --------------------------------------------------------
step "Fetching origin"
git -C "${main_root}" fetch origin --quiet
git -C "${main_root}" rev-parse --verify --quiet "${base}^{commit}" >/dev/null \
  || die "base '${base}' is not a known commit"

step "Creating worktree ${wt} on branch ${branch} from ${base}"
git -C "${main_root}" worktree add --no-track -b "${branch}" "${wt}" "${base}"

# 4. Seed the SwiftPM cache --------------------------------------------------
shared_build="${main_root}/.build"
wt_build="${wt}/.build"
step "Seeding SwiftPM cache from ${shared_build}"
if [[ ! -d "${shared_build}" ]]; then
  warn "main checkout has no .build; skipping the seed (first build will download everything)"
else
  mkdir -p "${wt_build}"
  for d in artifacts checkouts repositories; do
    if [[ -d "${shared_build}/${d}" ]]; then
      echo "    copying .build/${d} ($(du -sh "${shared_build}/${d}" | cut -f1))"
      cp -R "${shared_build}/${d}" "${wt_build}/"
    else
      warn "no ${shared_build}/${d}; skipped"
    fi
  done

  if [[ -f "${shared_build}/workspace-state.json" ]]; then
    echo "    writing workspace-state.json and repointing checkouts at the new .build"
    # Rewrites every absolute path to the shared .build: artifact paths in
    # workspace-state.json, plus each checkout's remote url / git alternates
    # (they point at .build/repositories).
    python3 - "${shared_build}" "${wt_build}" <<'PY'
import json, os, sys
old, new = sys.argv[1], sys.argv[2]

def rewrite(path):
    with open(path) as f:
        text = f.read()
    if old not in text:
        return
    mode = os.stat(path).st_mode
    os.chmod(path, mode | 0o200)  # SwiftPM leaves checkouts read-only
    with open(path, "w") as f:
        f.write(text.replace(old, new))
    os.chmod(path, mode)

src = os.path.join(old, "workspace-state.json")
dst = os.path.join(new, "workspace-state.json")
with open(src) as f:
    text = f.read().replace(old, new)
json.loads(text)  # refuse to write a broken state file
with open(dst, "w") as f:
    f.write(text)

checkouts = os.path.join(new, "checkouts")
for root, dirs, files in os.walk(checkouts):
    if ".git" not in root.split(os.sep):
        continue
    for name in files:
        if name in ("config", "alternates"):
            rewrite(os.path.join(root, name))
PY
    if grep -rqsF "${shared_build}" "${wt_build}/workspace-state.json" "${wt_build}/checkouts"/*/.git/config; then
      die "seeded files still point at ${shared_build}"
    fi
  else
    warn "no ${shared_build}/workspace-state.json; artifacts copied but SwiftPM may re-download them"
  fi
fi

if [[ ! -f "${wt}/Package.resolved" && -f "${main_root}/Package.resolved" ]]; then
  echo "    copying Package.resolved from the main checkout"
  cp "${main_root}/Package.resolved" "${wt}/Package.resolved"
fi

# 5. Next steps --------------------------------------------------------------
step "Done: ${wt} (${branch} @ $(git -C "${wt}" log -1 --format='%h' HEAD))"
cat <<EOF
Next steps:
  cd ${wt}
  timeout 900 swift build        # first build reuses the seeded cache
  scripts/test-split.sh          # FastTabTests + AgentBarTests, hang-safe
  git push -u origin ${branch}
When finished:
  git -C ${main_root} worktree remove ${wt}
EOF
