# WinLauncher 1.1.0

This update adds Android APKs to the same native macOS app library.

## Highlights

- Open or drag `.exe`, `.msi`, or `.apk` files.
- Open supported Windows and Android files directly from Finder.
- Install a minimal Android runtime automatically without Android Studio or Java.
- Verify every Android runtime archive against Google's published SHA-1 checksum.
- Start the Android Emulator, install the APK, detect its package and open it.
- Keep Android apps in the library for one-click relaunch.
- Automatic, verified WineForge engine installation.
- New native macOS application icon created with Apple Icon Composer.
- One shared Windows Environment by default.
- Ubisoft Connect login and Trackmania support through the WineForge CEF/DXMT path.
- Real application icons when Wine can extract them, with polished generated artwork as a fallback.
- Automatic, Performance and Compatibility graphics modes.
- Environment repair, Windows tools, custom environment variables and useful diagnostics.
- Automatic, integrity-checked Wine Mono support for managed .NET applications.
- Clear guidance when an installer depends on unsupported Microsoft Store/WinRT components.
- Microsoft Store bootstrap installers are recognized before launch. Minecraft routes to the Windows-entitlement Bedrock runtime, which uses the user's Microsoft purchase without requiring Google Play.

## Requirements

- Apple Silicon Mac
- macOS 14 or later
- Internet connection for the first Windows engine installation
- About 3 GB free space for optional Android Support

Android compatibility depends on the APK. Apps requiring a physical device,
an unavailable native CPU architecture, Google Play installation, DRM, or Play
Integrity certification may not run in an emulator.

The DMG uses local ad-hoc signing for testing. Public distribution should use a
Developer ID signature and Apple notarization.
