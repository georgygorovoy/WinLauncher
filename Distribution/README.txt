WinLauncher 1.2.1

1. Drag WinLauncher to Applications.
2. Open WinLauncher and choose a Windows .exe/.msi or Android .apk file.
3. On first use, WinLauncher downloads and verifies its open-source Wine engine.
4. All applications share one Windows Environment by default.
5. To open supported files from Finder, open WinLauncher Settings > General and click
   “Make WinLauncher Default for .exe, .msi, and .apk”.

For Android APKs, click “Download and Install” when prompted and accept Google's
Android SDK license. WinLauncher downloads only adb, the native Apple Silicon
emulator and one Android 11 ARM64 image (about 985 MB download / 2.5–3 GB installed).
Android Studio and Java are not required.

For Minecraft for Windows, open MinecraftInstaller.exe and choose “Set Up Xbox
Games Support”. WinLauncher opens Microsoft sign-in through a separate GPL helper,
verifies ownership, downloads the official Windows game, prepares its dedicated
WineGDK/DXMT environment, and launches it. Subsequent launches use the Minecraft
card in the Library. Minecraft support requires macOS 15 or later and Rosetta 2.

The Wine engine is downloaded separately and verified with SHA-256. WinLauncher
does not disable macOS security or silently expose your entire Home folder.
