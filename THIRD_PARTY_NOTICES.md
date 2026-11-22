# Third-party notices

## UTM (reference implementation)

Akatsubaki Emu's QEMU integration references and adapts lifecycle and launcher patterns from UTM:

- Project: https://github.com/utmapp/UTM
- Relevant reference files: `Services/UTMQemuSystem.m`, `Configuration/UTMQemuConfiguration+Arguments.swift`, and `QEMULauncher/Bootstrap.c`
- License for those UTM source files: Apache License 2.0
- Copyright notice: Copyright © 2020–2022 osy and UTM contributors.

The Apache License 2.0 text is available at https://www.apache.org/licenses/LICENSE-2.0. Adapted source retains an attribution comment in `iSteam/QEMUNativeBridge.c`.

## QEMU

QEMU is a separate upstream project: https://gitlab.com/qemu-project/qemu. Its project-level license is generally GNU GPL version 2 or later, with components and dependencies potentially carrying different licenses. Before shipping a QEMU build, record the exact source revision, applied UTM patches, configure options, linked dependencies, and all applicable notices. Do not assume this notice alone satisfies redistribution requirements for a compiled runtime.

## StikJIT

Akatsubaki embeds the StikJIT 2.0.1 XCFramework in its iOS 26 ExtensionKit helper:

- Project: https://github.com/StikDebug/StikJIT
- Release: https://github.com/StikDebug/StikJIT/releases/tag/2.0.1
- Artifact: `StikJIT.xcframework.zip`
- SHA-256: `c376687326a785f5ed1da8caca08adc709b56919019dd751bca059b92b175d95`
- License: Mozilla Public License 2.0; full text: `THIRD_PARTY_LICENSES/MPL-2.0.txt`

The framework is downloaded at build time and verified against the pinned digest. The StikJIT source and release remain available from the upstream project.

## LocalDevVPN and StikDebug

LocalDevVPN and StikDebug are integration dependencies only; their app binaries, packet-tunnel extension and app source are not bundled. LocalDevVPN must be installed separately and its VPN profile approved by the user. Its packet-tunnel extension requires Apple's Network Extension entitlement and a matching provisioning profile, which the current Akatsubaki signing configuration does not declare.


## idevice Remote Pairing library

Project: https://github.com/jkcoxson/idevice  
Revision: `7bd551c16c6dd2e058740d85a2d9399a51a776e9`  
License: MIT; Copyright Jackson Coxson. See `THIRD_PARTY_LICENSES/MIT-idevice.txt`.

The pairing FFI is original Akatsubaki code. StikPair's MIT Non-Commercial app and wrapper source are not bundled.
