#!/bin/zsh
set -euo pipefail
setopt NULL_GLOB

project_root="${0:A:h:h}"
project="$project_root/WinLauncher.xcodeproj"
derived_data="$project_root/.build/xcode"
stage="$project_root/.build/dmg-stage"
output="$project_root/dist/WinLauncher-1.1.0.dmg"

developer_dir=""
for candidate in /Applications/Xcode.app/Contents/Developer /Applications/Xcode-*.app/Contents/Developer; do
  if [[ -x "$candidate/usr/bin/xcodebuild" ]]; then
    developer_dir="$candidate"
    break
  fi
done

if [[ -z "$developer_dir" ]]; then
  print -u2 "Full Xcode is not installed in /Applications. Install Xcode from the Mac App Store first."
  exit 2
fi

export DEVELOPER_DIR="$developer_dir"
export LC_ALL=C

"$developer_dir/usr/bin/xcodebuild" \
  -project "$project" \
  -scheme WinLauncher \
  -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$derived_data" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  build

app="$derived_data/Build/Products/Release/WinLauncher.app"
if [[ ! -d "$app" ]]; then
  print -u2 "Xcode completed without producing $app"
  exit 3
fi

/usr/bin/codesign --force --deep --sign - "$app"
/bin/rm -rf "$stage"
/bin/mkdir -p "$stage" "$project_root/dist"
/bin/cp -R "$app" "$stage/WinLauncher.app"
/bin/cp "$project_root/Distribution/README.txt" "$stage/README.txt"
/bin/ln -s /Applications "$stage/Applications"
/bin/rm -f "$output"
/usr/bin/hdiutil create -volname "WinLauncher 1.1.0" -srcfolder "$stage" -ov -format UDZO "$output"
/usr/bin/hdiutil verify "$output"
/usr/bin/shasum -a 256 "$output"
print "Created: $output"
