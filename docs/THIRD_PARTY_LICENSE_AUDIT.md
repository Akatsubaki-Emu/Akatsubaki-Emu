# Third-party license audit

**Project license:** Akatsubaki Emu is GPL-3.0 (see [LICENSE](../LICENSE)). This audit records upstream facts relevant to the current QEMU/UTM runtime work; it is not a legal opinion.

## Verified upstream inputs (2026-11-23)

| Component | Upstream revision | License evidence | Integration status |
|---|---|---|---|
| UTM | [utmapp/UTM](https://github.com/utmapp/UTM), commit [3d4b8d8](https://github.com/utmapp/UTM/commit/3d4b8d8cb1ce93a8b1a9610695c12487685f0c15) | Apache-2.0 LICENSE; UTM README says it also uses (L)GPL components | Build orchestration and packaging scripts consume UTM; no UTM frontend source is vendored |
| UTM QEMU fork | [utmapp/qemu](https://github.com/utmapp/qemu), tag `v10.0.12-utm`, commit [6601422](https://github.com/utmapp/qemu/commit/6601422e1fff2da1376faafb1e4c2c5cdb2d8003) | QEMU `LICENSE` says QEMU as a whole is GPL version 2; files may have specific licenses. TCG is mostly BSD/MIT, but some TCG files may be GPLv2 or other licenses | Built as a separate dynamic runtime by the iOS QEMU workflow; not yet cleared for redistribution inside the GPL-3.0 app |
| QEMU TCI | Same QEMU revision, built with UTM's `--enable-tcg-threaded-interpreter` for arm64 | Same per-file QEMU licensing; TCI does not change the project-level license | Build/package route exists in CI; successful hosted artifact and physical-device boot remain unverified |

The UTM dependency source list at the pinned UTM revision downloads `qemu-10.0.12-utm.tar.xz` from the UTM QEMU fork. The UTM build script exposes an `iOS-TCI` scheme and enables the threaded TCG interpreter for arm64.

## GPL-3.0 compatibility gate

QEMU's upstream license statement is not a blanket GPL-3.0 grant. QEMU is GPL-2.0 as a whole, with file-level exceptions; some files are GPL-2.0-only, while other files are GPL-2.0-or-later, BSD, MIT, or separately licensed. Akatsubaki Emu is GPL-3.0.

Because the current architecture loads QEMU as an in-process dynamic library, do **not** assume that a GPL-2.0-only QEMU component can be combined with the GPL-3.0 app. Before publishing an IPA containing the QEMU runtime:

1. Produce a source/build manifest for the exact QEMU 10.0.12-utm archive and configuration used by the build.
2. Identify the license of every compiled object, including machine/device models, TCG helpers, firmware and linked dependencies.
3. Establish whether the selected binary and in-process bridge can be distributed alongside the GPL-3.0 app without creating an incompatible combined work. Obtain qualified legal review if uncertain.
4. Preserve upstream copyright/license notices and provide the complete corresponding source and build/patch scripts required by each applicable license.
5. Record the decision and approved file set here before marking QEMU redistribution as cleared.

This is a **potential compatibility blocker**, not a conclusion that every QEMU component is incompatible. TCG's mostly BSD/MIT code is a useful reuse candidate, but the full-system runtime also includes code outside TCG. Do not infer compatibility from the TCI execution mode alone.

## Other integration candidates

- FEXCore and Box64 remain candidates for user-mode x86-64 translation. Their exact revisions, full dependency trees, licenses and iOS host compatibility must be checked before integration.
- Zydis and VIXL are potential decoder/code-generator components; verify exact revisions and licenses before vendoring.
- Wine/Proton, graphics translators, firmware and other UTM dependencies need their own file-level license and attribution review.
- No FEXCore, Box64, Wine or Proton source is currently integrated into Kenran Butō.

## Verification boundary

- **VERIFIED:** project GPL-3.0; UTM Apache-2.0 license; pinned UTM commit; UTM QEMU source URL/tag; QEMU project-level GPL-2.0 statement; UTM iOS-TCI build flag.
- **PARTIALLY VERIFIED:** compatibility of the actual compiled QEMU/UTM binary with the GPL-3.0 app; requires an object-level license manifest and legal review.
- **UNTESTED:** exact hosted runtime artifact, signed IPA, physical iPad guest boot.
