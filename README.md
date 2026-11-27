# Akatsubaki Emu

> **DISCLAIMER !**
>
> **please read this before using this application**
> 
> **Important Notice Regarding Akatsubaki Emu’s current development stage**
>
> Akatsubaki Emu is still in development and is highly unstable, which means **you may lose your data or get banned**.
>
> Furthermore, please note that we do not provide any support for issues of these development builds. and **we will not take responsibility for any possessions lost whilst using this application**. please use this application at your own risk
> **by using this application you agree to all the notices above**

> Akatsubaki Emu is an experimental iOS, tvOS, and visionOS game-library and guest-runtime project.

[![License: GPL-3.0-or-later](https://img.shields.io/badge/License-GPL--3.0--or--later-blue.svg)](https://spdx.org/licenses/GPL-3.0-or-later.html)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://makeapullrequest.com)
[![Akatsubaki Emu Build & Release](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/actions/workflows/release.yml/badge.svg)](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/actions/workflows/release.yml)

[**GitHub**](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu) · [**All releases**](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/releases) · [**Nightly builds**](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/releases/tag/nightly) · [**GitLab mirror**](https://gitlab.com/chantinlongxthrx/I-steam) · [**AltStore source**](https://altdirect.app/?url=https://akatsubaki-emu.github.io/AltSource.json)


![Overview](docs/metrics-overview.svg)



**Akatsubaki Emu** is a Steam-oriented game library and experimental guest-runtime project for Apple platforms.

> [!WARNING]
> **Akatsubaki Emu is experimental and is not yet a working PC emulator.** It does not currently boot arbitrary Windows/Linux images through a fully integrated emulator or promise that Steam games will run. The tvOS interface is a prototype, not a game launcher. CI IPAs are unsigned; installation requires a compatible signing method, and packaging success does not prove the app works on a device.

## Development timeline (estimate)

- **First playable physical iOS build: February–May 2027.** This is an ambitious planning estimate, not a promised release date. It depends on completing and integrating the Kenran Butō execution path, the required AOT/runtime and ABI work, a reproducible physical-device build, and basic guest display/input. The estimate must be revised as real integration, CI and device-test evidence becomes available.
- **Full emulator completion: not yet estimable.** Broad Windows/Linux compatibility, graphics translation and other production features remain outside the first-playable milestone; there is not enough verified progress to give them a reliable completion date.

Engineering status: [First-playable acceptance](docs/FIRST_PLAYABLE_IOS_ACCEPTANCE.md) · [Legacy feature parity](docs/LEGACY_FEATURE_PARITY.md) · [FEXCore/Box64 iOS integration audit](docs/FEXCORE_IOS_PORT_AUDIT.md)


## Downloads

Choose the build channel and platform below. Nightly builds contain recent changes and may be unstable; Main is the project's main release channel.

| Channel | iOS | tvOS | visionOS |
| --- | --- | --- | --- |
| **Main** | [Download iOS IPA](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/releases/tag/main) | [Download tvOS IPA](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/releases/tag/main) | [Download visionOS app](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/releases/tag/main) |
| **Nightly** | [Download nightly IPA](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/releases/tag/nightly) | [Download nightly IPA](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/releases/tag/nightly) | [Download visionOS nightly](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/releases/tag/nightly) |

Each release contains all three platform packages and SHA-256 checksum files. Open the release page and choose the asset for your device. These are unsigned prototype packages and must be signed before installation.

### Add the AltStore source

Use the source URL below in a compatible AltStore-based app. The website repository refreshes the official AltStore/PAL manifests from published app releases; feed updates may lag a new release until that updater runs.

```text
https://akatsubaki-emu.github.io/AltSource.json
```

<a href="https://altdirect.app/?url=https://akatsubaki-emu.github.io/AltSource.json" target="_blank"><img src="https://altdirect.app/assets/png/AltSource_Blue.png" alt="Add AltSource" width="200"></a>

[SideStore installation guide](https://docs.sidestore.io/)

The source includes separate entries for iOS Main, iOS Nightly, tvOS Main, and tvOS Nightly when published. Apple TV sideloading support depends on the installer and device; an IPA link alone does not guarantee tvOS installation.

## Regional guides

- [Hong Kong（香港繁體中文）](README_HK.md) — regional installation notes and troubleshooting.
- [Japan（日本語）](README_JP.md) — regional installation notes and troubleshooting.

## Features and project status

### iOS app — Akatsubaki Emu

- Experimental library and import flows for executable and operating-system files.
- Local VM/session configuration and last-session metadata.
- Four selectable Icon Composer app icons in Settings; Main defaults to Default and Nightly defaults to Simple.
- File selection and shared-directory handling.
- Bounded, read-only metadata inspection for Windows PE and Linux ELF files.
- A bounded static x86-64 Linux ELF execution path through `GuestMachine`, native C-backed guest memory, a Linux syscall subset, and the x86-64 interpreter; host-side regression coverage exists, but physical iOS execution is not yet verified.
- Guest-memory and block-device prototypes.
- Early display, Metal presentation, frame-pacing, keyboard, controller, and JIT-related experiments.
- Research into app-container and binary-execution approaches used by projects such as LiveContainer.
- Native DroidDeck-inspired library backup/restore, per-game profile defaults, artwork caching, local compatibility records, and runtime component integrity verification.

These are works in progress. Importing a file or inspecting its metadata does not execute it, and a storage prototype is not a complete virtual storage controller. JIT behavior depends on iOS version, device, signing, entitlements, and supported tooling. Akatsubaki Emu requests JIT only for its QEMU VM process through the LocalDevVPN/StikDebug flow; it does not enable JIT for unrelated apps.

### tvOS app

The tvOS target is an early Siri Remote-friendly interface preview. Its Launch session, Steam Store, and Settings actions currently display explanatory notices. It does **not** boot an operating system or launch games.

### Runtime and native helpers

The hybrid execution core is named **Kenran Butō (絢爛舞踏)**. Its AOT translator, translated-code cache, backend router, interpreter fallback, and runtime orchestration now have concrete implementations, but coverage remains deliberately bounded. AOT translates only a subset of x86-64 instructions to ARM64; unsupported instructions must fall back to the interpreter. The iOS JIT path uses a process-lifetime 32 MiB TXM executable arena with exact-allocation tracking and coalescing reuse; it requires a supported StikDebug/JIT session and has not yet been verified on a physical iPad.

A bounded static Linux x86-64 ELF execution path is present: \`GameLauncher\` routes imported static ELF files through \`LinuxELFRuntime\` and \`GuestMachine\`, using \`ELF64Loader\`, \`LinuxProcessStackBuilder\`, \`LinuxSyscallDispatcher\`, \`X86_64Interpreter\`, and native C-backed \`GuestMemory\`. Diagnostic guests exercise register exchange, \`uname\`, \`write\`, and \`exit\`. This is not a general Linux userland: dynamic linking, \`PT_INTERP\`, shared libraries, arbitrary applications, and full-system OS boot are not established. The in-app console currently exposes text output; the Kenran Butō path does not yet have a complete guest framebuffer and input pipeline.

The broader Windows and game-launch planner still contains orchestration scaffolding for dynamic translators, Windows compatibility, graphics translation, and host services; those adapters are not made available merely by the planner. The Windows PE parser is metadata inspection, not a Windows x64-to-ARM64 translator or Windows kernel. QEMU/UTM remains the full-system route under a separate licensing/build gate; Bochs is only a candidate for further iOS porting work. No current-main IPA, physical-device guest boot, production 3D GPU translation, Box64/FEXCore execution environment, Wine/Proton, Windows API layer, or functional guest networking/input path is verified. Android selection remains a UI experiment. Compatibility with arbitrary games or anti-cheat systems is not promised.

### To build from source

- A Mac running a compatible version of Xcode.
- XcodeGen, installable with Homebrew: `brew install xcodegen`.
- Git and an iPhone/iPad, Apple TV, or Apple Vision Pro simulator for testing.
- Physical-device installation requires appropriate signing and provisioning.

The project currently declares IOS 16 ~ IOS 27, tvOS 17, and visionOS 1.0 deployment targets. Confirm the current project settings and CI logs for exact SDK compatibility.

### Installation notes

- **Unsigned IPA:** use a compatible signer and follow that tool's installation instructions.
- **AltStore source:** add `https://akatsubaki-emu.github.io/AltSource.json` in a compatible app.
- **Troubleshooting:** include your device/OS version and the relevant build or crash log when reporting an issue.
- **File access:** iOS file-picker access and persistent bookmark access are different; a selected file may not remain accessible if its security-scoped bookmark cannot be created or reopened.

## Automatic JIT activation

Akatsubaki can orchestrate JIT acquisition for its QEMU VM and Kenran Butō AOT path on supported physical iOS devices through LocalDevVPN and StikDebug. This sideload/developer workflow requires a valid `get-task-allow` entitlement. See [Automatic JIT activation](docs/JIT_ACTIVATION.md) for setup, lifecycle, failure handling and validation.

## Building

Generate the Xcode project:

```sh
brew install xcodegen
bash scripts/prepare-app-icons.sh
xcodegen generate --spec project.yml
```

Open `iSteam.xcodeproj` in Xcode and choose a scheme. The legacy Xcode project, scheme, executable and IPA filenames are retained for compatibility; the installed app is branded **Akatsubaki Emu**:

- `iSteam` — iOS main build.
- `iSteamNightly` — iOS nightly build.
- `iSteamTV` — tvOS prototype.
- `iSteamVision` — visionOS app.

For hosted builds, use the [Build & Release workflow](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/actions/workflows/release.yml).

## Build and release channels

- **Push to `main`:** starts the Nightly channel.
- **Scheduled workflow:** runs daily at 02:00 UTC.
- **Manual GitHub Actions run:** choose **Nightly** or **Main**.
- **Release assets:** iOS, tvOS, and visionOS IPAs, each with a SHA-256 checksum.

Official AltStore/PAL manifests are refreshed from published app releases by the [website repository's GitHub Actions updater](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu.github.io/blob/main/.github/workflows/update-xthrx-alt-source.yml). Builds are unsigned prototypes. ZIP and checksum validation verify packaging integrity only, not installability, runtime behavior, or guest OS compatibility.

More details: [Installation](INSTALL.md) · [Release workflow](docs/RELEASES.md) · [tvOS roadmap](docs/TVOS.md).

## Contributing

Bug reports, documentation improvements, and focused pull requests are welcome. Please read [contributing.md](CONTRIBUTING.md) before submitting changes.

## Documentation

**[Open the official Akatsubaki Emu wiki](https://akatsubaki-emu.github.io/docs/)** — searchable, mobile-friendly documentation with a navigable sidebar.

- [Installation guide](https://akatsubaki-emu.github.io/docs/installation)
- [Contributing guide](https://akatsubaki-emu.github.io/docs/contributing)
- [Kenran Butō hybrid runtime architecture](https://akatsubaki-emu.github.io/docs/hybrid-runtime-architecture)
- [Host-device bridge](https://akatsubaki-emu.github.io/docs/host-device-bridge)
- [QEMU iOS runtime build workflow](https://akatsubaki-emu.github.io/docs/qemu-build-workflow)
- [Automatic JIT activation](https://akatsubaki-emu.github.io/docs/jit-activation)
- [iOS memory entitlements](https://akatsubaki-emu.github.io/docs/ios-entitlements)
- [First playable iOS acceptance and remaining feature backlog](docs/FIRST_PLAYABLE_IOS_ACCEPTANCE.md)
- [tvOS status and roadmap](https://akatsubaki-emu.github.io/docs/tvos)
- [DroidDeck feature-port plan](https://akatsubaki-emu.github.io/docs/droiddeck-port-plan)
- [DroidDeck port status](https://akatsubaki-emu.github.io/docs/droiddeck-port-status)
- [Windows x64 to ARM64 static translation](https://akatsubaki-emu.github.io/docs/windows-arm64-static-translation)
- [Build and release channels](https://akatsubaki-emu.github.io/docs/releases)
- [GitHub Actions and GitLab synchronization](https://akatsubaki-emu.github.io/docs/git-sync)
- [Third-party notices](https://akatsubaki-emu.github.io/docs/third-party-notices)

The Markdown source remains in this repository for version control and review; the published wiki is the primary reader-facing documentation.

## Credits and technical references

These projects are research references; listing them does not mean their code is bundled here or that their maintainers endorse Akatsubaki Emu.

- [QEMU](https://www.qemu.org/) — full-system emulation reference.
- [Box64](https://github.com/ptitSeb/box64) — x86-64 user-mode emulation reference.
- [FEX-Emu](https://github.com/FEX-Emu/FEX) — x86-64 Linux user-mode translation reference.
- [Wine](https://www.winehq.org/) and [Proton](https://github.com/ValveSoftware/Proton) — Windows user-mode compatibility references.
- [StikDebug](https://github.com/StephenDev0/StikDebug) — JIT-related iOS development reference.
- [LiveContainer](https://github.com/LiveContainer/LiveContainer) and [LiveExec32](https://github.com/LiveContainer/LiveExec32) — iOS app-container and binary-execution research reference.
- [MeloNX](https://github.com/AzureDominus/melonx) — iOS emulator UI and performance reference.
- [SharpEmu](https://github.com/sharpemu/sharpemu) — emulator architecture research reference.
- [SideStore](https://sidestore.io/) — iOS signing and installation reference.
- [xthrx](https://github.com/xthrx-chu) - main project maintainer and developer

Third-party projects retain their own licenses and copyrights. Review upstream licenses and notices before redistributing code. No endorsement is implied.

## License and disclaimer

Akatsubaki Emu project-authored source files are licensed under the **GNU General Public License version 3 or (at your option) any later version (GPL-3.0-or-later)**. File-level scope and exceptions are recorded in [`.reuse/dep5`](.reuse/dep5); see [LICENSE](LICENSE). Third-party files retain their original licences.

## Third-party licensing: UTM and QEMU

The GPL-3.0-or-later grant applies only to project-authored files listed in `.reuse/dep5`. Files with upstream provenance retain their original or separately identified terms; this repository-wide notice does not relicense third-party components.

The full-system QEMU runtime is built from UTM pinned at commit [`3d4b8d8cb1ce93a8b1a9610695c12487685f0c15`](https://github.com/utmapp/UTM/commit/3d4b8d8cb1ce93a8b1a9610695c12487685f0c15) (UTM 5.0.9). At that revision, UTM's repository-level `LICENSE` is Apache License 2.0. That notice applies to UTM-authored material covered by it; it is not a blanket licence for the QEMU fork or every dependency in UTM's app archive. The pinned UTM `patches/sources` selects QEMU `v10.0.12-utm`. QEMU's project-level licensing is GPLv2 with file-level exceptions: some files are GPL-2.0-only, while other files and dependencies may carry different terms. Do not assume one licence applies to every file.

The runtime packagers extract QEMU's dynamic library/framework, its dependency frameworks, and firmware/data from UTM's iOS archives. They do not bundle UTM's Swift UI wrapper. Akatsubaki loads QEMU in-process through `QEMUNativeRuntime`; a separate framework or dynamic-library boundary is not a separate process and does not, by itself, settle whether the distributed app and runtime form one combined work.

Apache-2.0 is generally compatible with GPL-3.0-or-later, so the UTM-derived portions are no longer the same GPLv2 compatibility obstacle. However, QEMU's project-level licence is GPLv2 with file-level exceptions: any GPL-2.0-only files incorporated into the combined iOS app/runtime remain incompatible with GPL-3.0-or-later terms. Files explicitly marked GPL-2.0-or-later may be used under GPLv3; permissively licensed QEMU files retain their own notices. The exact QEMU source/object/dependency closure still needs to be inventoried. `iSteam/QEMUNativeBridge.c` is identified in `.reuse/dep5` as containing both Apache-2.0 UTM-derived material and GPL-3.0-or-later project-authored changes. Obtain qualified review of the exact combined distribution before approval.

QEMU runtime artifact upload and QEMU-enabled IPA publication remain blocked pending that review. CI compilation or internal validation is not approval to redistribute. Do not set `QEMU_GPL_COMPATIBILITY_REVIEW_APPROVED` to `true` until a qualified file-level and combined-work review approves the exact build and distribution model. Preserve corresponding source, local patches/modifications, copyright notices, and licence texts as required by the applicable licences. App Store distribution terms require separate review; sideloading does not remove GPL obligations.

See [third-party notices](THIRD_PARTY_NOTICES.md) and the [QEMU build/licensing notes](docs/QEMU_BUILD_WORKFLOW.md). This is an engineering summary, not legal advice.

Akatsubaki Emu is not affiliated with, endorsed by, or sponsored by Valve Corporation. Steam is a trademark of Valve Corporation. No particular game or operating system is guaranteed to run. AI assistants, including ChatGPT and Claude, have been used as development aids; all changes are still being reviewed and tested by maintainers.

## Repository synchronization

GitHub is the canonical source repository: [Akatsubaki-Emu/Akatsubaki-Emu](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu). GitLab at [chantinlongxthrx/I-steam](https://gitlab.com/chantinlongxthrx/I-steam) is the downstream mirror. **All repository CI, regression tests, Apple-platform builds, QEMU/UTM runtime builds, and releases run through GitHub Actions.** The `validate-repository.yml` workflow runs the Python source-contract suite, native C/C++ regression harnesses, and standalone Swift runtime tests; `validate-ios-build.yml`, `build-qemu-runtime.yml`, and `release.yml` handle Apple-platform compilation, QEMU runtime packaging, and releases. No GitLab CI configuration is maintained. The retained GitHub-to-GitLab synchronization workflow propagates canonical commits to the mirror; external mirror settings are unchanged. The website repository separately updates the AltStore/PAL feed from published releases. See [`docs/GIT_SYNC.md`](docs/GIT_SYNC.md) for synchronization details and cautions.


## QEMU runtime build workflow

See [QEMU_BUILD_WORKFLOW.md](docs/QEMU_BUILD_WORKFLOW.md) for the UTM/QEMU iOS build patching, early link verification, regression tests, cache behavior, and failure diagnosis.
