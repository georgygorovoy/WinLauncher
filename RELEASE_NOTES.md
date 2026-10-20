# WinLauncher 1.0.0

The first public release turns Windows apps into a simple native macOS library.

## Highlights

- Open or drag any `.exe` or `.msi`.
- Open Windows files directly from Finder.
- Automatic, verified WineForge engine installation.
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

The DMG uses local ad-hoc signing for testing. Public distribution should use a
Developer ID signature and Apple notarization.
