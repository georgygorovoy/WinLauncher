# WinLauncher 1.2.1

This patch fixes Xbox Games Support on supported Macs where choosing Download
appeared to do nothing and no Microsoft sign-in window opened.

## Fixed

- Replaces the host-built PyInstaller worker that could require symbols from a
  newer macOS than the user was running.
- Uses a checksum-pinned portable CPython 3.13.17 runtime built for macOS 11 or
  later; WinLauncher itself continues to require macOS 15 or later.
- Starts Microsoft sign-in without requiring Python, Homebrew, Xcode, or other
  developer tools on the user's Mac.
- Keeps the worker isolated from user-installed Python packages.
- Retains the complete CPython and python-build-standalone license notices in
  the packaged runtime.

## Included from 1.2.0

- Native Minecraft installer recognition and Xbox Games Support.
- Microsoft sign-in, ownership verification, Keychain session storage, and the
  official owned-game download.
- Pinned WineGDK 11.8 and DXMT 0.80 setup and launch support.
- Windows EXE/MSI, Android APK, Finder integration, managed WineForge, and the
  shared Windows Environment.

## Requirements

- Apple Silicon Mac
- macOS 15 or later for Minecraft for Windows support
- Rosetta 2 for Minecraft for Windows support
- Internet connection for first sign-in and game download

The DMG uses local ad-hoc signing for preview testing. Public distribution still
needs a Developer ID signature and Apple notarization.
