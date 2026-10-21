#!/usr/bin/env python3
"""Verify and install the source-built picker bridge in an idle owned prefix."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile

SOURCE_INPUTS = ('file-pickers/pickers.c', 'file-pickers/ids.h',
                 'file-pickers/pickers.spec', 'file-pickers/build.sh')
CLASSES = ('Microsoft.Windows.Storage.Pickers.FileOpenPicker',
           'Windows.Storage.Pickers.FileOpenPicker',
           'Windows.Storage.Pickers.FileSavePicker', 'Windows.Storage.StorageFile')
KEY = r'Software\Microsoft\WindowsRuntime\ActivatableClassId'
DLL = r'C:\windows\system32\bedrock-pickers.dll'
RECEIPT = '.bedrock-pickers.json'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_root():
    bundle = os.environ.get('BEDROCK_BUNDLE')
    return Path(bundle) / 'scripts' if bundle else Path(__file__).resolve().parent


def verify_runtime(wine, source=None):
    source = source or source_root()
    dll = wine / 'lib/wine/x86_64-windows/bedrock-pickers.dll'
    receipt = wine / 'file-pickers-build.json'
    try:
        data = json.loads(receipt.read_text())
        if data.get('version') != 1 or set(data['source_sha256']) != set(SOURCE_INPUTS):
            raise ValueError('unexpected source receipt')
        for name, expected in data['source_sha256'].items():
            path = source / name
            if path.is_symlink() or digest(path) != expected:
                raise ValueError('bridge source changed: ' + name)
        if dll.is_symlink() or digest(dll) != data['files']['bedrock-pickers.dll']:
            raise ValueError('bridge DLL changed')
        binary = dll.read_bytes()
        if len(binary) < 64 or binary[:2] != b'MZ':
            raise ValueError('bridge is not a PE DLL')
        offset = int.from_bytes(binary[60:64], 'little')
        if binary[offset:offset + 6] != b'PE\0\0\x64\x86':
            raise ValueError('bridge is not x86-64')
        return {'dll_sha256': digest(dll), 'build_receipt_sha256': digest(receipt),
                'source_sha256': data['source_sha256']}
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise RuntimeError('The file picker bridge failed verification. Rebuild the selected Wine runtime.') from error


def registrations(prefix):
    path = prefix / 'system.reg'
    if not path.exists():
        if path.is_symlink():
            raise RuntimeError('Unexpected picker registry link.')
        return {}
    if path.is_symlink():
        raise RuntimeError('Unexpected picker registry link.')
    result, current = {}, None
    names = {(KEY + '\\' + name).lower(): name for name in CLASSES}
    for line in path.read_text().splitlines():
        if line.startswith('[') and ']' in line:
            section = line[1:line.index(']')].replace('\\\\', '\\').lower()
            current = names.get(section)
            if current:
                if current in result:
                    raise RuntimeError('Duplicate picker registry class; preserve and repair system.reg.')
                result[current] = None
        elif current and re.match(r'"dllpath"=', line, re.I):
            value = line.partition('=')[2]
            if not re.fullmatch(r'"(?:\\.|[^"\\])*"', value):
                raise RuntimeError('Unsupported picker DllPath; preserve and repair system.reg.')
            if result[current] is not None:
                raise RuntimeError('Duplicate picker DllPath; preserve and repair system.reg.')
            result[current] = re.sub(r'\\(.)', r'\1', value[1:-1])
    return result


def safe_prefix(prefix):
    # Never replace files through a symlink into another prefix or runtime.
    for relative in ('', 'drive_c', 'drive_c/windows', 'drive_c/windows/system32',
                     'drive_c/windows/system32/bedrock-pickers.dll', RECEIPT,
                     '.bedrock-pickers.reg', '.bedrock-pickers-backups'):
        if (prefix / relative).is_symlink():
            raise RuntimeError('Unexpected picker installation link: ' + relative)


def preflight(prefix):
    safe_prefix(prefix)
    previous = {}
    receipt = prefix / RECEIPT
    if receipt.exists():
        try:
            previous = json.loads(receipt.read_text())
            if not isinstance(previous, dict):
                raise ValueError('receipt must be an object')
        except (OSError, ValueError) as error:
            raise RuntimeError('Picker installation receipt needs recovery: ' + str(receipt)) from error
    mappings = registrations(prefix)
    target = prefix / 'drive_c/windows/system32/bedrock-pickers.dll'
    known = {previous.get('dll_sha256'), previous.get('previous_dll_sha256')} - {None}
    own = (previous.get('classes') == list(CLASSES) and target.is_file()
           and digest(target) in known)
    builtin = {'windows.storage.dll', r'c:\windows\system32\windows.storage.dll'}
    for name, value in mappings.items():
        normalized = value.replace('/', '\\').lower() if isinstance(value, str) else None
        if normalized == DLL.lower() and own:
            continue
        if name == 'Windows.Storage.StorageFile' and normalized in builtin:
            builtin_file = prefix / 'drive_c/windows/system32/windows.storage.dll'
            if builtin_file.is_file():
                with builtin_file.open('rb') as stream:
                    if b'Wine builtin DLL' in stream.read(128):
                        continue
            raise RuntimeError('The existing StorageFile DLL is not a recognized Wine builtin; preserve ' + str(builtin_file))
        raise RuntimeError('An existing file picker registration must be preserved: ' + name + '. Back up and inspect ' + str(prefix / 'system.reg'))
    if target.exists() and not own:
        raise RuntimeError('An unrecognized picker DLL must be preserved: ' + str(target))
    return mappings


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def install(prefix, wine, register, source=None):
    verified = verify_runtime(wine, source)
    mappings = preflight(prefix)
    target = prefix / 'drive_c/windows/system32/bedrock-pickers.dll'
    previous_hash = digest(target) if target.is_file() else None
    backup_root = prefix / '.bedrock-pickers-backups'
    backup_root.mkdir(exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix='install-', dir=backup_root))
    for name, path in (('system.reg', prefix / 'system.reg'),
                       ('bedrock-pickers.dll', target), ('receipt.json', prefix / RECEIPT)):
        if path.is_file():
            shutil.copyfile(path, backup / name)
    record = dict(verified, version=1, classes=list(CLASSES), phase='installing',
                  previous_dll_sha256=previous_hash, previous_registrations=mappings,
                  backup=str(backup.relative_to(prefix)))
    atomic_write(prefix / RECEIPT, (json.dumps(record, indent=2) + '\n').encode())
    data = (wine / 'lib/wine/x86_64-windows/bedrock-pickers.dll').read_bytes()
    if hashlib.sha256(data).hexdigest() != verified['dll_sha256']:
        raise RuntimeError('Picker DLL changed during installation; retained recovery backup: ' + str(backup))
    atomic_write(target, data)
    registry = ['Windows Registry Editor Version 5.00', '']
    for name in CLASSES:
        registry += ['[HKEY_LOCAL_MACHINE\\' + KEY + '\\' + name + ']',
                     '"DllPath"="' + DLL.replace('\\', '\\\\') + '"',
                     '"ThreadingModel"=dword:00000000', '']
    regfile = prefix / '.bedrock-pickers.reg'
    atomic_write(regfile, '\n'.join(registry).encode('utf-16'))
    register(regfile)
    record['phase'] = 'installed'
    atomic_write(prefix / RECEIPT, (json.dumps(record, indent=2) + '\n').encode())


def installed(prefix, wine):
    try:
        verified = verify_runtime(wine)
        preflight(prefix)
        data = json.loads((prefix / RECEIPT).read_text())
        return (data.get('phase') == 'installed' and data.get('dll_sha256') == verified['dll_sha256']
                and digest(prefix / 'drive_c/windows/system32/bedrock-pickers.dll') == verified['dll_sha256']
                and registrations(prefix) == {name: DLL for name in CLASSES})
    except (OSError, ValueError, RuntimeError):
        return False
