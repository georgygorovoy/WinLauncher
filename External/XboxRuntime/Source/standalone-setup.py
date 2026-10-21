#!/usr/bin/env python3
"""Acquire the owned Windows game and Microsoft's unmodified GDK threading DLL.

--check and --dry-run never contact Microsoft, read Keychain, or modify files.
The game, Microsoft DLLs, credentials, and downloaded archives are not redistributable
parts of this source project. Each user obtains their own copies from the vendors.
"""
from pathlib import Path
import argparse
import ctypes
import fcntl
import hashlib
import io
import json
import os
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib
import xml.etree.ElementTree as ET

ROOT = Path(os.environ.get('BEDROCK_HOME', Path(__file__).resolve().parent))
XODUS = ROOT / "sources/xodus"
XODUS_COMMIT = "0670e25aeb0e0e9f800f8f2f4968ae3b681842a7"
HELPER = XODUS / "target/release/examples/standalone_helper"
GDK_NAME = "GDK_2604.4.7897.zip"
GDK_URL = "https://github.com/microsoft/GDK/releases/download/April-2026-Update-4-v2604.4.7897/" + GDK_NAME
GDK_SHA256 = "3da3f104fa66bb3ee1299b3dc8c0a3ecac1cb56a4cf04136b8595942272017eb"
GDK_SIZE = 1315537904
# Exact compressed ZIP member within the pinned, checksum-verified GDK archive.
# Fetching this byte range avoids downloading the other 1.1 GB of developer tools.
GAMING_OFFSET = 1101515484
GAMING_SIZE = 196592307
GAMING_UNPACKED_SIZE = 198332601
GAMING_SHA256 = 'f8d5f3ebe7339d9d65ebf4b4d68cb7a5281c0f944acafd613ccc68d7d908baed'
THREADING_SHA256 = "aa611155057ebd01cf315ad702a4b5725aa9d5e6fad87732c956fe0a1e5fcfba"
THREADING = ROOT / "runtime/xgameruntime.dll.threading"
PATCHES = ("xodus-real-store-license.patch", "keychain-cache.patch", "unified-helper.patch", "standalone-signin-window.patch", "standalone-keychain-write.patch", "standalone-account-transport.patch", "standalone-helper-dependencies.patch")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def amd64_pe(path):
    try:
        with path.open("rb") as stream:
            header = stream.read(64)
            if len(header) < 64 or header[:2] != b"MZ":
                return False
            stream.seek(struct.unpack_from("<I", header, 60)[0])
            return stream.read(6) == b"PE\0\0\x64\x86"
    except (OSError, ValueError, struct.error):
        return False


def game_status(directory):
    version = None
    try:
        config = ET.parse(directory / "MicrosoftGame.Config").getroot()
        identity = config.find("Identity")
        version = identity.get("Version") if identity is not None else None
        store = config.find("StoreId")
        product = store.text.strip() if store is not None and store.text else None
    except (OSError, ET.ParseError):
        product = None
    return {
        "game_directory": str(directory),
        "prepared_windows_x64_game": amd64_pe(directory / "Minecraft.Windows.exe"),
        "minecraft_store_product": product == "9NBLGGH2JHXJ",
        "package_metadata_present": (directory / ".xodus-streaming.msixvc").is_file(),
        "gameinput_installer_present": (directory / "Installers/GameInputRedist.msi").is_file(),
        "version": version,
    }


def check(directory):
    result = game_status(directory)
    result.update({
        "threading_dll_verified": THREADING.is_file() and sha256(THREADING) == THREADING_SHA256,
        "standalone_helper_built": HELPER.is_file(),
        "another_xbox_helper_socket_present": os.path.lexists("/tmp/xodus.sock"),
    })
    print(json.dumps(result, indent=2))
    return 0 if all(result[key] for key in (
        "prepared_windows_x64_game", "minecraft_store_product", "package_metadata_present",
        "gameinput_installer_present", "threading_dll_verified", "standalone_helper_built")) else 1


