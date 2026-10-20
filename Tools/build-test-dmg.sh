#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
engine_archive="$HOME/Library/Application Support/Sikarugir/Engines/WS12WineSikarugir10.0_6.tar.xz"
build_root="$project_root/.build/native-test"
app_path="$build_root/WinLauncher Test.app"
volume_path="$build_root/volume"
output_path="$project_root/dist/WinLauncher-Test.dmg"

if [[ ! -f "$engine_archive" ]]; then
  print -u2 "Missing local Sikarugir engine archive: $engine_archive"
  exit 1
fi

if [[ -d "$volume_path" ]]; then
  /bin/rm -rf "$volume_path"
fi
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$volume_path" "$project_root/dist"
mkdir -p "$build_root/module-cache"

/usr/bin/clang -fobjc-arc -fmodules -fmodules-cache-path="$build_root/module-cache" -mmacosx-version-min=14.0 \
  -framework Cocoa \
  "$project_root/NativeTestApp/main.m" \
  -o "$app_path/Contents/MacOS/WinLauncherTest"

/bin/cp "$project_root/NativeTestApp/Info.plist" "$app_path/Contents/Info.plist"
/bin/cp "$engine_archive" "$app_path/Contents/Resources/WS12WineSikarugir10.0_6.tar.xz"
/usr/bin/codesign --force --deep --sign - "$app_path"

/bin/cp -R "$app_path" "$volume_path/WinLauncher Test.app"
/bin/cp "$project_root/NativeTestApp/README.txt" "$volume_path/README.txt"
/bin/ln -s /Applications "$volume_path/Applications"
/bin/rm -f "$output_path"

/usr/bin/hdiutil create -quiet -volname "WinLauncher Test" -srcfolder "$volume_path" \
  -ov -format UDZO "$output_path"
/usr/bin/hdiutil verify "$output_path"
/usr/bin/shasum -a 256 "$output_path"
