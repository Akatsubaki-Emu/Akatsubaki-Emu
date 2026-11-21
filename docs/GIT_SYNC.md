# GitLab ↔ GitHub synchronization and GitHub Actions CI/CD

## Repositories

- **GitLab:** https://gitlab.com/chantinlongxthrx/I-steam
- **GitHub:** https://github.com/Akatsubaki-Emu/Akatsubaki-Emu
- **Branch:** `main`

GitHub is the canonical source repository; GitLab is its mirror. Both configured synchronization directions are retained for recovery and owner-directed workflows:

1. **GitHub → GitLab:** `.github/workflows/blank.yml` pushes canonical GitHub main commits to GitLab main using the existing `GITLAB_TOKEN` secret. This workflow has been restored byte-for-byte from the commit immediately before its accidental deletion and is intentionally left unchanged.
2. **GitLab → GitHub:** the owner-configured GitLab push mirror can publish owner-requested GitLab commits to canonical GitHub. This is configured in GitLab project settings, not by a repository workflow.

Do not edit, rename, disable, or delete `.github/workflows/blank.yml` without explicit owner approval. The scheduled `.github/workflows/mirror-from-gitlab.yml` polling workflow has been removed because the owner-configured GitLab push mirror already handles GitLab → GitHub synchronization. The GitLab CI configuration has also been removed; CI/CD runs on GitHub Actions.

## Important bidirectional-mirror caution

Two active push directions can race or create divergent histories if both sides receive independent commits. The GitHub → GitLab workflow contains ancestry checks and refuses some unsafe updates, but that is not a complete distributed synchronization protocol. Make ordinary source changes on canonical GitHub and let the retained GitHub → GitLab workflow update the mirror. If the owner explicitly requests direct GitLab commits, verify that the GitLab → GitHub push mirror has caught up before making further canonical changes. Never force-push either side to resolve a divergence without explicit review.

## GitHub Actions CI/CD

All CI/CD definitions live in `.github/workflows/` and execute on GitHub:

- `validate-repository.yml` — YAML/configuration validation, duplicate-key detection, QEMU source validation, and shell syntax checks.
- `validate-ios-build.yml` — iOS, tvOS, and visionOS simulator compile checks.
- `build-qemu-runtime.yml` — builds and packages the iOS arm64 QEMU/UTM runtime; supports manual and reusable-workflow calls.
- `release.yml` — builds the runtime first, then platform packages and combined GitHub releases. The separate website repository's `update-xthrx-alt-source.yml` workflow refreshes official AltStore/PAL feeds from published releases.
- `blank.yml` — synchronization only; not a build or validation job. Keep unchanged.

Required app-repository GitHub secrets include `GITLAB_TOKEN` for the retained GitHub → GitLab sync. The app release workflow no longer needs a website write token; the website repository owns its feed updater and `contents: write` permission. The GitLab push-mirror credentials remain configured in GitLab settings and must not be committed to source.

## Mirror verification

The GitLab push mirror is external project configuration. Verify it in GitLab Settings → Repository → Mirroring repositories. Confirm the GitHub target, enabled status, and successful last update. This repository change does not alter those settings.

## Validation and limitations

- A successful GitHub workflow run proves only the checks it actually executes.
- Simulator compilation and IPA packaging do not prove physical-device installation, guest OS boot, persistence, or game compatibility.
- The QEMU runtime build must produce and package its artifact in the same release workflow run before the iOS app packaging job can proceed.
- GitHub Actions sync success and GitLab push-mirror success must be checked independently.
