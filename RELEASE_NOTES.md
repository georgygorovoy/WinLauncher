# WinLauncher 1.2.2

This patch fixes Microsoft sign-in appearing to do nothing during Minecraft
setup, especially on macOS Sequoia.

## Fixed

- Reads Xbox setup events while setup is running instead of waiting for the
  entire download or game session to finish.
- Brings the separate Microsoft sign-in window to the front when it opens.
- Shows whether WinLauncher is signing in, checking ownership, downloading, or
  preparing Minecraft.
- Adds Stop Setup so an unfinished attempt can be cancelled and retried without
  restarting WinLauncher.
- Shows the installed WinLauncher version in the Minecraft setup window.
- Retains the checksum-pinned portable Python runtime introduced in 1.2.1 for
  compatibility with supported macOS releases.

## Requirements

- Apple Silicon Mac
- macOS 15 or later
- Rosetta 2
- Internet connection for first sign-in and game download
- A Microsoft account that owns Minecraft for Windows

The DMG uses local ad-hoc signing for preview testing. Public distribution still
needs a Developer ID signature and Apple notarization.
