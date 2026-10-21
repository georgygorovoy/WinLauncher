#!/usr/bin/env python3
"""Local launcher worker. Only structured, credential-free status reaches the UI."""
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import runpy
# Included explicitly for the frozen worker's dynamically loaded scripts.
import xml.etree.ElementTree
import zipfile
import zlib
import datetime
import signal
import contextlib
import uuid
import tempfile
import time

FROZEN = getattr(sys, 'frozen', False)
BUNDLE = Path(os.environ['BEDROCK_BUNDLE']) if os.environ.get('BEDROCK_BUNDLE') else None
if BUNDLE and not os.environ.get('BEDROCK_HOME'):
    os.environ['BEDROCK_HOME'] = str(Path.home() / 'Library/Application Support/Bedrock for Mac')

# The frozen executable also runs the shipped Python scripts. No system Python
# or developer tools are required on the user's Mac.
if FROZEN and len(sys.argv) > 1 and sys.argv[1].endswith('.py'):
    script = Path(sys.argv[1]).resolve()
    allowed = {'standalone.py', 'standalone-setup.py', 'standalone-gameinput.py'}
    if script.name not in allowed or script.parent != Path(os.environ.get('BEDROCK_HOME', '')).resolve():
        raise SystemExit('Unknown bundled script')
    sys.argv = sys.argv[1:]
    runpy.run_path(str(script), run_name='__main__')
    raise SystemExit(0)

