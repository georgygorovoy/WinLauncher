WinLauncher 1.3.1

1. Drag WinLauncher to Applications.
2. Open WinLauncher and choose a Windows .exe/.msi or Android .apk file.
3. On first use, WinLauncher downloads and verifies its open-source Wine engine.
4. All applications share one Windows Environment by default.
5. To open supported files from Finder, open WinLauncher Settings > General and click
   “Make WinLauncher Default for .exe, .msi, and .apk”.

For Windows games downloaded with Steam for macOS, WinLauncher checks Steam's
cached Play commands every 10 seconds, including while Steam is open. If a
launch needs repair, the Steam card shows a red warning. Quit Steam to let
WinLauncher repair the cache, then reopen Steam. A green status means the
launch route has been verified. Supported games with a root .exe launch through
WineForge from Steam's Play button. You can also start a game from its card
under Profile > Steam Windows games in WinLauncher.

Steam prefers native macOS versions by default. To download a Windows-only
game, turn on the Windows downloads switch in WinLauncher Settings > Steam and
restart Steam. Turn the switch off and restart Steam before installing or
updating Mac games. This Steam setting affects the whole library; automatic
per-game platform selection is not yet available.

For Android APKs, click “Download and Install” when prompted and accept Google's
Android SDK license. WinLauncher downloads only adb, the native Apple Silicon
emulator and one Android 11 ARM64 image (about 985 MB download / 2.5–3 GB installed).
Android Studio and Java are not required.
The F-Droid card in the Android tab downloads a pinned, verified official APK
and installs the open-source app store inside that Android emulator. Google
Play is not included.

Store combines public Steam and GOG search results. Epic and Ubisoft open their
official websites. Game buttons open official store pages for sign-in and
installation. Profile shows apps known to WinLauncher and launches made through
WinLauncher; it is not a list of every game installed by macOS store clients.

For Minecraft for Windows, open MinecraftInstaller.exe and choose “Set Up Xbox
Games Support”. WinLauncher opens Microsoft sign-in through a separate GPL helper,
verifies ownership, downloads the official Windows game, prepares its dedicated
WineGDK/DXMT environment, and launches it. Subsequent launches use the Minecraft
card in the Library. Minecraft support requires macOS 15 or later and Rosetta 2.

The Wine engine is downloaded separately and verified with SHA-256. WinLauncher
does not disable macOS security or silently expose your entire Home folder.
