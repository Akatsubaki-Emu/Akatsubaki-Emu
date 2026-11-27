# Third-party notices

## UTM (reference implementation)

`iSteam/QEMUNativeBridge.c` explicitly records that its QEMU lifecycle integration adapts UTM material. Preserve the Apache-2.0 attribution and applicable licence conditions for that upstream-derived material. The root GPL-3.0-or-later grant does not erase those conditions. If the adapted material is part of a combined application/runtime work, the GPLv2 option may not be available for that combined distribution; a GPLv3-compatible path, separate permission, or clean-room replacement requires review.

Akatsubaki Emu's QEMU integration references and adapts lifecycle and launcher patterns from UTM:

- Project: https://github.com/utmapp/UTM
- Relevant reference files: `Services/UTMQemuSystem.m`, `Configuration/UTMQemuConfiguration+Arguments.swift`, and `QEMULauncher/Bootstrap.c`
- License for those UTM source files: Apache License 2.0
- Copyright notice: Copyright © 2020–2022 osy and UTM contributors.

The pinned UTM build input is commit `3d4b8d8cb1ce93a8b1a9610695c12487685f0c15` (UTM 5.0.9); its repository-level `LICENSE` is Apache License 2.0. This top-level notice applies to UTM-authored material covered by it, not to QEMU or every third-party dependency in the UTM archive. The Apache License 2.0 text is available at https://www.apache.org/licenses/LICENSE-2.0. Adapted source retains an attribution comment in `iSteam/QEMUNativeBridge.c`.

The UTM iOS archives are intermediate build inputs. Akatsubaki's packagers extract the QEMU dynamic library/framework, required dependency frameworks, and firmware/data; they do not bundle UTM's Swift UI wrapper. The extracted QEMU runtime is loaded in-process by Akatsubaki Emu. This packaging description is factual provenance, not a legal conclusion about whether a combined work is formed.

## QEMU

QEMU is a separate upstream project; this build uses the pinned UTM-maintained fork: https://github.com/utmapp/qemu.

- **Project-level license:** GNU GPL version 2. The pinned QEMU fork's [README](https://github.com/utmapp/qemu/blob/v10.0.12-utm/README.rst) states that QEMU as a whole is released under GPL version 2. Its [LICENSE](https://github.com/utmapp/qemu/blob/v10.0.12-utm/LICENSE) describes file-level notices and the default for files without a license header; its [COPYING](https://github.com/utmapp/qemu/blob/v10.0.12-utm/COPYING) contains the GPLv2 text. The LICENSE also records GPLv2-only contribution areas and notes that TCG is mostly BSD/MIT with some GPLv2 or other licensed parts. These project-level documents do not prove which files are linked into this iOS x86_64-softmmu archive; audit the actual selected source files and linked objects. Do not describe the entire build as a blanket GPLv2-or-later work.
- **Pinned build input:** the pinned UTM 5.0.9 source revision selects the `qemu-10.0.12-utm.tar.xz` release asset. The build workflow verifies and records that exact URL in both JIT and TCI runtime artifacts.
- **GPL-3.0-or-later compatibility:** GPL-2.0-only QEMU components can in principle be combined with Akatsubaki-authored code under its GPL-3.0-or-later grant by choosing GPLv2 terms; QEMU remains under its own licence and file-level notices. Apache License 2.0 is not compatible with GPL-2.0-only when the works are combined into a single derivative work. Because `iSteam/QEMUNativeBridge.c` identifies an adaptation of UTM lifecycle material with Apache-2.0 provenance, the GPLv2 option may not be available for a combined app/runtime distribution containing that material. A GPLv3-compatible path, separate permission, or clean-room replacement needs qualified review. Do not infer compatibility from UTM's root licence or from dynamic linking.
- **Distribution review:** Akatsubaki-authored code is licensed GPL-3.0-or-later; QEMU's project-level license is GPLv2 with file-level exceptions, and UTM-derived bridge material carries Apache-2.0 provenance. Because QEMU is loaded as an in-process shared library, perform a file-level and combined-work compatibility review before distributing an IPA. Do not assume that dynamic linking or a separate framework alone resolves compatibility. Preserve the exact QEMU source, UTM patches, configure options, linked dependency licenses and all notices; obtain qualified review or required permissions before public distribution.

The project-authored files have been moved to GPL-3.0-or-later only where the project has the necessary rights; upstream-origin files retain their original terms.
