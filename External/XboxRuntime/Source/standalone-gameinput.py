#!/usr/bin/env python3
"""Install pinned Microsoft GameInput files into an idle, explicitly chosen Wine prefix.

The OLE/MSZIP readers below are adapted from BedrockOnLinux bol/gameinput.py,
commit 7a315c836b7ae8068042bc466b0540c16ffe3a5e:
https://github.com/Wyze3306/BedrockOnLinux
The original MIT license notice follows. Microsoft payloads are not included.
"""
# MIT License
#
# Copyright (c) 2026 BedrockOnLinux contributors
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import zlib

def _msi_embedded_cab(msi: bytes):
    """Return the embedded MSZip CAB bytes from an MSI, parsing the OLE
    compound-file container in pure Python (no msiexec, no host tools). The
    CAB is stored as a stream scattered across OLE sectors — not contiguous —
    so we must walk the FAT chains. Returns the CAB bytes, or None."""
    if msi[:8] != bytes.fromhex("d0cf11e0a1b11ae1"):
        return None
    u = struct.unpack_from
    ssz = 1 << u("<H", msi, 0x1e)[0]
    mssz = 1 << u("<H", msi, 0x20)[0]
    dir0 = u("<I", msi, 0x30)[0]
    minicut = u("<I", msi, 0x38)[0]
    minifat0 = u("<I", msi, 0x3c)[0]
    difat0, ndifat = u("<I", msi, 0x44)[0], u("<I", msi, 0x48)[0]
    FREE, ENDC = 0xFFFFFFFF, 0xFFFFFFFE
    sect = lambda n: msi[(n + 1) * ssz:(n + 2) * ssz]
    difat = list(u("<109I", msi, 0x4c))
    nxt = difat0
    for _ in range(ndifat):
        if nxt in (FREE, ENDC):
            break
        vals = list(u("<%dI" % (ssz // 4), sect(nxt), 0))
        difat += vals[:-1]
        nxt = vals[-1]
    fat = []
    for fs in (d for d in difat if d != FREE):
        fat += list(u("<%dI" % (ssz // 4), sect(fs), 0))

    def chain(start):
        out, n, seen = [], start, set()
        while n not in (ENDC, FREE) and n < len(fat) and n not in seen:
            seen.add(n)
            out.append(n)
            n = fat[n]
        return out

    rbig = lambda s, sz: b"".join(sect(n) for n in chain(s))[:sz]
    dird = rbig(dir0, len(chain(dir0)) * ssz)
    ents = []
    for i in range(0, len(dird), 128):
        e = dird[i:i + 128]
        if len(e) < 128:
            break
        if u("<H", e, 64)[0]:
            ents.append((e[66], u("<I", e, 116)[0], u("<Q", e, 120)[0]))
    root = next((e for e in ents if e[0] == 5), None)
    if not root:
        return None
    ministream = rbig(root[1], root[2])
    mfat = []
    for ms in chain(minifat0):
        mfat += list(u("<%dI" % (ssz // 4), sect(ms), 0))

    def rmini(s, sz):
        out, n, seen = b"", s, set()
        while n not in (ENDC, FREE) and n < len(mfat) and n not in seen:
            seen.add(n)
            out += ministream[n * mssz:(n + 1) * mssz]
            n = mfat[n]
        return out[:sz]

    for typ, start, size in ents:
        if typ != 2 or size < 4:
            continue
        head = rbig(start, size) if size >= minicut else rmini(start, size)
        if head[:4] == b"MSCF":
            return head
    return None

def _cab_payload(cab: bytes):
    """Decompress an MSZip CAB. Returns [(uncompressed_size, bytes), …]."""
    if not cab or cab[:4] != b"MSCF":
        return []
    u = struct.unpack_from
    coff_files = u("<I", cab, 16)[0]
    cfolders, cfiles, flags = u("<HHH", cab, 26)
    o, cb_folder, cb_data = 36, 0, 0
    if flags & 4:
        cb_header, cb_folder, cb_data = u("<HBB", cab, o)
        o += 4 + cb_header
    folders = []
    for _ in range(cfolders):
        coff, ndata, _ = u("<IHH", cab, o)
        o += 8 + cb_folder
        folders.append((coff, ndata))
    files, p = [], coff_files
    for _ in range(cfiles):
        cb, uoff, ifol = u("<IIH", cab, p)
        p += 16
        p = cab.index(b"\x00", p) + 1
        files.append((cb, uoff, ifol))
    fdata = []
    for coff, ndata in folders:
        q, out, prev = coff, b"", b""
        for _ in range(ndata):
            cb_d = u("<IHH", cab, q)[1]
            q += 8 + cb_data
            blk = cab[q:q + cb_d]
            q += cb_d
            if blk[:2] != b"CK":
                return []
            d = zlib.decompressobj(-15, zdict=prev[-32768:] if prev else b"")
            out += d.decompress(blk[2:]) + d.flush()
            prev = out
        fdata.append(out)
    return [(cb, fdata[ifol][uoff:uoff + cb]) for cb, uoff, ifol in files]


ROOT = Path(__file__).resolve().parent
MSI_SHA256 = "4e325dbc8a6853ea7786504f6f326bee37a085b799d262a5ec296df95cc8601a"
CAB_SHA256 = "e1ef9aaf57b36bd75c75416772026835842353b764926ccf6242cf6a1cd676af"
FILES = {
    "GameInputRedist.dll": (895376, "ea6816937030fcf232de5c29628a0140d0643f81939b5ac47fb2a1f4bfaa374d", True),
    "GameInputRedistService.exe": (137616, "3959900e8a57e368e86f0b9d63585bc721d71ee78fba30086f224fc9981244c2", False),
    "GameInputBridge.dll": (80272, "00a5255333be1db3006485f5a5c6a9e1e42ccdb1d7ba35d05aeafedc9f1bc5c5", True),
    "GameInputRawInputProxy.exe": (80272, "76638d16c9bbd6c87b4b64bdbbcce166b2f83f261fc756ec6714a5a5f667dd81", False),
}
REDIST = r"C:\Program Files\Microsoft GameInput\x64"
SERVICE = r"System\CurrentControlSet\Services\GameInputRedistService"
REGISTRY = {
    r"Software\Microsoft\GameInput": {"RedistDir": REDIST},
    r"Software\Wow6432Node\Microsoft\GameInput": {"RedistDir": REDIST},
    SERVICE: {
        "DisplayName": "GameInput Redist Service", "Description": "GameInput Redist Service",
        "ImagePath": REDIST + r"\GameInputRedistService.exe", "ObjectName": "LocalSystem",
        "ErrorControl": 0, "Start": 3, "Type": 0x10, "PreshutdownTimeout": 180000,
    },
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def verify_pe(data, is_dll):
    if data[:2] != b"MZ" or len(data) < 64:
        return False
    offset = struct.unpack_from("<I", data, 60)[0]
    return (offset + 24 <= len(data) and data[offset:offset + 6] == b"PE\0\0\x64\x86"
            and bool(struct.unpack_from("<H", data, offset + 22)[0] & 0x2000) == is_dll)


def payload(msi):
    source = msi.read_bytes()
    if digest(source) != MSI_SHA256:
        raise RuntimeError("Unrecognized GameInput MSI. No files changed; this package needs a reviewed hash mapping.")
    cab = _msi_embedded_cab(source)
    if cab is None or digest(cab) != CAB_SHA256:
        raise RuntimeError("GameInput CAB does not match the pinned Microsoft payload.")
    expected = {entry[1]: name for name, entry in FILES.items()}
    selected = {}
    for declared_size, data in _cab_payload(cab):
        name = expected.get(digest(data))
        if name is not None:
            size, _, is_dll = FILES[name]
            if name in selected or declared_size != size or len(data) != size or not verify_pe(data, is_dll):
                raise RuntimeError("The native GameInput payload has an invalid PE image or size.")
            selected[name] = data
    if selected.keys() != FILES.keys():
        raise RuntimeError("The pinned MSI is missing an expected native GameInput file.")
    return selected


def validate_prefix(prefix):
    if prefix.is_symlink() or (prefix / "cxbottle.conf").exists() or prefix.resolve() == (ROOT / "bottles/Bedrock-Mac").resolve():
        raise RuntimeError("Refusing to change the existing CrossOver prefix or a symbolic-link prefix.")
    for relative in ("system.reg", "user.reg", "drive_c/windows/system32"):
        path = prefix / relative
        if not path.exists() or not path.resolve().is_relative_to(prefix.resolve()):
            raise RuntimeError("Initialize the separate Wine prefix before installing GameInput.")


def require_idle(prefix, wineserver):
    if not wineserver.is_file():
        raise RuntimeError("The standalone wineserver executable is missing.")
    env = {key: value for key, value in os.environ.items() if not key.startswith(("CX_", "WINE", "DYLD_"))}
    env.update(WINEPREFIX=str(prefix), WINEARCH="win64")
    try:
        # -w only waits for this prefix's server; it never starts or stops it.
        subprocess.run([str(wineserver), "-w"], env=env, timeout=1, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise RuntimeError("The selected standalone prefix is busy. Stop its Wine processes before installing GameInput.")


def native_directory(prefix):
    return prefix / "drive_c/Program Files/Microsoft GameInput/x64"


def files_valid(prefix):
    directory = native_directory(prefix)
    if not directory.resolve().is_relative_to(prefix.resolve()):
        return {name: False for name in FILES}
    return {name: not (directory / name).is_symlink() and (directory / name).is_file() and digest((directory / name).read_bytes()) == sha
            for name, (_, sha, _) in FILES.items()}


def registry_text():
    lines = ["Windows Registry Editor Version 5.00", ""]
    for section, entries in REGISTRY.items():
        lines.append("[HKEY_LOCAL_MACHINE\\" + section + "]")
        for key, value in entries.items():
            if isinstance(value, int):
                encoded = "dword:%08x" % value
            elif key == "ImagePath":
                encoded = "hex(2):" + ",".join("%02x" % b for b in (value + "\0").encode("utf-16-le"))
            else:
                encoded = '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
            lines.append('"' + key + '"=' + encoded)
        lines.append("")
    return "\n".join(lines)


def registry_valid(prefix):
    sections = {}
    current = None
    for line in (prefix / "system.reg").read_text(errors="replace").splitlines():
        if line.startswith("[") and "]" in line:
            current = line[1:line.index("]")].replace("\\\\", "\\").lower()
            sections[current] = {}
        elif current:
            match = re.fullmatch(r'"((?:\\.|[^"\\])*)"=(.*)', line)
            if match:
                value = match[2]
                if value.startswith("dword:"):
                    value = int(value[6:], 16)
                else:
                    value = re.sub(r'^str\(2\):', '', value)
                    if value.startswith('"') and value.endswith('"'):
                        value = re.sub(r'\\(.)', r'\1', value[1:-1])
                sections[current][match[1].lower()] = value
    active = sections.get('system\\select', {}).get('current', 1)
    if not isinstance(active, int):
        active = 1
    def section_values(section):
        name = section.lower()
        canonical = name.replace('\\currentcontrolset\\', '\\controlset%03d\\' % active)
        return sections.get(name, sections.get(canonical, {}))
    return {section: all(section_values(section).get(key.lower()) == value for key, value in entries.items())
            for section, entries in REGISTRY.items()}


def atomic_write(path, data):
    if path.is_symlink():
        raise RuntimeError("Refusing to replace a symbolic link: " + str(path))
    fd, temporary = tempfile.mkstemp(prefix=".gameinput-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def install(prefix, msi, wineserver):
    validate_prefix(prefix)
    selected = payload(msi)
    require_idle(prefix, wineserver)
    directory = native_directory(prefix)
    for parent in [directory, *directory.parents]:
        if parent == prefix:
            break
        if parent.is_symlink():
            raise RuntimeError("GameInput destination contains a symbolic link; no files changed.")
    # Reject all conflicts before writing any game files.
    for name, data in selected.items():
        target = directory / name
        if target.is_symlink() or (target.exists() and target.read_bytes() != data):
            raise RuntimeError("Existing GameInput file differs from this Microsoft package; it was preserved: " + name)
    directory.mkdir(parents=True, exist_ok=True)
    for name, data in selected.items():
        target = directory / name
        if not target.exists():
            atomic_write(target, data)
    registry = prefix / ".standalone-gameinput.reg"
    atomic_write(registry, registry_text().encode("utf-16"))
    if not all(files_valid(prefix).values()):
        raise RuntimeError("GameInput file verification failed after extraction.")
    print("Verified four native Microsoft GameInput files. Registry import is still required:")
    print(registry)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prefix", type=Path, required=True, help="Explicit separate Wine prefix; no default")
    parser.add_argument("--msi", type=Path, required=True, help="The owned game's Installers/GameInputRedist.msi")
    parser.add_argument("--wineserver", type=Path, help="Standalone wineserver, required for installation idle check")
    parser.add_argument("--check", action="store_true", help="Read-only verification of files and persisted Wine registry")
    parser.add_argument("--verify-payload", action="store_true", help="Validate/extract the MSI in memory without touching any prefix")
    args = parser.parse_args()
    prefix = args.prefix.expanduser().absolute()
    msi = args.msi.expanduser().absolute()
    if args.verify_payload:
        selected = payload(msi)
        print(json.dumps({"msi_sha256": MSI_SHA256, "files": {name: digest(data) for name, data in selected.items()}}, indent=2))
        return 0
    validate_prefix(prefix)
    if args.check:
        payload(msi)
        files, registry = files_valid(prefix), registry_valid(prefix)
        print(json.dumps({"files": files, "registry": registry}, indent=2))
        return 0 if all(files.values()) and all(registry.values()) else 1
    if not args.wineserver:
        parser.error("Installation requires --wineserver to verify that this prefix is idle")
    os.umask(0o077)
    install(prefix, msi, args.wineserver.expanduser().absolute())
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError, struct.error, subprocess.SubprocessError) as error:
        print("GameInput: " + str(error), file=sys.stderr)
        sys.exit(1)
