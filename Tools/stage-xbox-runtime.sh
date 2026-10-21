#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
upstream="${1:-/private/tmp/winlauncher-bedrock-mac}"
output="$project_root/External/XboxRuntime/bin/XboxRuntime"
temporary="$project_root/External/XboxRuntime/bin/.XboxRuntime-$$"

wine="$upstream/runtime/standalone/wine"
dxmt="$upstream/runtime/standalone/dxmt"
worker="$upstream/build/winlauncher-frozen/BedrockWorker"
helper="$project_root/External/XboxHelper/bin/standalone_helper"
source="$project_root/External/XboxRuntime/Source"

for required in "$wine/bin/wine" "$wine/build-manifest.json" \
  "$dxmt/manifest.json" "$worker/BedrockWorker" "$helper"; do
  [[ -e "$required" ]] || { print -u2 "Missing runtime input: $required"; exit 2; }
done

/bin/rm -rf "$temporary"
/bin/mkdir -p "$temporary/runtime" "$temporary/worker" "$temporary/scripts/file-pickers" \
  "$temporary/scripts/patches" "$temporary/LICENSES"
/usr/bin/ditto "$wine" "$temporary/runtime/wine"
/usr/bin/ditto "$dxmt" "$temporary/runtime/dxmt"
/usr/bin/ditto "$worker" "$temporary/worker"
/usr/bin/install -m 700 "$helper" "$temporary/standalone_helper"

for file in standalone.py standalone-setup.py standalone-gameinput.py standalone-pickers.py winrt.reg; do
  /usr/bin/install -m 600 "$source/$file" "$temporary/scripts/$file"
done
# The picker verifier hashes every build input, including build.sh. Keep the
# complete pinned source set beside the runtime so verification cannot depend
# on files from the developer checkout.
/bin/cp -R "$source/file-pickers/." "$temporary/scripts/file-pickers/"
/bin/cp -R "$source/patches/." "$temporary/scripts/patches/"
/bin/cp -R "$source/LICENSES/." "$temporary/LICENSES/"
/bin/mkdir -p "$temporary/LICENSES/PythonWorker"
/bin/cp -R "$source/PythonWorkerNotices/licenses/." "$temporary/LICENSES/PythonWorker/"
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
