# GitHub Actions CI/CD and GitLab mirror synchronization

## Current development destination (2026-11-25)

- **Required write destination:** https://gitlab.com/chantinlongxthrx/I-steam, existing branch `main`.
- **GitHub repository:** https://github.com/Akatsubaki-Emu/Akatsubaki-Emu, whose `main` is behind the current GitLab `main`.
- **No safe automatic reconciliation:** do not push the stale GitHub head back to GitLab, force-push either host, or merge/rebase divergent histories without explicit owner authorization.

The current project-level development instruction requires GitLab `main` as the commit destination. GitHub Actions still hosts the Apple-platform and QEMU build workflows, but those workflows cannot validate GitLab-only commits while GitHub `main` remains behind. The retained `.github/workflows/blank.yml` is a GitHub-to-GitLab sync workflow; it does not propagate GitLab commits upstream. Do not modify it without explicit owner approval. The manual GitLab `.gitlab-ci.yml` validation pipeline is restricted to `main` and `web`/`api` triggers; its latest run is blocked by shared runner quota. This direction mismatch is a release/build blocker, not a reason to write source changes to GitHub.

## GitHub Actions workflows

All repository automation is stored in `.github/workflows/`:

- `validate-repository.yml` — validates workflow/project YAML, packaging-script shell syntax, QEMU source assumptions, Python source-contract/regression tests, native C/C++ bridge and guest-memory tests, and standalone Swift runtime harnesses.
- `validate-ios-build.yml` — compiles the iOS, tvOS, and visionOS simulator targets and runs focused Apple-platform checks.
- `build-qemu-runtime.yml` — reusable and manual build of the physical iOS arm64 QEMU/UTM JIT and TCI runtime variants.
- `release.yml` — orchestrates the QEMU runtime and Apple-platform packaging, verifies release assets, and publishes Nightly/Main GitHub releases.
- `Update stats.yml` — refreshes repository metrics.
- `blank.yml` — retained GitHub-to-GitLab main synchronization. Do not rename, remove, or disable it without explicit owner approval.
- `reconcile-gitlab-main.yml` — manually invoked history reconciliation helper. Review divergence and the exact GitLab commits before dispatching; never use it to bypass canonical GitHub review.

There is no `.gitlab-ci.yml` in the canonical repository. Do not recreate GitLab CI jobs. The former GitLab Swift, native-memory, and Python validation jobs are now covered by `validate-repository.yml`.

## GitHub → GitLab synchronization

The retained `.github/workflows/blank.yml` workflow pushes canonical GitHub `main` to GitLab `main` using the existing `GITLAB_TOKEN` GitHub Actions secret. The metrics workflow writes SVG commits using `GITHUB_TOKEN`, which does not trigger a normal push workflow; its final `sync-mirror` job therefore dispatches `blank.yml` with `workflow_dispatch` after both metrics jobs succeed. This keeps generated metrics commits mirrored without changing the protected sync workflow. The sync workflow:

- fetches GitLab history before pushing;
- exits when both main refs already match;
- only fast-forwards GitLab when its current head is an ancestor of GitHub;
- retries only detected rate-limit responses, with increasing waits and fresh ancestry checks;
- refuses to overwrite newer GitLab history or auto-resolve divergent histories;
- serializes sync runs without cancelling an in-progress mirror update.

Keep the workflow unchanged unless the owner explicitly approves a modification. The GitLab push-mirror configuration is external project settings and is not changed by this repository migration. Verify it separately in GitLab Settings → Repository → Mirroring repositories.

## Development rules

1. Make ordinary source, workflow, and documentation changes on existing GitLab `main`.
2. Do not write to GitHub while its `main` is behind unless a specific safe fallback is verified and authorized.
3. Keep the GitHub-to-GitLab sync workflow unchanged; it cannot currently reconcile GitLab-ahead history.
4. Compare commit SHAs on both hosts before assuming synchronization completed.
5. Never force-push either host or auto-merge divergent histories to make the refs appear synchronized.
6. A GitHub workflow run is evidence only for the jobs that actually ran. A queued, skipped, cancelled, or failed run is not a passing test.
7. Simulator compilation, an IPA archive, or a QEMU runtime artifact does not prove physical-device installation or successful guest execution.

## Required secrets

- `GITLAB_TOKEN` — GitLab project access token with the minimum repository write scope required by the GitHub → GitLab sync workflow.

Do not commit tokens or mirror credentials. The website repository separately owns the AltStore/PAL source updater and its publishing permissions.
