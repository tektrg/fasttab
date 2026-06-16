#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/release.sh VERSION [--skip-tests] [--dry-run]

Creates and pushes an annotated release tag from main.

Examples:
  scripts/release.sh 1.5.2
  scripts/release.sh 1.5.2 --dry-run

Notes:
  This script does not build, sign, notarize, package, or update Sparkle appcast
  metadata. The official distribution pipeline remains outside this source checkout.
USAGE
}

die() {
  echo "release: $*" >&2
  exit 1
}

run() {
  echo "+ $*"
  if [[ "${DRY_RUN}" == "false" ]]; then
    "$@"
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

version=""
SKIP_TESTS=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --skip-tests)
      SKIP_TESTS=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [[ -n "${version}" ]]; then
        die "unexpected extra argument: $1"
      fi
      version="$1"
      shift
      ;;
  esac
done

[[ -n "${version}" ]] || {
  usage
  exit 2
}

[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 1.5.2"

require_command git
require_command swift

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

branch="$(git branch --show-current)"
[[ "${branch}" == "main" ]] || die "release must run from main; current branch is ${branch:-detached}"

git fetch origin main --tags

if [[ -n "$(git status --porcelain)" ]]; then
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "Dry run: working tree is not clean; a real release would stop here." >&2
  else
    die "working tree must be clean before release"
  fi
fi

local_head="$(git rev-parse HEAD)"
remote_head="$(git rev-parse origin/main)"
[[ "${local_head}" == "${remote_head}" ]] || die "main must match origin/main before tagging"

if git rev-parse -q --verify "refs/tags/${version}" >/dev/null; then
  die "tag ${version} already exists locally"
fi

if git ls-remote --exit-code --tags origin "refs/tags/${version}" >/dev/null 2>&1; then
  die "tag ${version} already exists on origin"
fi

latest_tag="$(git tag --sort=-version:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"
if [[ -n "${latest_tag}" ]]; then
  highest_version="$(printf '%s\n%s\n' "${latest_tag}" "${version}" | sort -V | tail -n 1)"
  [[ "${highest_version}" == "${version}" && "${version}" != "${latest_tag}" ]] || \
    die "version ${version} must be greater than latest tag ${latest_tag}"
fi

if [[ "${SKIP_TESTS}" == "false" ]]; then
  run swift test
else
  echo "Skipping tests by request."
fi

run git tag -a "${version}" -m "Release ${version}"
run git push origin "${version}"

echo "Release tag ${version} is ready."
echo "A GitHub Release will be created by .github/workflows/github-release.yml after the tag push."
echo ""
echo "Next: run the distribution pipeline to ship the update to users:"
echo "  scripts/distribute.sh ${version} \"<release notes>\""