ROOT = Path(os.environ.get('BEDROCK_HOME', Path(__file__).resolve().parents[1]))
os.environ['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'
os.environ.update(XODUS_LOG='off', RUST_LOG='off', PYTHONUNBUFFERED='1')

ACCOUNT_ERRORS = {
    'account_timeout': 'Sign-in took too long. Check your connection, then try again.',
    'signin_cancelled': 'Sign-in was closed. Try again when you’re ready.',
    'signin_failed': 'Microsoft sign-in did not finish. Check your connection and try again.',
    'device_auth': 'Could not connect to Microsoft sign-in. Check your connection and retry.',
    'keychain_access': 'Could not access your saved sign-in. Respond to any macOS Keychain prompt, then retry.',
    'helper_stopped': 'The sign-in helper stopped unexpectedly. Open the setup log for details.',
    'helper_parent_lost': 'The setup session stopped. Try again.',
    'helper_session_missing': 'Setup could not start safely. Close and reopen the app, then try again.',
    'catalog_lookup': 'Could not find Minecraft in Microsoft’s Windows catalog. Try again shortly.',
    'account_package': 'Microsoft could not provide the game download for this account. Try again shortly.',
    'package_selection': 'Microsoft returned an unexpected set of game packages. The launcher needs an update.',
    'package_connection': 'Could not connect to Microsoft’s game download. Check your connection and retry.',
    'package_integrity': 'Microsoft’s game download could not be verified. Try again shortly.',
    'package_unavailable': 'Microsoft’s game download is unavailable. Try again shortly.',
    'package_transport': 'This download isn’t supported by this build. Check for a Bedrock for Mac update.',
    'package_size': 'Microsoft’s download size differs from its catalog. Try again shortly.',
    'package_cache': 'Could not save the download metadata. Check available disk space and retry.',
    'package_format': 'Minecraft’s download format could not be read. The launcher needs an update.',
    'package_files': 'Could not read the game’s file list. The launcher needs an update.',
    'package_segments': 'Could not read the game’s download segments. The launcher needs an update.',
    'package_filesystem': 'Could not read the game’s package filesystem. The launcher needs an update.',
    'content_license': 'Microsoft could not verify a Minecraft for Windows license for this account.',
    'download_failed': 'Minecraft preparation stopped. Open the setup log for details.',
}

BUNDLE_LINKS = {
    'runtime/standalone/wine': 'runtime/wine',
    'runtime/standalone/dxmt': 'runtime/dxmt',
    'sources/xodus/target/release/examples/standalone_helper': 'standalone_helper',
}


def event(state, title, detail='', progress=None):
    print(json.dumps(dict(state=state, title=title, detail=detail, progress=progress)), flush=True)


def load(name, filename):
    source = BUNDLE / 'scripts' / filename if BUNDLE else ROOT / filename
    spec = importlib.util.spec_from_file_location(name, source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def replace_bytes(target, contents):
    """Replace one file without opening or overwriting an existing staging path."""
    descriptor, name = tempfile.mkstemp(prefix='.' + target.name + '-', dir=target.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, 'wb') as output:
            output.write(contents)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def initialize_bundle():
    if not BUNDLE:
        return
    ROOT.mkdir(parents=True, exist_ok=True)
    for filename in ('standalone.py', 'standalone-setup.py', 'standalone-gameinput.py', 'standalone-pickers.py', 'winrt.reg'):
        source = BUNDLE / 'scripts' / filename
        target = ROOT / filename
        if target.is_symlink():
            raise RuntimeError('An unexpected file blocks app setup: ' + filename)
        if not target.exists() or target.read_bytes() != source.read_bytes():
            replace_bytes(target, source.read_bytes())
    for relative, bundled in BUNDLE_LINKS.items():
        destination = ROOT / relative
        target = BUNDLE / bundled
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.is_symlink():
            if destination.resolve() == target.resolve():
                continue
            destination.unlink()
        elif destination.exists():
            raise RuntimeError('An existing installation blocks app setup: ' + relative)
        destination.symlink_to(target)


def installed():
    if not (ROOT / 'standalone.py').is_file():
        return False
    # Status must describe this app's components, not an older app that still
    # owns the data directory's links. Only Play is allowed to change the links.
    if BUNDLE and any(not (ROOT / relative).is_symlink()
                      or (ROOT / relative).resolve() != (BUNDLE / bundled).resolve()
                      for relative, bundled in BUNDLE_LINKS.items()):
        return False
    runtime = load('standalone', 'standalone.py')
    try:
        runtime.prerequisites(ROOT / 'game')
        return runtime.HELPER.is_file() and runtime.setup_matches(runtime.setup_signature(ROOT / 'game'))
    except (OSError, RuntimeError):
        return False


def account_update(line, updating=False):
    # Only these credential-free status lines reach the user interface.
    if line.startswith(b'Keychain: requesting saved sign-in entry'):
        event('busy', 'Signing you in', 'If macOS asks, “Always Allow” remembers access to your saved sign-in.', 0.2)
    elif line.startswith((b'Finding the Windows package', b"Checking this account's Minecraft ownership.")):
        event('busy', 'Checking your Minecraft purchase', '', 0.3)
    elif line.startswith(b'Checking the signed Minecraft package header.'):
        event('busy', 'Checking download', '', 0.3)
    elif line.startswith(b'Downloading Minecraft into private staging.'):
        event('busy', 'Downloading Minecraft', 'Keep this app open.' if updating else 'Keep this app open. Minecraft will start when it’s ready.', 0.35)
    elif line.startswith(b"Checking Microsoft's game signature and package integrity."):
        event('busy', 'Checking download', 'Keep this app open.', 0.8)
    elif line.startswith(b'Downloading Minecraft '):
        event('busy', 'Preparing Minecraft', '', 0.85)
    elif line.startswith(b'Downloaded ') and b' files.' in line:
        import re
        match = re.fullmatch(rb'Downloaded (\d+)/(\d+) files\.\s*', line)
        if match:
            done, total = map(int, match.groups())
            if 0 <= done <= total and total > 0:
                event('busy', 'Preparing Minecraft', f'{done * 100 // total}%', 0.85 + 0.04 * done / total)


class Cancelled(BaseException):
    """User cancellation unwinds owned processes without reporting a failure."""


def stop_command(process):
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass  # It exited between the timeout and the final signal.
            process.wait()


def run(command, log, failure, account_progress=False):
    log.write(('\n$ ' + ' '.join(map(str, command)) + '\n').encode())
    log.flush()
    helper_error = None
    process = subprocess.Popen(list(map(str, command)), cwd=ROOT,
                               stdout=subprocess.PIPE if account_progress else log,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        if account_progress:
            # Never forward arbitrary helper output to the UI.
            for line in process.stdout:
                log.write(line)
                log.flush()
                if line.startswith(b'BEDROCK_ERROR:'):
                    helper_error = ACCOUNT_ERRORS.get(line.strip().split(b':', 1)[1].decode('ascii', errors='replace'))
                account_update(line)
        code = process.wait()
    finally:
        stop_command(process)
        if account_progress and process.stdout:
            process.stdout.close()
    if code:
        raise RuntimeError(helper_error or failure)


def validate_install():
    minimum = '15.0'
    if BUNDLE:
        candidates = (BUNDLE.parent / 'Info.plist', BUNDLE.parent.parent / 'Info.plist')
        info = next((path for path in candidates if path.is_file()), None)
        if info:
            with info.open('rb') as file:
                minimum = plistlib.load(file).get('LSMinimumSystemVersion', minimum)
    version = lambda text: tuple(int(part) for part in text.split('.'))
    if platform.machine() != 'arm64' or version(platform.mac_ver()[0] or '0') < version(minimum):
        raise RuntimeError(f'This build requires an Apple Silicon Mac with macOS {minimum} or later.')
    if subprocess.run(['/usr/bin/arch', '-x86_64', '/usr/bin/true'], capture_output=True).returncode:
        raise RuntimeError('Rosetta is required to run Minecraft. See Bedrock for Mac Help in the Help menu for Apple’s setup instructions.')
    required = (ROOT / 'runtime/standalone/wine/build-manifest.json',
                ROOT / 'runtime/standalone/dxmt/manifest.json',
                ROOT / 'sources/xodus/target/release/examples/standalone_helper')
    if not all(path.is_file() for path in required):
        raise RuntimeError('This app is missing its bundled runtime. Use a complete build of Bedrock for Mac.')
    if not (ROOT / 'game/Minecraft.Windows.exe').is_file() and shutil.disk_usage(ROOT).free < 8 * 1024**3:
        raise RuntimeError('Free up at least 8 GB for Minecraft, then try again.')


def install(log):
    event('busy', 'Preparing Minecraft', 'Checking the required Microsoft game component…', 0.9)
    run([sys.executable, ROOT / 'standalone-setup.py', '--threading'], log,
        'Could not download the Microsoft game component. Check your connection and try again.')
    event('busy', 'Finishing setup', '', 0.95)
    run([sys.executable, ROOT / 'standalone.py', 'prepare'], log,
        'Could not finish setting up the game. Open the setup log for details.')


def update_paths():
    return ROOT / '.minecraft-update', ROOT / 'game', ROOT / 'bottles/Bedrock-Standalone'


def write_update(transaction, record):
    replace_bytes(transaction / 'transaction.json', json.dumps(record).encode('utf-8'))


def finish_update(transaction, record):
    backups = ROOT / 'game-backups'
    if backups.is_symlink():
        raise RuntimeError('The game backup folder must not be a symbolic link. Your files were kept.')
    backups.mkdir(exist_ok=True)
    destination = backups / record['backup']
    if destination.exists() or destination.is_symlink():
        raise RuntimeError('An existing game backup blocks completion. Your files were kept.')
    transaction.rename(destination)
    return destination


def recover_update():
    """Restore interrupted activation using only this transaction's owned paths."""
    transaction, game, prefix = update_paths()
    if not transaction.exists() and not transaction.is_symlink():
        return
    if any(path.is_symlink() for path in (transaction, game, prefix, prefix.parent)):
        raise RuntimeError('An unexpected link blocks Minecraft recovery. Your files were kept.')
    if not any(transaction.iterdir()):
        transaction.rmdir()  # Interrupted before writing the initial journal.
        return
    try:
        record = json.loads((transaction / 'transaction.json').read_text())
        if (record['phase'] not in ('downloading', 'activating', 'preparing', 'committed', 'rolled-back')
                or type(record['had_game']) is not bool or type(record['had_prefix']) is not bool
                or record['backup'] != 'minecraft-' + uuid.UUID(record['backup'][10:]).hex):
            raise ValueError('invalid journal')
    except (OSError, ValueError, KeyError, TypeError):
        raise RuntimeError('The Minecraft update record could not be read. Your files were kept.') from None
    if record['phase'] == 'committed':
        return finish_update(transaction, record)
    if record['phase'] in ('activating', 'preparing'):
        for current, previous, discarded, existed in (
                (game, transaction / 'previous-game', transaction / 'discarded-game', record['had_game']),
                (prefix, transaction / 'previous-prefix', transaction / 'discarded-prefix', record['had_prefix'])):
            if current == prefix and record['phase'] != 'preparing':
                continue
            if any(path.is_symlink() for path in (previous, discarded)):
                raise RuntimeError('An unexpected link blocks Minecraft recovery. Your files were kept.')
            if previous.exists() or not existed:
                if current.exists():
                    if discarded.exists():
                        raise RuntimeError('Minecraft recovery found conflicting files. Your files were kept.')
                    current.rename(discarded)
                if previous.exists():
                    previous.rename(current)
            elif not current.exists():
                raise RuntimeError('A Minecraft backup is missing. Your remaining files were kept.')
    record['phase'] = 'rolled-back'
    write_update(transaction, record)
    if any((transaction / name).exists() for name in
           ('previous-game', 'previous-prefix', 'discarded-game', 'discarded-prefix')):
        # Another entry point may have saved a world after the interruption.
        # Restore the snapshot, but retain every displaced game/prefix for
        # recovery instead of silently deleting potentially newer progress.
        return finish_update(transaction, record)
    # Detach the completed rollback before deleting temporary bytes. A second
    # interruption during cleanup must not leave an unreadable active journal.
    discarded = ROOT / ('.minecraft-discard-' + uuid.uuid4().hex)
    transaction.rename(discarded)
    shutil.rmtree(discarded)


@contextlib.contextmanager
def maintenance_lock(runtime):
    path = ROOT / 'runtime/standalone/launcher.lock'
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Close Minecraft and the other launcher before continuing.') from None
        # account(download=True) can reuse an existing helper without downloading.
        # Never reuse or stop somebody else's account session during maintenance.
        if runtime.game_running():
            raise RuntimeError('Close Minecraft and the other launcher before continuing.')
        if os.path.lexists(ROOT / '.minecraft-update'):
            # A guarded helper stops itself after its worker dies. Give that
            # bounded shutdown time to complete; never signal a recorded PID.
            deadline = time.monotonic() + 2
            while runtime.account_pid() and time.monotonic() < deadline:
                time.sleep(0.05)
        if runtime.account_pid():
            raise RuntimeError('An account helper is still running. Close its Minecraft or launcher window, then retry. If no window is open, restart your Mac; your files were kept.')
        runtime.recover_account_socket()
        # A moved app can leave the old runtime link dangling. Check the same
        # prefix with the new bundled wineserver without changing any links yet.
        if BUNDLE and not (runtime.WINE / 'bin/wineserver').is_file():
            previous_wine = runtime.WINE
            try:
                runtime.WINE = BUNDLE / 'runtime/wine'
                runtime.wait_for_idle_prefix()
            finally:
                runtime.WINE = previous_wine
        else:
            runtime.wait_for_idle_prefix()
        yield


def initialize_session_bundle():
    # A standalone CLI session holds launcher.lock, not onboarding.lock. Protect
    # app replacement as well as game updates before rewriting its live inputs.
    if BUNDLE:
        runtime = load('standalone_bundle_maintenance', 'standalone.py')
        with maintenance_lock(runtime):
            initialize_bundle()
    else:
        initialize_bundle()


@contextlib.contextmanager
def update_account(runtime, destination):
    # The helper arms its own parent-lifetime guardian before sign-in. It waits
    # for account() to publish its session record before creating any socket,
    # closing the worker-death race between Popen and the record write.
    changes = {'BEDROCK_HELPER_PARENT_PID': str(os.getpid()),
               'BEDROCK_HELPER_SESSION_FILE': str(runtime.STATE)}
    previous = {key: os.environ.get(key) for key in changes}
    os.environ.update(changes)
    try:
        with runtime.account(destination, download=True,
                             progress=lambda line: account_update(line, updating=True)):
            yield
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def update_minecraft(runtime, log):
    transaction, game, prefix = update_paths()
    # Both profiles reject a different game hash even with their gate disabled.
    # Keep the playable installation intact until the source developer restores
    # these deliberately installed experiments in reverse staging order.
    for marker, tool in (('bedrock-frame-slab.json', 'standalone-bedrock-frame-profile.py'),
                         ('bedrock-refmove.json', 'standalone-bedrock-refmove.py')):
        if os.path.lexists(ROOT / 'runtime/standalone/wine' / marker):
            raise RuntimeError('Restore the local game-specific runtime profile before updating Minecraft: '
                               f'python3 {tool} restore --wine runtime/standalone/wine. '
                               'Your game and worlds were kept.')
    if any(path.is_symlink() for path in (game, prefix, prefix.parent, ROOT / 'game-backups')):
        raise RuntimeError('An unexpected link blocks Minecraft updates. Your files were kept.')
    prefix_bytes = sum(path.stat().st_size for path in prefix.rglob('*')
                       if not path.is_symlink() and path.is_file()) if prefix.exists() else 0
    if shutil.disk_usage(ROOT).free < 8 * 1024**3 + prefix_bytes:
        raise RuntimeError('Free up 8 GB plus room for a copy of your worlds and settings, then retry.')
    record = {'phase': 'downloading', 'had_game': game.exists(), 'had_prefix': prefix.exists(),
              'backup': 'minecraft-' + uuid.uuid4().hex}
    initial = Path(tempfile.mkdtemp(prefix='.minecraft-update-staging-', dir=ROOT))
    try:
        write_update(initial, record)
        initial.rename(transaction)
    finally:
        if initial.exists():
            shutil.rmtree(initial)
    try:
        event('busy', 'Updating Minecraft', 'Downloading the latest version available to your Microsoft account.', 0.2)
        with update_account(runtime, transaction / 'download'):
            run([sys.executable, ROOT / 'standalone-setup.py', '--threading'], log,
                'Could not download the Microsoft game component. Check your connection and retry.')
            runtime.prerequisites(transaction / 'download')
            event('busy', 'Keeping a backup', 'Your game and worlds will be kept.', 0.9)
            if prefix.exists():
                shutil.copytree(prefix, transaction / 'previous-prefix', symlinks=True)
            record['phase'] = 'activating'
            write_update(transaction, record)
            if game.exists():
                game.rename(transaction / 'previous-game')
            (transaction / 'download').rename(game)
            record['phase'] = 'preparing'
            write_update(transaction, record)
            event('busy', 'Finishing update', '', 0.95)
            # We already own launcher.lock. prepare() stops its owned Wine setup
            # on BaseException (including cancellation) before rollback starts.
            runtime.prepare(game)
            runtime.prerequisites(game)
            if not runtime.setup_matches(runtime.setup_signature(game)):
                raise RuntimeError('Minecraft setup could not be verified. Try the update again.')
        record['phase'] = 'committed'
        write_update(transaction, record)
    except BaseException as error:
        recovery = recover_update()
        if recovery:
            detail = 'Your previous setup was restored. Recovery copies are in game-backups; choose Help → Open Game Data.'
            if isinstance(error, Cancelled):
                raise Cancelled(detail) from error
            if isinstance(error, (OSError, RuntimeError)):
                raise RuntimeError(str(error) + ' ' + detail) from error
        raise
    finish_update(transaction, record)
    event('ready', 'Minecraft is up to date', 'Your previous game and worlds are backed up.')


def main():
    os.umask(0o077)
    if '--status' in sys.argv:
        if os.path.lexists(ROOT / '.minecraft-update'):
            event('update', 'Finish Minecraft update', 'Choose Continue to recover the interrupted update.')
            return
        ready = installed()
        if ready:
            event('ready', 'Ready to play')
        elif (ROOT / 'game/Minecraft.Windows.exe').is_file():
            event('update', 'Finish setup', 'Your game and worlds will be kept.')
        else:
            event('new', 'Minecraft on your Mac')
        return
    folder = ROOT / 'logs/standalone'
    folder.mkdir(parents=True, exist_ok=True)
    with (folder / 'onboarding.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Setup or Minecraft is already running. Return to the other launcher window.')
        if '--update-game' in sys.argv or os.path.lexists(ROOT / '.minecraft-update'):
            runtime = load('standalone_maintenance', 'standalone.py')
            with maintenance_lock(runtime):
                recover_update()
                initialize_bundle()
                validate_install()
                with (folder / 'onboarding.log').open('ab') as log:
                    if '--update-game' in sys.argv:
                        try:
                            update_minecraft(runtime, log)
                        except runtime.AccountError as error:
                            raise RuntimeError(ACCOUNT_ERRORS.get(error.code, str(error))) from error
                        return
        initialize_session_bundle()
        with (folder / 'onboarding.log').open('ab') as log:
            ready = installed()
            if '--sign-out' in sys.argv:
                helper = ROOT / 'sources/xodus/target/release/examples/standalone_helper'
                event('busy', 'Signing out')
                run([helper.resolve(), '--sign-out', ROOT / 'game'], log,
                    'Could not sign out. Close Minecraft and try again.', account_progress=True)
                event('ready' if ready else 'new', 'Signed out', 'Choose Play to sign in with another Microsoft account.' if ready else '')
                return
            validate_install()
            if (ROOT / 'game').exists() and not (ROOT / 'game/Minecraft.Windows.exe').is_file():
                raise RuntimeError('The game installation is incomplete. Choose Update Minecraft from the app menu to repair it. Your worlds will be kept.')
            runtime = load('standalone_session', 'standalone.py')
            event('busy', 'Signing you in' if ready else 'Sign in to Microsoft',
                  '' if ready else 'Use the account that owns Minecraft for Windows.', 0.2)
            try:
                # One owner keeps the same helper alive through download,
                # prefix setup and gameplay. The child launcher reuses it.
                with runtime.account(ROOT / 'game', download=not (ROOT / 'game').exists(), progress=account_update):
                    if not ready:
                        install(log)
                    event('playing', 'Minecraft is running', 'You can close this window. Quit Minecraft to end your session.')
                    run([sys.executable, ROOT / 'standalone.py', 'launch'], log,
                        'Minecraft stopped unexpectedly. Open the setup log for details, then try again.')
            except runtime.AccountError as error:
                raise RuntimeError(ACCOUNT_ERRORS.get(error.code, str(error))) from error
            event('ready', 'Ready to play')


def cancel(_signal, _frame):
    raise Cancelled()


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    try:
        main()
    except Cancelled as error:
        event('cancelled', 'Setup paused', str(error) or 'Continue when you’re ready.')
    except (OSError, RuntimeError) as error:
        event('error', 'Setup needs attention', str(error))
        sys.exit(1)
