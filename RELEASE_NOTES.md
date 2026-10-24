# WinLauncher 1.2.3

This patch fixes Minecraft setup, sign-in recovery, and launching Minecraft
bootstrapper files directly from Finder.

## Fixed

- Accepts Microsoft's compact JWE ticket at the content-license boundary while
  leaving the saved Xbox and Store sign-in unchanged.
- Converts rejected, missing, or malformed license responses into controlled
  setup errors instead of terminating the account helper.
- Detects whether Microsoft account setup previously completed and shows Set Up,
  Repair, or Play instead of offering Play before the account is ready.
- Adds Repair Microsoft Sign-In. It clears only WinLauncher's saved Microsoft
  session, opens sign-in again, and keeps the downloaded game, worlds, and other
  local Minecraft files.
- Routes Minecraft-named `.exe` files opened from Finder to Xbox Games Support
  even while the Windows engine is still starting.
- Adds Run as Regular Windows App for users who want to bypass Xbox Games
  Support and launch the selected bootstrapper through the normal Wine path.
- Keeps the live setup progress, foreground Microsoft sign-in window, retry,
  and Stop Setup controls introduced in 1.2.2.
- Rebuilds and checksum-binds the separate GPL account helper and its exact
  corresponding source package.
- Fixes the Xcode packaging dependency so a changed Xbox setup worker is always
  copied into release builds.

## Requirements

- Apple Silicon Mac
- macOS 15 or later
- Rosetta 2
- Internet connection for first sign-in and game download
- A Microsoft account that owns Minecraft for Windows

The DMG uses local ad-hoc signing for preview testing. Public distribution still
needs a Developer ID signature and Apple notarization.
