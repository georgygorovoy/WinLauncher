# Android APK support

WinLauncher 1.1.0 installs a minimal official Android runtime on demand. Android Studio and Java are not required. The app never silently accepts Google's SDK license.

## One-time setup

1. Open an `.apk` in WinLauncher.
2. Read and accept the linked Android SDK License Agreement.
3. Click **Download and Install**.

WinLauncher downloads three checksum-pinned packages directly from Google's SDK repository: Platform Tools (`adb`), the native Apple Silicon Emulator, and the default Android 11 ARM64 AOSP image. The download is about 985 MB and occupies about 2.5–3 GB after installation under `~/Library/Application Support/WinLauncher/Android`. WinLauncher stores the large Android disk images sparsely and disables emulator snapshots so unused zero-filled space does not consume real disk space. An existing SDK can still be selected in Settings > Android.

For every APK, WinLauncher starts the chosen virtual phone if needed, waits for Android to finish booting, extracts the package identifier with Android build tools, installs or updates the APK with `adb`, and opens its launcher activity. The APK stays in the WinLauncher library.

## Compatibility boundary

Universal and ARM64 APKs are the best fit for Apple Silicon. An APK is not guaranteed to work when it contains only x86 native libraries, requires unavailable phone hardware, requires installation through Google Play, performs DRM checks, or rejects emulated devices through Play Integrity. Split APK bundles (`.apks`, `.xapk`, `.aab`) are outside version 1.1.0.
