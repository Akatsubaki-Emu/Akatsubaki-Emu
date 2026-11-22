# Akatsubaki Emu

> DISCLAIMER
>
> **please read this before using this application**
> **Important Notice Regarding Akatsubaki Emu’s current development stage**
>
> Akatsubaki Emu is still in development and is highly unstable, which means **you may lose your data or get banned**.
>
> Furthermore, please note that we do not provide any support for issues of these development builds. and **we will not take responsibility for any possessions lost whilst using this application**. please use this application at your own risk
> **by using this application you agree to all the notices above**

> Akatsubaki Emu is an experimental iOS, tvOS, and visionOS game-library and guest-runtime project.

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://makeapullrequest.com)
[![Akatsubaki Emu Build & Release](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/actions/workflows/release.yml/badge.svg)](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/actions/workflows/release.yml)

[**GitHub**](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu) · [**All releases**](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/releases) · [**Nightly builds**](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu/releases/tag/nightly) · [**GitLab mirror**](https://gitlab.com/chantinlongxthrx/I-steam) · [**AltStore source**](https://altdirect.app/?url=https://akatsubaki-emu.github.io/AltSource.json)

![Alt](https://repobeats.axiom.co/api/embed/60c92ea5e53d1048f89bf703d5444e243a2c5244.svg "Repobeats analytics image")

**Akatsubaki Emu** is a Steam-oriented game library and experimental guest-runtime project for Apple platforms.

> [!WARNING]
> **Akatsubaki Emu is experimental and is not yet a working PC emulator.** It does not currently boot arbitrary Windows/Linux images through a fully integrated emulator or promise that Steam games will run. The tvOS interface is a prototype, not a game launcher. CI IPAs are unsigned; installation requires a compatible signing method, and packaging success does not prove the app works on a device.

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

## Features and project status

### iOS app — Akatsubaki Emu

- Experimental library and import flows for executable and operating-system files.
- Local VM/session configuration and last-session metadata.
- File selection and shared-directory handling.
- Bounded, read-only metadata inspection for Windows PE and Linux ELF files.
- Guest-memory and block-device prototypes.
- Early display, Metal presentation, frame-pacing, keyboard, and controller support.
- Research into app-container and binary-execution approaches used by projects such as LiveContainer.
- Native DroidDeck-inspired library backup/restore, per-game profile defaults, artwork caching, local compatibility records, and runtime component integrity verification.

These are works in progress. Importing a file or inspecting its metadata does not execute it, and a storage prototype is not a complete virtual storage controller. JIT behavior depends on iOS version, device, signing, entitlements, and supported tooling. The current VM launch path requests JIT through LocalDevVPN and StikDebug before starting QEMU; those helper apps and a compatible signature are still required. Akatsubaki Emu does not yet embed the StikJIT helper extension.

### tvOS app

The tvOS target is an early Siri Remote-friendly interface preview. Its Launch session, Steam Store, and Settings actions currently display explanatory notices. It does **not** boot an operating system or launch games.

### Runtime and native helpers

The hybrid execution architecture is named **Kenran Butō (絢爛舞踏)**. Its planned components are Kenran Butō AOT (static x86-64 → ARM64 translation), Kenran Butō Cache (translated-code cache), Kenran Butō Router (backend selection and fallback), Kenran Butō Runtime (execution orchestration), and Kenran Butō Graphics (graphics translation). These names describe architectural responsibilities, not a claim that the corresponding engines are complete or integrated.

The repository contains exploratory components for guest memory, image/file inspection, storage, display, and host-device services. The Windows game-launch boundary now invokes the **Kenran Butō** hybrid execution planner that composes cached static translation, one selected dynamic translator, diagnostic fallback, Windows compatibility, independent graphics translation, and host services. QEMU remains the full-system route; a32rt and native ARM64 remain architecture-specific paths. This is still orchestration scaffolding: the planner does not make missing backends available, and launch remains blocked until concrete runtime adapters and required ABI layers are installed. The Windows PE parser is not yet a Windows x64-to-ARM64 instruction translator. The QEMU/UTM runtime build is being developed in `.github/workflows/build-qemu-runtime.yml`; no verified runtime artifact or physical-device guest boot is established here. A working full-system emulator, Box64 execution environment, Wine/Proton, Windows API compatibility layer, functional guest networking/input path, and production-ready 3D GPU translation are not yet integrated. Android selection is a UI experiment. Compatibility with arbitrary games or anti-cheat systems is not promised.

The Android DroidDeck source is not a direct iOS runtime: FEX/Proton, Turnip, Gamescope, Linux package managers, and Android-specific device access need separate Apple-platform implementations. See [DroidDeck feature-port inventory](docs/DROIDDECK_PORT_PLAN.md) and [DroidDeck port status](docs/DROIDDECK_PORT_STATUS.md).

## Requirements

### To build from source

- A Mac running a compatible version of Xcode.
- XcodeGen, installable with Homebrew: `brew install xcodegen`.
- Git and an iPhone/iPad, Apple TV, or Apple Vision Pro simulator for testing.
- Physical-device installation requires appropriate signing and provisioning.

The project currently declares iOS 16, tvOS 17, and visionOS 1.0 deployment targets. Confirm the current project settings and CI logs for exact SDK compatibility.

### Installation notes

- **Unsigned IPA:** use a compatible signer and follow that tool's installation instructions.
- **AltStore source:** add `https://akatsubaki-emu.github.io/AltSource.json` in a compatible app.
- **Troubleshooting:** include your device/OS version and the relevant build or crash log when reporting an issue.
- **File access:** iOS file-picker access and persistent bookmark access are different; a selected file may not remain accessible if its security-scoped bookmark cannot be created or reopened.

## Building

Generate the Xcode project:

```sh
brew install xcodegen
xcodegen generate --spec project.yml
```

Open `iSteam.xcodeproj` in Xcode and choose a scheme:

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
- **Older releases:** the workflow is configured not to automatically delete old releases.

Official AltStore/PAL manifests are refreshed from published app releases by the [website repository's GitHub Actions updater](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu.github.io/blob/main/.github/workflows/update-xthrx-alt-source.yml). Builds are unsigned prototypes. ZIP and checksum validation verify packaging integrity only, not installability, runtime behavior, or guest OS compatibility.

More details: [Installation](INSTALL.md) · [Release workflow](docs/RELEASES.md) · [tvOS roadmap](docs/TVOS.md).

## Contributing

Bug reports, documentation improvements, and focused pull requests are welcome. Please read the [contributing.md](CONTRIBUTING.md) before submitting changes.

## Documentation

- [Installation guide](INSTALL.md)
- [Contribution guide](CONTRIBUTING.md)
- [Build and release workflow](docs/RELEASES.md)
- [tvOS status and roadmap](docs/TVOS.md)
- [Host-device bridge](docs/HOST_DEVICE_BRIDGE.md)
- [JIT activation and limitations](docs/JIT.md)
- [Hybrid runtime architecture and roadmap](docs/HYBRID_RUNTIME_ARCHITECTURE.md)
- [QEMU runtime build and failure diagnostics](docs/QEMU_BUILD_WORKFLOW.md)
- [DroidDeck feature-port plan](docs/DROIDDECK_PORT_PLAN.md)
- [DroidDeck port status](docs/DROIDDECK_PORT_STATUS.md)
- Portable library transfer, per-game profile defaults, and feature readiness services: `src/Steam/DroidDeckFeatureServices.swift`
- Artwork cache: `src/Steam/GameArtworkStore.swift`
- Compatibility records: `src/Windows/GameCompatibilityDatabase.swift`
- Runtime manifest verification: `src/Runtime/RuntimeComponentManifest.swift`

## Credits and technical references

These projects are research references; listing them does not mean their code is bundled here or that their maintainers endorse Akatsubaki Emu.

- [QEMU](https://www.qemu.org/) — full-system emulation reference.
- [Box64](https://github.com/ptitSeb/box64) — x86-64 user-mode emulation reference.
- [FEX-Emu](https://github.com/FEX-Emu/FEX) — x86-64 Linux user-mode translation reference.
- [Wine](https://www.winehq.org/) and [Proton](https://github.com/ValveSoftware/Proton) — Windows user-mode compatibility references.
- [StikDebug](https://github.com/StikDebug/StikDebug) and [StikJIT](https://github.com/StikDebug/StikJIT) — JIT activation and universal breakpoint-protocol references.
- [LocalDevVPN](https://github.com/jkcoxson/LocalDevVPN) — local RSD tunnel and URL activation reference.
- [LiveContainer](https://github.com/LiveContainer/LiveContainer) and [LiveExec32](https://github.com/LiveContainer/LiveExec32) — iOS app-container and binary-execution research reference.
- [MeloNX](https://github.com/AzureDominus/melonx) — iOS emulator UI and performance reference.
- [SharpEmu](https://github.com/sharpemu/sharpemu) — emulator architecture research reference.
- [SideStore](https://sidestore.io/) — iOS signing and installation reference.
- [xthrx](https://github.com/xthrx-chu) - main project maintainer and developer

Third-party projects retain their own licenses and copyrights. Review upstream licenses and notices before redistributing code. No endorsement is implied.

## License and disclaimer

The Akatsubaki Emu project is licensed under the **GNU General Public License v3.0 (GPL-3.0)**. See [LICENSE](LICENSE).

Akatsubaki Emu is not affiliated with, endorsed by, or sponsored by Valve Corporation. Steam is a trademark of Valve Corporation. No particular game or operating system is guaranteed to run. AI assistants, including ChatGPT and Claude, have been used as development aids; all changes are still being reviewed and tested by maintainers.

## Repository synchronization

GitHub is the canonical source repository: [Akatsubaki-Emu/Akatsubaki-Emu](https://github.com/Akatsubaki-Emu/Akatsubaki-Emu). GitLab at [chantinlongxthrx/I-steam](https://gitlab.com/chantinlongxthrx/I-steam) is the mirror. The configured GitLab-to-GitHub push mirror and the existing GitHub-to-GitLab synchronization are retained; avoid making competing edits on both hosts and check the latest commit before changing either side. GitLab CI (`.gitlab-ci.yml`) runs supplemental Swift runtime, native guest-memory, and Python source-contract/regression tests. GitHub Actions remains responsible for Apple-platform simulator builds, QEMU/UTM runtime builds, releases, and the website's AltStore/PAL publishing workflow. GitLab CI jobs are currently blocked before execution by the project's runner quota; see the latest pipeline before treating tests as passed. See [`docs/GIT_SYNC.md`](docs/GIT_SYNC.md) for synchronization details and cautions.


## QEMU runtime build workflow

See [QEMU_BUILD_WORKFLOW.md](docs/QEMU_BUILD_WORKFLOW.md) for the UTM/QEMU iOS build patching, early link verification, regression tests, cache behavior, and failure diagnosis.