def acquire_threading():
    if THREADING.is_symlink():
        raise RuntimeError("The threading DLL path is a symbolic link; it was preserved.")
    if THREADING.exists():
        if sha256(THREADING) != THREADING_SHA256:
            raise RuntimeError("The existing threading DLL differs from the pinned Microsoft file; it was preserved.")
        print("Microsoft threading DLL is already verified.")
        return
    downloads = ROOT / "downloads"
    downloads.mkdir(exist_ok=True)
    archive = downloads / GDK_NAME
    if archive.is_symlink():
        raise RuntimeError("The GDK archive path is a symbolic link; it was preserved.")
    if not archive.exists():
        partial = archive.with_suffix(".zip.part")
        if partial.is_symlink():
            raise RuntimeError("The GDK partial download is a symbolic link; it was preserved.")
        partial_size = partial.stat().st_size if partial.exists() else 0
        if partial_size > GDK_SIZE:
            raise RuntimeError("The GDK partial download is larger than the pinned release; it was preserved.")
        if partial_size == GDK_SIZE:
            if sha256(partial) != GDK_SHA256:
                raise RuntimeError("The downloaded GDK failed checksum validation; the partial file was preserved.")
            exclusive_rename(partial, archive)
    if not archive.exists():
        payload = download_threading_member(downloads)
    else:
        if archive.stat().st_size != GDK_SIZE or sha256(archive) != GDK_SHA256:
            raise RuntimeError("The GDK archive differs from Microsoft's published release digest; it was preserved.")
        payload = extract_threading(archive)
    THREADING.parent.mkdir(exist_ok=True)
    atomic_write(THREADING, payload)
    print("Extracted and verified Microsoft's unmodified x64 threading DLL.")


def threading_from_bundle(data):
    with zipfile.ZipFile(io.BytesIO(data)) as bundle:
        package = 'GamingServicesTcui-Package_35.116.29001.0_x64.appx'
        with zipfile.ZipFile(io.BytesIO(bundle.read(package))) as appx:
            matches = [name for name in appx.namelist() if name.lower() == 'xgameruntime.dll']
            if len(matches) != 1:
                raise RuntimeError('The pinned Gaming Services package has an unexpected layout.')
            payload = appx.read(matches[0])
    if hashlib.sha256(payload).hexdigest() != THREADING_SHA256:
        raise RuntimeError("Microsoft's extracted threading DLL failed checksum validation.")
    return payload


def download_threading_member(downloads):
    if shutil.disk_usage(downloads).free < GAMING_SIZE + 256 * 1024 * 1024:
        raise RuntimeError('Not enough free space for the Microsoft component.')
    print('Downloading the Microsoft game component (197 MB).', flush=True)
    with tempfile.TemporaryDirectory(prefix='.gaming-', dir=downloads) as temporary:
        partial = Path(temporary) / 'member.deflate'
        response = subprocess.check_output([
            '/usr/bin/curl', '--disable', '--fail', '--location', '--retry', '3', '--silent', '--show-error',
            '--proto', '=https', '--proto-redir', '=https', '--max-filesize', str(GAMING_SIZE),
            '--range', f'{GAMING_OFFSET}-{GAMING_OFFSET + GAMING_SIZE - 1}',
            '--output', str(partial), '--write-out', '%{http_code}', GDK_URL], text=True)
        if response != '206' or partial.stat().st_size != GAMING_SIZE or sha256(partial) != GAMING_SHA256:
            raise RuntimeError('Microsoft component download failed verification. Please retry.')
        data = zlib.decompress(partial.read_bytes(), -15)
        if len(data) != GAMING_UNPACKED_SIZE:
            raise RuntimeError('Microsoft component has an unexpected size.')
        return threading_from_bundle(data)


def extract_threading(archive):
    # Read exact members rather than extracting arbitrary archive paths.
    with zipfile.ZipFile(archive) as gdk:
        return threading_from_bundle(gdk.read('Installers/GamingServices.appxbundle'))


