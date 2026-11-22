# Android app store

WinLauncher installs F-Droid inside its Android 11 ARM64 AOSP emulator. The
card in the Android tab and Settings → Android use the same action. WinLauncher
downloads the official F-Droid 1.23.2 APK from
`https://f-droid.org/repo/org.fdroid.fdroid_1023052.apk`, verifies its pinned
SHA-256 `985f5181d48bb6bafd54083a048b391271e0ab28385881cc41294fb01a222762`,
stores it in the Android cache, and uses the existing ADB install-and-launch
path. Reopening the card checks the cached APK again. The APK downloaded while
developing this feature has the [official F-Droid release signing certificate](https://f-droid.org/docs/Release_Channels_and_Signing_Keys/):
`43238d512c1e5eb2d6569f4a3afbf5523418b82e0a3ed1552770abb9a9c9ccab`.
When F-Droid is already installed in the emulator, WinLauncher opens that
installation without reinstalling the pinned APK, preserving store updates.

F-Droid is the official client for F-Droid's free-software repository. It is
not Google Play. The AOSP image used by WinLauncher does not bundle Google Play
Services or the Play Store. Some apps need those services or physical device
features and may not work in the emulator. Android may ask the user to allow
F-Droid to install apps the first time they use its store.
