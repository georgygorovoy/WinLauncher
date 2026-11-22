# Windows downloads in macOS Steam

WinLauncher offers an opt-in **Download Windows versions in Steam** switch in
Settings → Steam. It writes a marked `@sSteamCmdForcePlatformType windows` block
to the installed client's `steam_dev.cfg`. Steam reads this setting at startup,
so the user must quit and reopen Steam before its Library shows Install for
Windows games. WinLauncher removes only its own block when the switch is turned
off and refuses to overwrite a conflicting platform setting.

The override is global: Steam can replace an installed Mac build with the
Windows build when it updates a game. The setting may also interfere with the
client's initial bootstrap or update. WinLauncher scans installed Steam
manifests for Windows games with a root `.exe`. When WinLauncher opens, it
checks the matching launch entries in `appcache/appinfo.vdf`. If Steam is
running, WinLauncher checks the cache and the current Steam session's launch
errors without writing to either. A red warning appears on the Steam card if
a Windows game needs repair or Steam has tried to open its `.exe` directly.
The check repeats every 10 seconds; actual repair waits until Steam closes.
Changed entries are backed up, routed through the
bundled WineForge launch script, then parsed again to verify the result.
The script maps the game folder into the shared Wine prefix and starts the
game from that Windows working directory, so adjacent assets remain accessible.
WinLauncher also shows these games in its own library. An executable with
spaces in its filename is currently skipped by the Steam Play repair because
Wine's `cmd` cannot reliably launch it with quotes in this setup. Games that
need a Windows Steam client or an `lsteamclient` bridge may still fail
Steamworks checks.

WinLauncher preserves the chosen switch state across its own restarts. On a
fresh installation the switch is off, so Steam prefers native Mac builds. For
a Windows-only download the user can enable the switch and restart Steam, then
turn it off and restart Steam again before installing or updating Mac games.
Installed Windows games remain available from WinLauncher cards. This is not
automatic per-game platform selection: Steam's developer override is global.

For per-game Mac/Windows selection and full Steamworks integration, use the
approach explored by [NotProton](https://github.com/NotProtonNot/NotProton):
version-specific Steam hooks, a registered compatibility tool, and a Windows
runtime with an `lsteamclient` bridge. That integration requires testing with
each Steam client build and the chosen Wine engine.

The developer-config override and its whole-library behavior are documented
by [Kaon](https://github.com/natbro/kaon#1-installing-windows-games-naturally).
