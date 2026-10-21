#!/bin/sh
# Build, optionally stage to an idle Wine runtime. Never write a prefix or launch.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD="$ROOT/build/standalone-wine"
OUTPUT="$ROOT/build/file-pickers"
STAGE_RUNTIME=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --wine-build) [ "$#" -ge 2 ] || exit 2; BUILD=$2; shift 2 ;;
        --output) [ "$#" -ge 2 ] || exit 2; OUTPUT=$2; shift 2 ;;
        --stage-runtime) [ "$#" -ge 2 ] || exit 2; STAGE_RUNTIME=$2; shift 2 ;;
        *) echo 'Usage: file-pickers/build.sh [--wine-build DIR] [--output DIR] [--stage-runtime WINE]' >&2; exit 2 ;;
    esac
done
cd "$ROOT"
BUILD=$(CDPATH= cd -- "$BUILD" && pwd)
mkdir -p "$OUTPUT"
OUTPUT=$(CDPATH= cd -- "$OUTPUT" && pwd)
SNAPSHOT=$(mktemp -d "$OUTPUT/.picker-source.XXXXXX")
trap 'rm -rf "$SNAPSHOT"' 0
/usr/bin/python3 - "$ROOT" "$SNAPSHOT" <<'PYSNAPSHOT'
from pathlib import Path
import sys
root, snapshot = map(Path, sys.argv[1:])
for name in ('file-pickers/build.sh', 'file-pickers/pickers.c', 'file-pickers/pickers.spec',
             'file-pickers/ids.h', 'file-pickers/README.md', 'file-pickers/check-windows.cmd',
             'tests/file-picker-contract.c'):
    source, destination = root / name, snapshot / name
    if source.is_symlink():
        raise SystemExit('Picker build inputs must be ordinary source files.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(source.read_bytes())
PYSNAPSHOT
export PATH="$BUILD/toolbin:/opt/homebrew/opt/llvm/bin:/usr/bin:/bin"
for target in library contract; do
    if [ "$target" = library ]; then
        set -- -shared -o "$OUTPUT/bedrock-pickers.dll" "$SNAPSHOT/file-pickers/pickers.c" "$SNAPSHOT/file-pickers/pickers.spec"
    else
        set -- -o "$OUTPUT/file-picker-contract.exe" "$SNAPSHOT/tests/file-picker-contract.c" -Wl,-entry:mainCRTStartup
    fi
    "$BUILD/tools/winegcc/winegcc" "$@" --wine-objdir "$BUILD" \
      --cc-cmd='/opt/homebrew/opt/llvm/bin/clang -D__STDC__' -b x86_64-windows \
      -I"$BUILD/include" -I"$BUILD/source/include" -I"$BUILD/source/include/msvcrt" \
      -D__WINESRC__ -nostdlib -lkernel32 -luser32 -lcombase -lcomdlg32 -lucrtbase --no-default-config
done
/usr/bin/python3 - "$SNAPSHOT" "$OUTPUT" "$STAGE_RUNTIME" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
root, output = map(Path, sys.argv[1:3])
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
sources = ('file-pickers/build.sh', 'file-pickers/pickers.c', 'file-pickers/pickers.spec',
           'file-pickers/ids.h')
test_sources = ('file-pickers/README.md', 'file-pickers/check-windows.cmd',
                'tests/file-picker-contract.c')
receipt = {'version': 1,
           'files': {'bedrock-pickers.dll': digest(output / 'bedrock-pickers.dll')},
           'source_sha256': {name: digest(root / name) for name in sources},
           'test_source_sha256': {name: digest(root / name) for name in test_sources}}
staged = output / 'build-manifest.json.tmp'
staged.write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
staged.replace(output / 'build-manifest.json')
if sys.argv[3]:
    runtime = Path(sys.argv[3]).absolute()
    dll = runtime / 'lib/wine/x86_64-windows/bedrock-pickers.dll'
    metadata = runtime / 'file-pickers-build.json'
    for path in (runtime, runtime / 'lib', runtime / 'lib/wine', dll.parent, dll, metadata):
        if path.is_symlink():
            raise SystemExit('Picker staging refuses symlinked runtime paths.')
    if not (runtime / 'bin/wine').is_file() or not dll.parent.is_dir():
        raise SystemExit('Picker staging requires a built Wine runtime.')
    for path in (runtime / 'lib/wine/x86_64-unix/ntdll.so', dll):
        if path.exists():
            active = subprocess.run(['/usr/sbin/lsof', '-t', str(path)],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if active.returncode == 0 or active.stdout:
                raise SystemExit('Close standalone Wine applications before staging picker support.')
            if active.returncode != 1 or active.stderr:
                raise SystemExit('Cannot verify whether the picker runtime is idle.')
    previous = {path: path.read_bytes() if path.exists() else None for path in (dll, metadata)}
    if previous[dll] is not None:
        try:
            old = json.loads(previous[metadata])
            expected = old['files']['bedrock-pickers.dll']
        except (TypeError, ValueError, KeyError):
            raise SystemExit('Existing picker DLL has no valid build receipt; preserve it for review.')
        actual = hashlib.sha256(previous[dll]).hexdigest()
        if actual != expected:
            raise SystemExit('Existing picker DLL differs from its build receipt; preserve it for review.')
        backups = runtime / 'file-pickers-backups'
        if backups.is_symlink():
            raise SystemExit('Picker staging refuses a symlinked backup directory.')
        backups.mkdir(exist_ok=True)
        for suffix, data in (('.dll', previous[dll]), ('.json', previous[metadata])):
            backup = backups / (actual + '-' + hashlib.sha256(data).hexdigest() + suffix)
            if backup.exists() or backup.is_symlink():
                if backup.is_symlink() or backup.read_bytes() != data:
                    raise SystemExit('Existing picker backup conflicts with this runtime.')
            else:
                with backup.open('xb') as file:
                    file.write(data)
    def atomic(path, data):
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as file:
            temporary = Path(file.name)
            try:
                file.write(data)
                file.flush()
                os.fsync(file.fileno())
            except BaseException:
                temporary.unlink()
                raise
        try:
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)
    try:
        atomic(dll, (output / 'bedrock-pickers.dll').read_bytes())
        atomic(metadata, (output / 'build-manifest.json').read_bytes())
    except BaseException:
        for path, data in previous.items():
            if data is None:
                path.unlink(missing_ok=True)
            else:
                atomic(path, data)
        raise
PY
printf '%s\n' "Built file picker DLL and contracts in $OUTPUT"
