# Ecosystem and feasibility research

Research date: 2026-09-19. Source findings, third-party reports, and proposed experiments are distinguished below. No Windows application was executed during this research.

## Recommendation

Build our own SwiftUI frontend and process orchestration around a pinned, reproducible Wine engine. Start testing with upstream Wine 11.18 source or the verified available WineHQ macOS 11.17 package; do not equate newest source with an available macOS binary. Keep a stable 11.0 control for regression comparison, but prioritize the later development branch for Ubisoft. Use DXMT as the first D3D10/11 game-renderer candidate, with a separately tested launcher-rendering policy. Keep DXVK-macOS plus MoltenVK as an alternative. Exclude D3DMetal from the open-source baseline.

This is the best starting strategy, not a claim that a winning Ubisoft configuration has been established. A production engine version must be selected from measured results.

## Current Wine and macOS packaging

Wine 11.0 completes new WoW64 support, removes the separate `wine64` loader, and improves macOS thread handling. Its advertised NTSync feature is Linux-specific. Engine adapters must discover the actual loader and capabilities rather than assume old wrapper layouts. [Wine 11.0 release notes](https://raw.githubusercontent.com/wine-mirror/wine/wine-11.0/ANNOUNCE.md)

Wine 11.1 explicitly lists a Ubisoft Connect freeze fix, bug 59153. This is evidence to test newer Wine, not proof that the macOS CEF blank-window problem is fixed. [Wine 11.1 notes](https://raw.githubusercontent.com/wine-mirror/wine/wine-11.1/ANNOUNCE.md)

Wine 11.18 source release notes are available. The macOS package listing inspected showed 11.17 dated September 11, including a Vulkan portability-enumeration patch. Record exact source and package revisions separately. [11.18 source notes](https://raw.githubusercontent.com/wine-mirror/wine/wine-11.18/ANNOUNCE.md), [macOS package releases](https://github.com/Gcenx/macOS_Wine_builds/releases)

Gcenx's WineHQ packaging documents x86_64 host builds with i386/x86_64 Windows support. Its current configuration disables OpenGL and enables Vulkan; runtime dependencies include GStreamer and MoltenVK. Thus “WineD3D fallback” must identify its backend and build support. An OpenGL experiment needs an OpenGL-enabled engine; a stock package cannot be assumed to provide it. Bundled Gecko does not replace a launcher's own CEF. [Packaging configuration](https://raw.githubusercontent.com/Gcenx/macOS_Wine_builds/master/README.md)

For distribution, build relocatable engine archives in CI, ship matching source/build recipes and notices, audit every dynamic dependency, and avoid requiring end users to install Homebrew or a system-wide multimedia framework. The upstream package is useful for comparison, not automatically a finished redistributable product engine.

## Sikarugir: implementation and reuse boundary

Use the official GitHub organization. Its README explicitly disavows the similarly named `.com` website and distinguishes LGPL Configure from current Launcher and Creator components. No open-source reuse grant for those latter components was established here. [Official project](https://github.com/Sikarugir-App/Sikarugir)

Inspected source snapshots:

| Repository | Commit | Inspection scope |
|---|---|---|
| Sikarugir distribution | `45e8075853f904b06c65fc2e3c6bed7067241443` | README, component boundaries, file inventory |
| Sikarugir-foss-sources | `4be1b048f8df14b073a6e39e8245bbb52c6a71c0` | LGPL license, Configure controllers, path and engine utilities |

Concrete observations from the published Configure source:

| Area | Observed behavior | Our design consequence |
|---|---|---|
| Layout | Engine, prefix and logs under `Contents/SharedSupport` | Separate immutable engines from mutable app data |
| Construction/init | Delegates `WSS-InstallICE`, `WSS-wineprefixcreate`, `WSS-wineboot` to launcher | Those calls do not reveal current launcher implementation; implement our own lifecycle |
| Engine replacement | Extract archive, replace engine directory, refresh prefix | Stage/verify first; preserve old engine and snapshot prefix |
| Launching | Launcher commands; one utility constructs a temporary batch file | Use explicit executable/argument APIs and Windows quoting rules |
| Detection | Compare before/after runnable-file paths | Add shortcuts, uninstall registry and per-user installations |
| Settings | Plist metadata and registry changes for DPI/Retina | Typed configuration with migrations and capability checks |
| Paths | Falls back to root-mapped `Z:` | Explicit import/access grants; no host-root mapping |

Source references: [controller](https://github.com/Sikarugir-App/Sikarugir-foss-sources/blob/4be1b048f8df14b073a6e39e8245bbb52c6a71c0/Configure/Classes/Controller/WineskinAppDelegate.m), [process utility](https://github.com/Sikarugir-App/Sikarugir-foss-sources/blob/4be1b048f8df14b073a6e39e8245bbb52c6a71c0/Configure/Classes/Model/NSPortManager.m), [engine utility](https://github.com/Sikarugir-App/Sikarugir-foss-sources/blob/4be1b048f8df14b073a6e39e8245bbb52c6a71c0/Configure/Classes/Utilities/NSWineskinEngine.m), [path utility](https://github.com/Sikarugir-App/Sikarugir-foss-sources/blob/4be1b048f8df14b073a6e39e8245bbb52c6a71c0/Configure/Classes/Utilities/NSPathUtilities.m), [settings writer](https://github.com/Sikarugir-App/Sikarugir-foss-sources/blob/4be1b048f8df14b073a6e39e8245bbb52c6a71c0/Configure/Classes/Utilities/NSWineskinPortDataWriter.m).

Current wrapper construction and execution internals cannot be fully inspected from this Configure-only source tree. It also contains shell calls, broad permission changes and quarantine removal that should not become our implementation pattern. No code was reused.

Do not repeat the blanket claim that Sikarugir is limited to Wine 10: its public Wine source repository lists a Wine 11.4 release. That alone does not prove which engine its Creator currently selects or that all published binary assets match this source. [Wine source releases](https://github.com/Sikarugir-App/wine/releases), [separate engine distribution](https://github.com/Sikarugir-App/Engines/releases)

## Graphics choices

| Component | Evidence and license | Recommendation |
|---|---|---|
| DXMT | D3D10/11 to Metal; current license LGPL-2.1-or-later | First accelerated game candidate; not an assumed CEF cure |
| DXVK | D3D to Vulkan; zlib license | Version and required Vulkan features must match actual macOS stack |
| DXVK-macOS | Maintained separately from current upstream DXVK; 1.10.x lineage | Controlled fallback, not interchangeable with latest Linux binaries |
| MoltenVK | Vulkan portability implementation over Metal; Apache-2.0 | Probe extensions and limits; avoid assuming full desktop Vulkan |
| WineD3D | Part of Wine | Conservative baseline, conditional on compiled GL/Vulkan backend |
| D3DMetal | Apple's separately licensed, closed-source runtime | Excluded from this project's open-source proof and default distribution |

[DXMT source](https://github.com/3Shain/dxmt), [current DXMT license](https://raw.githubusercontent.com/3Shain/dxmt/main/LICENSE), [DXMT build requirements](https://raw.githubusercontent.com/3Shain/dxmt/main/docs/DEVELOPMENT.md), [DXVK source](https://github.com/doitsujin/dxvk), [DXVK license](https://raw.githubusercontent.com/doitsujin/dxvk/master/LICENSE), [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS), [MoltenVK](https://github.com/KhronosGroup/MoltenVK), [MoltenVK license](https://raw.githubusercontent.com/KhronosGroup/MoltenVK/main/LICENSE).

DXMT includes both Windows DLLs and a matching host library; its build documentation distinguishes 32-bit PE components from the 64-bit host library. Engine/renderer compatibility is an ABI contract, not merely copying `d3d11.dll`. Track paired versions and test both Windows architectures. [DXMT build guide](https://raw.githubusercontent.com/3Shain/dxmt/main/docs/DEVELOPMENT.md)

GPTK is a collection of porting/evaluation tools, not a synonym for an open-source Wine engine. Reusing legally published Wine changes is different from redistributing Apple's runtime. A free download or another project's bundled copy does not establish our redistribution rights. D3DMetal is unnecessary to the first login-UI experiment. General D3D12 compatibility is outside the initial promise. [Apple GPTK](https://developer.apple.com/games/game-porting-toolkit/), [Sikarugir's component warning and linked runtime terms](https://github.com/Sikarugir-App/Sikarugir#readme)

## Ubisoft Connect, CEF and Steam

**No verified open-source-only Ubisoft login solution was established by this research.** There is concrete evidence for a targeted experiment, not a justified production flag recipe.

The current upstream macOS driver rejects cross-process child-window Metal swapchain acquisition in `macdrv_client_surface_acquire_metal_swapchain`. This is a specific code limitation; whether current Ubisoft actually hits it must be established with logs. [Wine driver source](https://raw.githubusercontent.com/wine-mirror/wine/master/dlls/winemac.drv/window.c)

A DXMT issue reports Steam CEF/ANGLE failing swapchain creation with `EGL_BAD_ALLOC` on Wine 11.5, DXMT 0.74 and an M2. This demonstrates that recent Wine plus DXMT is insufficient for at least that configuration, not that all current versions fail. [DXMT issue 141](https://github.com/3Shain/dxmt/issues/141)

One Steam experiment reports success using CPU rendering and a single CEF process, or an in-process GPU path. Its reported root cause is not independently verified here. Do not transfer flags to Ubisoft without checking child-process command lines; launchers may discard them. Do not adopt executable replacement or update blocking as a shipping solution. [Experiment author's report](https://github.com/wisnuub/Steam-Win-Silicon)

WineForge claims Ubisoft installation/sign-in support and provides a Wine 11.18 source tree. However, its main documented runtime path uses D3DMetal. The inspected snapshot `1da4093ab92106121a515dca76092b485ec6c4fb` still contains the child-window swapchain limitation. Its claims therefore do not establish our no-D3DMetal result; any useful patch needs individual provenance and dependency review. [WineForge](https://github.com/Alien4042x/WineForge), [inspected driver](https://github.com/Alien4042x/WineForge/blob/1da4093ab92106121a515dca76092b485ec6c4fb/dlls/winemac.drv/window.c)

Heroic's Ubisoft guide says macOS requires commercial CrossOver. This is a caution against claiming a solved free configuration, not timeless proof that an updated source-built engine cannot work. [Heroic guide](https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/wiki/How-to-install-Ubisoft-Connect-on-Linux-and-Mac)

Investigate three separate layers: CEF child creation/sandboxing; ANGLE/D3D resource creation and sharing; Wine's presentation of those resources in macOS windows. Authentication/network failures and missing codecs are separate diagnoses. A registry value cannot implement a missing presentation path. No evidence-supported magic registry setting was found. Detailed experiments are specified in [UBISOFT-POC.md](UBISOFT-POC.md).

## Why not build on Whisky?

Whisky's maintainer states that engine updates and app-specific fixes stopped. The stated reasons include lost interest/time and concerns about relying on CodeWeavers without contributing fixes. Its Wine engine will not be upgraded to Wine 8+. This is a maintenance and sustainability warning: an attractive frontend cannot freeze its compatibility layer indefinitely. Budget for upstream work, reproducible builds and regression testing. [Maintainer's notice](https://docs.getwhisky.app/maintenance-notice.html)

## Redistribution and platform boundaries

Wine is LGPL-2.1-or-later; preserve licenses, copyright notices, corresponding source, modifications and build instructions. Audit dependencies independently. DXMT's current LGPL license must not be confused with older licensing information. Using CodeWeavers-authored code that is actually LGPL is permitted under that license; copying proprietary CrossOver code/assets is not. This research does not certify any prebuilt bundle as compliant. [Wine license](https://github.com/wine-mirror/wine/blob/master/LICENSE), [LGPL text](https://github.com/Sikarugir-App/Sikarugir-foss-sources/blob/main/LICENSE)

Rosetta is proprietary Apple software and must remain an OS-provided prerequisite. Apple states general availability through macOS 27 and restricted functionality from macOS 28. Do not promise the x86 engine strategy on macOS 28. A native ARM64/ARM64EC Wine plus CPU-translation path requires independent engineering and validation. [Apple's Rosetta guidance](https://support.apple.com/en-us/102527)

“Only open source” must refer to components we distribute, with explicit exceptions for the macOS/Metal/Rosetta platform and user-installed proprietary Windows applications. If it means no proprietary translation runtime at all, this Rosetta-based recommendation does not satisfy that stronger requirement.

Wine environments separate application state, not hostile code privileges. Removing `Z:` and home symlinks reduces accidental exposure but does not create OS confinement. Production needs an independently tested process/filesystem boundary; until then, use a disposable test account and never advertise sandboxing.

User software, Ubisoft/Steam credentials and game content are not redistributed. Microsoft runtime dependencies require their own terms; Winetricks scripts being open source does not make the downloaded payloads open source. Keep any such installation explicit and outside the strict open-source PoC unless separately approved as a changed scope.
