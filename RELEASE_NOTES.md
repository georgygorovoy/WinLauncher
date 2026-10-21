# WinLauncher 1.2.0

This release candidate adds the first native Xbox Games Support path for
Minecraft for Windows.

## Highlights

- Recognizes `MinecraftInstaller.exe`, `MinecraftLauncher.exe`, and `Minecraft.exe` automatically.
- Opens Xbox Games Support inside WinLauncher instead of sending the user to GitHub.
- Uses a separate pinned GPL helper for Microsoft sign-in and ownership verification.
- Stores Microsoft account tokens in macOS Keychain and refreshes them through Xbox services.
- Downloads and verifies the official Minecraft for Windows package owned by the signed-in account.
- Verifies the embedded helper against a fixed SHA-256 digest before execution.
- Includes GPL notices and exact corresponding-source materials for the helper build.
- Includes the verified license set and component/source inventory for the frozen Python worker.
- Includes a pinned WineGDK 11.8 and DXMT 0.80 player runtime built from source.
- Automatically prepares a dedicated Xbox Games environment and launches Minecraft for Windows.
- Installs the required Microsoft GameInput component after verifying its official payload.
- Includes a source-built WinRT file-picker bridge and verifies it before changing the environment.
- Adds an Xbox Games section to Settings and diagnostics.
- Retains Windows EXE/MSI, Android APK, Finder integration, WineForge and shared-environment support from 1.1.

## Preview limitations

Minecraft launch is implemented and has passed a local Apple Silicon launch test.
This is still preview support: game updates, multiplayer, controllers, world
import/export, and clean-machine installs need wider testing before a stable claim.

## Requirements

- Apple Silicon Mac
- macOS 15 or later for Minecraft for Windows support
- Rosetta 2 for Minecraft for Windows support
- Internet connection for Windows Support, Android Support, or Xbox sign-in/download

The DMG uses local ad-hoc signing for testing. Public distribution should use a
Developer ID signature and Apple notarization.