def atomic_write(path, payload):
    if path.is_symlink():
        raise RuntimeError("Refusing to replace a symbolic link: " + str(path))
    fd, temporary = tempfile.mkstemp(prefix="." + path.name + "-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def exclusive_rename(source, destination):
    """Promote completed local data atomically without replacing a racing path."""
    if sys.platform != "darwin":
        raise RuntimeError("Installation promotion currently requires macOS.")
    library = ctypes.CDLL(None, use_errno=True)
    rename = library.renamex_np
    rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 0x00000004) != 0:  # RENAME_EXCL
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))


def command_output(command):
    return subprocess.check_output(command, text=True).strip()


def prepare_source():
    if XODUS.is_symlink():
        raise RuntimeError("The Xodus source path is a symbolic link; it was preserved.")
    if not XODUS.exists():
        XODUS.parent.mkdir(exist_ok=True)
        # Interrupted cloning/patching leaves no poisoned final checkout. Only our
        # private staging directory is removed on failure; rerunning can retry.
        with tempfile.TemporaryDirectory(prefix=".xodus-setup-", dir=XODUS.parent) as temporary:
            candidate = Path(temporary) / "source"
            subprocess.run(["git", "clone", "--no-checkout", "https://github.com/xodus-gaming/xodus.git", str(candidate)], check=True)
            subprocess.run(["git", "-C", str(candidate), "checkout", "--detach", XODUS_COMMIT], check=True)
            for patch in PATCHES:
                subprocess.run(["git", "-C", str(candidate), "apply", str(ROOT / "patches" / patch)], check=True)
            shutil.copyfile(ROOT / "patches/Cargo.lock", candidate / "Cargo.lock")
            exclusive_rename(candidate, XODUS)
    if command_output(["git", "-C", str(XODUS), "rev-parse", "HEAD"]) != XODUS_COMMIT:
        raise RuntimeError("The Xodus source checkout is not at the pinned commit; it was preserved.")
    # Existing checkouts are never patched implicitly while an older helper runs.
    for relative, marker in (
        ("crates/xodus/src/secrets.rs", "pub fn init_named_secrets"),
        ("crates/xodus/src/tokens/backend/cached.rs", "struct CachedBackend"),
        ("crates/xodus-service/src/lib.rs", "pub async fn run"),
        ("crates/xodus/src/licensing/store.rs", "StoreLicenseSession"),
    ):
        path = XODUS / relative
        if not path.is_file() or marker not in path.read_text():
            raise RuntimeError("The Xodus checkout is missing required patches. Prepare a fresh pinned source checkout.")
    import importlib.util
    spec = importlib.util.spec_from_file_location("bedrock_bootstrap", ROOT / "bootstrap-sources.py")
    bootstrap = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bootstrap)
    bootstrap.copy_helper_inputs(XODUS, ROOT)
    bootstrap.verify_project(XODUS, "xodus", bootstrap.PROJECTS["xodus"], ROOT)
    if sha256(XODUS / "Cargo.lock") != sha256(ROOT / "patches/Cargo.lock"):
        raise RuntimeError("The Xodus lockfile differs from the pinned dependency lockfile; it was preserved.")


def build_helper(jobs):
    for program in ("git", "cargo", os.environ.get("PROTOC", "protoc")):
        if not shutil.which(program):
            raise RuntimeError("Missing build dependency: " + program + ". The helper requires Git, Rust 1.98.0, and Protocol Buffers (protoc).")
    processes = command_output(["/bin/ps", "-axo", "comm="]).splitlines()
    if any(line.strip() == str(HELPER) or line.strip().endswith("/standalone_helper") for line in processes):
        raise RuntimeError("Close the standalone game and its account helper before rebuilding that helper.")
    prepare_source()
    # Only this new example is built; the running bedrock_helper binary is untouched.
    env = dict(os.environ, XODUS_LOG="off", RUST_LOG="off")
    subprocess.run(["cargo", "+1.98.0", "build", "--manifest-path", str(XODUS / "Cargo.toml"),
                    "--release", "--locked", "--no-default-features", "-j", str(jobs), "-p", "xodus-cli", "--example", "standalone_helper"],
                   cwd=ROOT, env=env, check=True)
    print("Built standalone account helper: " + str(HELPER))


