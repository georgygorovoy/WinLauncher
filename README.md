# WinLauncher

Native macOS application that runs Windows applications through independently updatable Wine engines and launches Android APKs through an installed Android Emulator.

**Current release candidate: WinLauncher 1.2.2.** Windows support automatically installs an integrity-checked WineForge 11.18 engine. Android support can install a minimal, checksum-verified runtime without Android Studio or Java. Version 1.2 adds Xbox Games Support for Minecraft for Windows: a separately built GPL worker handles Microsoft sign-in, ownership verification, the official owned-game download, WineGDK/DXMT setup, and launch. Version 1.2.2 uses the portable worker added in 1.2.1, displays setup progress live, and brings the separate Microsoft sign-in window to the front on macOS Sequoia.

The first engineering gate is deliberately small: install current Ubisoft Connect on Apple Silicon and display its responsive login UI without CrossOver binaries or D3DMetal. Product implementation follows that result.

The product default is one shared Windows Environment for all imported applications. This mirrors a normal Windows PC: installers, launchers and games can discover one another. Users can select or create another environment globally or for an individual application when compatibility or isolation requires it.

- [Ecosystem research and licensing](docs/RESEARCH.md)
- [Proposed architecture](docs/ARCHITECTURE.md)
- [Ubisoft Connect proof-of-concept specification](docs/UBISOFT-POC.md)
- [Implementation phases and blockers](docs/IMPLEMENTATION-PLAN.md)

Recommended starting point: a pinned upstream Wine 11 development build with new WoW64, followed by a minimal, auditable patch build only if the baseline fails. Evaluate DXMT independently from launcher rendering. Treat Rosetta as an Apple-provided host prerequisite, not an open-source component we redistribute.

## Phase 0 laboratory

The repository now includes an initial command-line laboratory. It requires an existing Wine engine and an installer supplied explicitly by the tester; it performs no downloads.

```sh
swift run winlab doctor --engine "/path/to/Wine.app"
swift run winlab init --engine "/path/to/Wine.app" --environment "/path/to/disposable/ubisoft-test"
swift run winlab installer --engine "/path/to/Wine.app" \
  --environment "/path/to/disposable/ubisoft-test" \
  --exe "/path/to/UbisoftConnectInstaller.exe"
```

The same `--environment` path is intentionally reused for Steam, Ubisoft Connect and Trackmania. Each run writes a JSON manifest and combined process log under that laboratory environment. A Wine prefix is not a macOS security sandbox; use a disposable test account without personal data for compatibility experiments.

Research included direct inspection of Sikarugir's published Configure source. No third-party source or binaries were copied into this repository. Runtime compatibility, binary redistribution compliance, and filesystem confinement remain acceptance gates, not claimed capabilities.

## Native Xcode application

`WinLauncher.xcodeproj` contains the current macOS SwiftUI MVP. Wine is not embedded in the application or disk image. On the first launch of a Windows application, WinLauncher automatically downloads pinned WineForge 0.6.0.5, verifies its SHA-256 digest, mounts the image read-only, installs it transactionally, validates the executable and required runtime files, and stores it separately under Application Support. A different Wine app or executable can still be selected when Advanced Mode is enabled.

Implemented in the MVP:

- native SwiftUI library and drag-and-drop for `.exe` and `.msi` files;
- one shared Default Windows Environment;
- controlled import of selected executables into that environment instead of a host-root Wine drive;
- automatic managed WineForge 11.18 installation, plus external Wine discovery;
- automatic DXMT routing and WineForge launcher fixes for Chromium-based launchers;
- prefix initialization, direct process execution, bounded logs and diagnostic report;
- basic installed-application discovery, library persistence and per-application launch history.
- Windows application artwork with Wine-extracted icons and polished generated fallbacks;
- Finder integration for opening `.exe` and `.msi` files directly;
- practical graphics, environment, compatibility and diagnostics settings.
- automatic, checksum-verified Wine Mono installation when a managed .NET executable is opened.
- preflight detection for Microsoft Store/WinRT bootstrap installers, with a clear compatible path instead of a Wine crash; Minecraft routes only to an open-source Windows-entitlement Bedrock runtime and never to a Google Play launcher.
- Android `.apk` import, drag-and-drop, Finder file association and one-click relaunch from the same library;
- automatic installation or discovery and startup of an Apple Silicon Android Emulator device;
- automatic APK package detection, `adb` installation and launcher activity startup.
- native Minecraft installer detection and Microsoft sign-in through a pinned, separately executed Xodus helper;
- SHA-256 verification of the helper, macOS Keychain token storage and corresponding GPL source materials;
- a bundled, replaceable WineGDK 11.8 and DXMT 0.80 player runtime for one-click Minecraft for Windows launch;
- a dedicated Xbox Games environment, automatic GameInput setup, and source-built WinRT file-picker compatibility.

Android Studio is not required. After the user accepts Google's Android SDK License Agreement, WinLauncher downloads `adb`, the native Apple Silicon emulator, and one Android 11 ARM64 AOSP image directly from Google's SDK repository. The download is about 985 MB and uses about 2.5–3 GB after installation. Disk images are stored sparsely and emulator snapshots stay disabled to avoid wasting space. APKs that require a physical device, a different CPU ABI, installation from Google Play, or a successful Play Integrity verdict may refuse to run.

Not yet implemented or validated:

- signed engine update catalogs and rollback UI;
- user-selectable graphics modes and remotely updated compatibility profiles;
- robust process-tree supervision and environment repair;
- Steam → Trackmania → Ubisoft launcher-chain validation and broader game compatibility testing;
- Developer ID signing and notarization for public distribution;
- wider Minecraft qualification across clean Macs, game updates, multiplayer, controllers, and world import/export.

Minecraft for Windows support requires macOS 15 or later, Rosetta 2, an Internet connection for initial sign-in, and a Microsoft account that owns the game. The game is downloaded directly for the signed-in owner and is never included in WinLauncher.

See [Xcode setup and run instructions](docs/RUN-XCODE.md). The earlier `WinLauncher-Test.dmg` is an obsolete local experiment and should not be used for further testing.
