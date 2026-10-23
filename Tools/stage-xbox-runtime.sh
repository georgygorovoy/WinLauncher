#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
upstream="${1:-/private/tmp/winlauncher-bedrock-mac}"
output="$project_root/External/XboxRuntime/bin/XboxRuntime"
temporary="$project_root/External/XboxRuntime/bin/.XboxRuntime-$$"
download_cache="$project_root/.build/downloads"

wine="$upstream/runtime/standalone/wine"
dxmt="$upstream/runtime/standalone/dxmt"
helper="$project_root/External/XboxHelper/bin/standalone_helper"
source="$project_root/External/XboxRuntime/Source"
python_lock="$source/portable-python.lock"

# A previously staged runtime is also a valid input when only the worker needs
# rebuilding. This avoids rebuilding WineGDK and DXMT for a launcher-only fix.
if [[ ! -e "$wine/bin/wine" && -e "$upstream/runtime/wine/bin/wine" ]]; then
  wine="$upstream/runtime/wine"
  dxmt="$upstream/runtime/dxmt"
fi

for required in "$wine/bin/wine" "$wine/build-manifest.json" \
  "$dxmt/manifest.json" "$helper" "$python_lock" "$source/launcher/setup.py" \
  "$source/launcher/worker-launcher.c" \
  "$source/LICENSES/python-build-standalone-MPL-2.0.txt"; do
  [[ -e "$required" ]] || { print -u2 "Missing runtime input: $required"; exit 2; }
done

/bin/rm -rf "$temporary"
/bin/mkdir -p "$temporary/runtime" "$temporary/worker" "$temporary/scripts/file-pickers" \
  "$temporary/scripts/patches" "$temporary/LICENSES"
/usr/bin/ditto "$wine" "$temporary/runtime/wine"
/usr/bin/ditto "$dxmt" "$temporary/runtime/dxmt"
/usr/bin/install -m 700 "$helper" "$temporary/standalone_helper"

# Use a pinned, portable CPython build rather than freezing the worker with the
# developer Mac's Homebrew Python. The latter can accidentally require symbols
# from a newer macOS and fail before the Microsoft sign-in window can open.
typeset python_archive python_url python_sha
python_archive="$(/usr/bin/awk -F= '$1 == "archive" {sub(/^archive=/, ""); print; exit}' "$python_lock")"
python_url="$(/usr/bin/awk -F= '$1 == "url" {sub(/^url=/, ""); print; exit}' "$python_lock")"
python_sha="$(/usr/bin/awk -F= '$1 == "sha256" {print $2; exit}' "$python_lock")"
[[ -n "$python_archive" && -n "$python_url" && -n "$python_sha" ]] || {
  print -u2 "Invalid portable Python lock file: $python_lock"
  exit 2
}
/bin/mkdir -p "$download_cache"
python_download="$download_cache/$python_archive"
if [[ ! -f "$python_download" ]] || \
   [[ "$(/usr/bin/shasum -a 256 "$python_download" | /usr/bin/awk '{print $1}')" != "$python_sha" ]]; then
  /bin/rm -f "$python_download"
  /usr/bin/curl -L --fail --retry 3 -o "$python_download.part" "$python_url"
  /bin/mv "$python_download.part" "$python_download"
fi
[[ "$(/usr/bin/shasum -a 256 "$python_download" | /usr/bin/awk '{print $1}')" == "$python_sha" ]] || {
  print -u2 "Portable Python checksum mismatch"
  exit 2
}
/usr/bin/tar -xzf "$python_download" -C "$temporary/worker"
/usr/bin/install -m 600 "$source/launcher/setup.py" "$temporary/worker/setup.py"
/usr/bin/clang -Os -mmacosx-version-min=11.0 "$source/launcher/worker-launcher.c" \
  -o "$temporary/worker/BedrockWorker"
/bin/chmod 700 "$temporary/worker/BedrockWorker" "$temporary/worker/python/bin/python3.13"

# These compiler, package-manager and GUI development files are not used by the
# launcher. Removing them keeps the distributed worker small and immutable.
/bin/rm -rf "$temporary/worker/python/include" "$temporary/worker/python/share" \
  "$temporary/worker/python/lib/pkgconfig" "$temporary/worker/python/lib/tk9.0" \
  "$temporary/worker/python/lib/tcl9.0" "$temporary/worker/python/lib/tcl9" \
  "$temporary/worker/python/lib/thread3.0.6" "$temporary/worker/python/lib/itcl4.3.8" \
  "$temporary/worker/python/lib/python3.13/idlelib" \
  "$temporary/worker/python/lib/python3.13/tkinter" \
  "$temporary/worker/python/lib/python3.13/ensurepip" \
  "$temporary/worker/python/lib/python3.13/site-packages"
/bin/rm -f "$temporary/worker/python/lib/"*.dylib \
  "$temporary/worker/python/lib/python3.13/lib-dynload/_tkinter"* \
  "$temporary/worker/python/lib/python3.13/lib-dynload/_dbm"*
/usr/bin/find "$temporary/worker/python/bin" -type f ! -name python3.13 -delete
/usr/bin/find "$temporary/worker/python/bin" -type l ! -name python3 -delete

for file in standalone.py standalone-setup.py standalone-gameinput.py standalone-pickers.py winrt.reg; do
  /usr/bin/install -m 600 "$source/$file" "$temporary/scripts/$file"
done
# The picker verifier hashes every build input, including build.sh. Keep the
# complete pinned source set beside the runtime so verification cannot depend
# on files from the developer checkout.
/bin/cp -R "$source/file-pickers/." "$temporary/scripts/file-pickers/"
/bin/cp -R "$source/patches/." "$temporary/scripts/patches/"
/bin/cp -R "$source/LICENSES/." "$temporary/LICENSES/"
/bin/mkdir -p "$temporary/LICENSES/PortablePython"
/usr/bin/install -m 600 "$temporary/worker/python/lib/python3.13/LICENSE.txt" \
  "$source/LICENSES/python-build-standalone-MPL-2.0.txt" "$python_lock" \
  "$temporary/LICENSES/PortablePython/"
/usr/bin/install -m 600 "$source/LICENSE-GPL-3.0.txt" "$source/THIRD_PARTY.md" \
  "$project_root/External/XboxRuntime/README.md" "$project_root/External/XboxRuntime/UPSTREAM.lock" \
  "$temporary/"

# Fail the developer build before packaging if the Wine bridge or any of its
# pinned source inputs is missing or changed. This is the same verification the
# player performs before it modifies a user's Xbox Games environment.
BEDROCK_BUNDLE="$temporary" /usr/bin/python3 -c \
  'import importlib.util, os, pathlib; p=pathlib.Path(os.environ["BEDROCK_BUNDLE"]); s=importlib.util.spec_from_file_location("pickers", p/"scripts/standalone-pickers.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); m.verify_runtime(p/"runtime/wine")'

/usr/bin/find "$temporary" -type f -exec /usr/bin/shasum -a 256 {} \; \
  | /usr/bin/sort > "$temporary/RUNTIME-SHA256.txt"
/bin/rm -rf "$output"
/bin/mv "$temporary" "$output"
print "Staged Xbox runtime: $output"
/usr/bin/du -sh "$output"
