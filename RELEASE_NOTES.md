# WinLauncher 1.3.0

- Checks installed Windows Steam games every 10 seconds, including while Steam
  is open. A red warning on the Steam card and in Settings explains when the
  launch cache needs repair or the running Steam session has already failed to
  start a Windows executable. The warning clears after a verified healthy
  launch route; cache writes still wait until Steam is closed.
- Adds a complete Russian translation of WinLauncher screens, settings, guides,
  status messages, and errors. macOS selects it when Russian is the preferred
  language; English remains the default for other languages.
- Keeps the user's Steam Windows-download setting across WinLauncher restarts.
  Previously, startup cleared the setting even after the user enabled it.
- Opens on a Store screen with combined live Steam and GOG game results,
  search, store filters, sorting, platform information, and official game links.
- Balances Steam and GOG recommendations, highlights confirmed free Steam games,
  and offers A–Z, free, low-price paid, high-price and popular views. A–Z is the
  default; store sorting is removed.
- Adds an info icon to the Android tab.
- Offers an Install in Steam action for supported results when Steam is
  installed; Steam still handles ownership and the actual download.
- Adds direct search links for Epic Games Store and Ubisoft Store. Their games
  are not included in the combined results yet.
- Moves F-Droid to a separate Android tab and installed apps to Profile.
- Profile shows installed launchers, detected Windows Steam games, and launches
  made through WinLauncher.

# WinLauncher 1.2.11

- The Ubisoft Connect featured card now detects the installed launcher and opens
  it directly instead of showing a download link.
- Adds Epic Games Store with its official macOS download page and detection of
  an already installed Mac or Windows launcher.
- Adds F-Droid to the home screen and Android settings. WinLauncher verifies a
  pinned official APK before installing it in the Android emulator.
- Reopens Android apps already present in the emulator without reinstalling
  their APK, preserving updates made through F-Droid.
- Expands in-app explanations of WineForge, DXMT, Steam, Android/ADB, F-Droid,
  Minecraft, file access, and diagnostics.

# WinLauncher 1.2.10

- Adds info icons on the Steam card, Windows game list, and Steam settings.
- Explains the download steps, Steam restarts, game folder, cache repair, and
  WineForge launch path in a short in-app guide.

# WinLauncher 1.2.9

- Retires WinLauncher's old global Windows platform override on startup, after
  Steam closes if needed, so Steam prefers native macOS builds again.
- Leaves games advertised for macOS untouched when repairing cached Steam Play
  launch entries.
- Keeps an explicit Windows download switch for Windows-only games; this Steam
  setting affects the whole library and requires a Steam restart.
- Continues checking installed Windows games and repairing their launch entries
  after Steam closes, without requiring a companion application.

# WinLauncher 1.2.8

- Prepared detection of a configured Steam Play tool and kept macOS game
  metadata unchanged during legacy launch repair.

# WinLauncher 1.2.7

- Checks Steam's cached Windows game launch entries in the background when
  WinLauncher opens and every 20 seconds while it is running.
- Waits until Steam closes before repairing changed entries, backs up the cache,
  and verifies the rewritten records and checksums.
- Restores the WineForge launch script if it is missing or outdated.
- Fixes the direct game launch command used by WinLauncher cards.

# WinLauncher 1.2.6

- Shows installed Steam Windows games in the WinLauncher Apps view.
- Launches a detected game through WineForge with its game folder as the Windows
  working directory, so adjacent assets are available.
- Adds a Steam settings page for enabling Windows downloads and refreshing games.
- Moves file import to the plus button and adds featured application shortcuts.

Steam's own Play button may still report OS Error 0 because it does not call
WinLauncher. Start downloaded Windows games from the WinLauncher Apps view.

# WinLauncher 1.2.5

This patch removes the repeated macOS password prompts shown during Minecraft
for Windows setup and launch.

## Fixed

- Stores the Microsoft session in WinLauncher’s private XboxSupport data folder
  instead of macOS Keychain, so an ad-hoc-signed helper update does not trigger
  repeated Keychain authorization dialogs.
- Creates the account folder with mode 0700 and the account file with mode 0600,
  rejects symbolic links and files owned by another user, and keeps credentials
  out of logs.
- Keeps Repair Microsoft Sign-In working by securely recreating the private
  account file.
- Merges duplicate legacy `Minecraft.exe` library cards into one Minecraft for
  Windows card and routes it through Xbox Games Support instead of ordinary Wine.
- Keeps the explicit “Run as Regular Windows App” action available as a separate
  opt-in path for the original bootstrapper.
- Updates the bundled helper checksum and complete GPL corresponding source for
  the exact helper shipped in this release.

Existing users will sign in to Microsoft once after installing 1.2.5 because
WinLauncher intentionally does not read or migrate the old Keychain entry.

## Requirements

- Apple Silicon Mac
- macOS 15 or later
- Rosetta 2
- Internet connection for first sign-in and game download
- A Microsoft account that owns Minecraft for Windows

The DMG uses local ad-hoc signing for preview testing. Public distribution still
needs a Developer ID signature and Apple notarization.
