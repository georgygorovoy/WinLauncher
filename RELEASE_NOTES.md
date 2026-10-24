# WinLauncher 1.2.4

This patch makes the initial Minecraft for Windows setup work on a clean Mac
with no existing XboxSupport data.

## Fixed

- Keeps Set Up and Download enabled when XboxSupport is completely empty.
- Recognizes the current bundled Microsoft account helper using its correct
  SHA-256 checksum.
- Accepts the verified bundled helper when WinLauncher is installed system-wide
  and the app files are owned by macOS rather than the current user.
- Adds a release-build checksum gate so a mismatched helper cannot be packaged
  again.
- Includes the Microsoft sign-in repair, compact JWE license handling, Finder
  routing, and regular Wine launch option introduced in 1.2.3.

## Requirements

- Apple Silicon Mac
- macOS 15 or later
- Rosetta 2
- Internet connection for first sign-in and game download
- A Microsoft account that owns Minecraft for Windows

The DMG uses local ad-hoc signing for preview testing. Public distribution still
needs a Developer ID signature and Apple notarization.
