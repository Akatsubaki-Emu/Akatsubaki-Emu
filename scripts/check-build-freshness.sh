#!/usr/bin/env bash
# Return true when this run is still the newest build-relevant revision of main.
# Commits limited to paths ignored by release.yml must not invalidate a valid build.
set -euo pipefail

base_sha="${1:-${GITHUB_SHA:-}}"
if [ -z "$base_sha" ]; then
  echo "A base commit SHA is required." >&2
  exit 2
fi

if [ "${GITHUB_REF:-}" != "refs/heads/main" ]; then
  printf 'true\n'
  exit 0
fi

# Checkout jobs may be shallow. Fetch enough history to compare the run commit
# with the current main tip without relying on GitHub API state.
if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
  git fetch --no-tags --unshallow origin main >/dev/null
else
  git fetch --no-tags origin main >/dev/null
fi
latest_main="$(git rev-parse refs/remotes/origin/main)"

if [ "$base_sha" = "$latest_main" ]; then
  printf 'true\n'
  exit 0
fi

# If main was force-updated or histories diverged, fail closed and skip this run.
if ! git merge-base --is-ancestor "$base_sha" "$latest_main"; then
  echo "Build commit $base_sha is not an ancestor of current main $latest_main." >&2
  printf 'false\n'
  exit 0
fi

build_relevant_change=false
while IFS= read -r -d '' path; do
  case "$path" in
    .github/workflows/blank.yml|.github/workflows/reconcile-gitlab-main.yml|.github/workflows/validate-ios-build.yml|.github/workflows/validate-repository.ymlscripts/tests/*|README.md|CONTRIBUTING.md|INSTALL.md|LICENSE|docs/*|scripts/validate-qemu-source.py)
      # These paths are excluded by release.yml paths-ignore.
      ;;
    *)
      build_relevant_change=true
      break
      ;;
  esac
done < <(git diff --name-only -z "$base_sha" "$latest_main")

if [ "$build_relevant_change" = true ]; then
  echo "A newer build-relevant commit exists on main ($latest_main)." >&2
  printf 'false\n'
else
  echo "Only release.yml paths-ignore files changed after $base_sha; this build remains current." >&2
  printf 'true\n'
fi
