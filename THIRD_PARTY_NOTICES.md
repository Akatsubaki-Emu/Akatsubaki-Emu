# Third-party notices

## UTM (reference implementation)

Akatsubaki Emu's QEMU integration references and adapts lifecycle and launcher patterns from UTM:

- Project: https://github.com/utmapp/UTM
- Relevant reference files: `Services/UTMQemuSystem.m`, `Configuration/UTMQemuConfiguration+Arguments.swift`, and `QEMULauncher/Bootstrap.c`
- License for those UTM source files: Apache License 2.0
- Copyright notice: Copyright © 2020–2022 osy and UTM contributors.

The Apache License 2.0 text is available at https://www.apache.org/licenses/LICENSE-2.0. Adapted source retains an attribution comment in `iSteam/QEMUNativeBridge.c`.

## QEMU

QEMU is a separate upstream project: https://gitlab.com/qemu-project/qemu.

- **Project-level license:** GNU GPL version 2. QEMU's own [license explanation](https://www.qemu.org/license.html) says QEMU as a whole is GPLv2; per-file headers can specify other terms, files without a license header default to GPLv2-or-later, and some areas have GPLv2-only contributions. TCG is mostly BSD/MIT, but each linked component still needs its own audit. Do not describe the entire QEMU project as a blanket GPLv2-or-later work.
- **Pinned build input:** the pinned UTM 5.0.9 source revision selects the `qemu-10.0.12-utm.tar.xz` release asset. The build workflow verifies and records that exact URL in both JIT and TCI runtime artifacts.
- **Distribution review:** this repository's application license is GPLv3, while QEMU's project-level license is GPLv2 with file-level exceptions. Because the QEMU runtime is loaded as an in-process shared library, perform a file-level and combined-work compatibility review before distributing an IPA. Do not assume that dynamic linking or a separate framework alone resolves compatibility. Preserve the exact QEMU source, UTM patches, configure options, linked dependency licenses and all notices; obtain qualified review or required permissions before public distribution.

Do not change the repository's top-level license as a workaround without authorization from every relevant rights holder.
