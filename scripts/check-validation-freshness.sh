#!/usr/bin/env bash
# Skip expensive validation runners when a newer main commit already supersedes this run.
# Unlike check-build-freshness.sh, this is strict: every newer commit, including tests/docs,
# makes an older validation run stale.
set -euo pipefail

base_sha="${1:-${GITHUB_SHA:-}}"
if [[ -z "$base_sha" ]]; then
  echo "A base commit SHA is required." >&2
  exit 2
fi

# Pull requests and non-main manual runs must still validate their own checkout.
if [[ "${GITHUB_REF:-}" != "refs/heads/main" ]]; then
  printf 'true\n'
  exit 0
fi

if [[ "$(git rev-parse --is-shallow-repository)" == "true" ]]; then
  git fetch --no-tags --unshallow origin main >/dev/null
else
  git fetch --no-tags origin main >/dev/null
fi
latest_main="$(git rev-parse refs/remotes/origin/main)"

if [[ "$base_sha" == "$latest_main" ]]; then
  printf 'true\n'
  exit 0
fi

if ! git merge-base --is-ancestor "$base_sha" "$latest_main"; then
  echo "Validation commit $base_sha is not an ancestor of current main $latest_main; skipping stale/diverged run." >&2
  printf 'false\n'
  exit 0
fi

echo "A newer main commit exists ($latest_main); this validation run is stale." >&2
printf 'false\n'