def download_game(directory, market):
    status = game_status(directory)
    if all(status[key] for key in ("prepared_windows_x64_game", "minecraft_store_product", "package_metadata_present", "gameinput_installer_present")):
        print("The owned Windows game is already prepared; no sign-in or download needed.")
        return
    if os.path.lexists("/tmp/xodus.sock"):
        raise RuntimeError("Close Minecraft and stop its existing account helper before account setup. The live session was not touched.")
    processes = command_output(["/bin/ps", "-axo", "comm="]).splitlines()
    if any(line.strip().lower().endswith(("\\minecraft.windows.exe", "/minecraft.windows.exe")) for line in processes):
        raise RuntimeError("Close Minecraft before downloading a new installation.")
    if directory.exists() or directory.is_symlink():
        raise RuntimeError("The game directory exists but is incomplete. Choose a new --game-dir; existing files were preserved.")
    if not HELPER.is_file():
        raise RuntimeError("Build the standalone account helper first with --build-helper.")
    env = dict(os.environ, XODUS_LOG="off", RUST_LOG="off")
    subprocess.run([str(HELPER.resolve()), "--download", str(directory), "--market", market], cwd=ROOT, env=env, check=True)
    status = game_status(directory)
    if not all(status[key] for key in ("prepared_windows_x64_game", "minecraft_store_product", "package_metadata_present", "gameinput_installer_present")):
        raise RuntimeError("The downloaded game did not pass the Windows installation check.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Inspect existing files without network or account access")
    parser.add_argument("--dry-run", action="store_true", help="Show requested actions without modifying files or accessing the network/account")
    parser.add_argument("--threading", action="store_true", help="Acquire the pinned official Microsoft GDK threading DLL")
    parser.add_argument("--build-helper", action="store_true", help="Build the separate unified standalone helper from pinned Xodus source")
    parser.add_argument("--download-game", action="store_true", help="Sign in and download the owned Windows PC game to a new directory")
    parser.add_argument("--game-dir", type=Path, default=ROOT / "game")
    parser.add_argument("--market", default="CA", help="Two-letter country code used for Store/license requests (default CA)")
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if len(args.market) != 2 or not args.market.isascii() or not args.market.isupper() or not args.market.isalpha():
        parser.error("--market must be a two-letter uppercase country code")
    if not 1 <= args.jobs <= 12:
        parser.error("--jobs must be between 1 and 12")
    directory = args.game_dir.expanduser().absolute()
    actions = [(args.threading, "Verify/acquire Microsoft's pinned threading DLL"),
               (args.build_helper, "Build the new standalone_helper example; preserve bedrock_helper"),
               (args.download_game, "Download and license the owner's Minecraft Windows game to " + str(directory))]
    if args.dry_run:
        for requested, description in actions:
            if requested:
                print(description)
        if not any(flag for flag, _ in actions):
            print("No setup actions requested. Use --check for an offline installation report.")
        return 0
    if args.check:
        if any(flag for flag, _ in actions):
            parser.error("--check cannot be combined with setup actions")
        return check(directory)
    if not any(flag for flag, _ in actions):
        parser.print_help()
        return 0
    os.umask(0o077)
    state_dir = ROOT / "runtime/standalone"
    state_dir.mkdir(parents=True, exist_ok=True)
    with (state_dir / "setup.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another standalone setup is already running.")
        if args.threading:
            acquire_threading()
        if args.build_helper:
            build_helper(args.jobs)
        if args.download_game:
            download_game(directory, args.market)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, RuntimeError, ValueError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print("Setup: " + str(error), file=sys.stderr)
        sys.exit(1)
