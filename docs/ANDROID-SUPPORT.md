# Android APK support

WinLauncher 1.1.0 uses the official Android Emulator already installed on the Mac. The app does not bundle Google SDK packages or silently accept Google's SDK license.

## One-time setup

1. Install Android Studio.
2. In SDK Manager, install Android Emulator, Android SDK Platform-Tools and Android SDK Build-Tools.
3. In Device Manager, create and start once an ARM64 phone image (`arm64-v8a`).
4. Open an `.apk` in WinLauncher. The standard SDK location is detected automatically. A custom SDK can be selected in Settings > Android.

For every APK, WinLauncher starts the chosen virtual phone if needed, waits for Android to finish booting, extracts the package identifier with Android build tools, installs or updates the APK with `adb`, and opens its launcher activity. The APK stays in the WinLauncher library.

## Compatibility boundary

Universal and ARM64 APKs are the best fit for Apple Silicon. An APK is not guaranteed to work when it contains only x86 native libraries, requires unavailable phone hardware, requires installation through Google Play, performs DRM checks, or rejects emulated devices through Play Integrity. Split APK bundles (`.apks`, `.xapk`, `.aab`) are outside version 1.1.0.
