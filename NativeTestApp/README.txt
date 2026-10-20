WinLauncher Test 0.1

This local proof-of-concept runs .exe and .msi files with one shared Windows Environment.

1. Drag WinLauncher Test.app into Applications, or run it from this disk image.
2. Open the app. If macOS blocks it, Control-click it in Finder and choose Open.
3. Drop an .exe/.msi into the window or use one of the buttons.

The first launch extracts the bundled Wine engine and prepares:
~/Library/Application Support/WinLauncher Test/Environments/Default

Logs are stored in:
~/Library/Application Support/WinLauncher Test/Logs

This is an ad-hoc-signed local test build. It is not notarized and the Wine 10 engine is a control build, not the final Ubisoft engine.
