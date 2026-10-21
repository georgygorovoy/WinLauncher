#!/usr/bin/env python3
"""Fetch pinned upstream source trees and apply the reviewed local patches."""

import argparse
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent
PROJECTS = {
    "xodus": {
        "url": "https://github.com/xodus-gaming/xodus.git",
        "commit": "0670e25aeb0e0e9f800f8f2f4968ae3b681842a7",
        "patches": ("xodus-real-store-license.patch", "keychain-cache.patch", "unified-helper.patch", "standalone-signin-window.patch", "standalone-keychain-write.patch", "standalone-account-transport.patch", "standalone-helper-dependencies.patch"),
    },
    "winegdk": {
        "url": "https://github.com/Sightem/WineGDK.git",
        "commit": "b5d23b074cfd5e28e79acceaaefaf41a26ce6272",
        "patches": ("winegdk-macos-local.patch", "minecraft-store-callback.patch"),
    },
    "dxmt": {
        "url": "https://github.com/3Shain/dxmt.git",
        "commit": "589adb780354b461645b29999cefaf533594ee99",
        "patches": (),
    },
}


HELPER_INPUTS = {
    "standalone-helper.rs": "crates/xodus-cli/examples/standalone_helper.rs",
    "standalone-xvd.rs": "crates/xodus-cli/examples/standalone_xvd.rs",
    "LICENSES/XVD-GreenGamesPublicKey.rsa": "crates/xodus-cli/examples/standalone_xvd_key.rsa",
}


def copy_helper_inputs(root, source_root=ROOT):
    """Copy the three project-owned build inputs without following source/destination links."""
    pairs = [(source_root / source, root / destination) for source, destination in HELPER_INPUTS.items()]
    for source, target in pairs:
        for path, boundary in ((source, source_root), (target, root)):
            while True:
                if path.is_symlink():
                    raise ValueError("Symlink helper source input: " + str(path))
                if path == boundary:
                    break
                path = path.parent
        if not source.is_file():
            raise ValueError("Missing helper source input: " + str(source))
    for source, target in pairs:
        data = source.read_bytes()
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_file() and target.read_bytes() == data:
            continue
        fd, temporary = tempfile.mkstemp(prefix=".helper-source-", dir=target.parent)
        try:
            with os.fdopen(fd, "wb") as output:
                output.write(data)
            os.chmod(temporary, 0o644)
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)


def run(*args, cwd=None, capture=False):
    return subprocess.run(args, cwd=cwd, check=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def patch_paths(patches):
    paths = set()
    for patch in patches:
        for line in patch.read_text(encoding="utf-8").splitlines():
            match = re.match(r"^(?:--- a/|\+\+\+ b/)([^\t]+)(?:\t.*)?$", line)
            if not match:
                continue
            name = match.group(1)
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or str(path) != name or "\\" in name:
                raise ValueError("Unsafe patch path: " + name)
            paths.add(name)
    return sorted(paths)


def apply_project(root, name, project, source_root=ROOT):
    for patch in project["patches"]:
        file = source_root / "patches" / patch
        run("git", "apply", "--check", str(file), cwd=root)
        run("git", "apply", str(file), cwd=root)
    if name == "xodus":
        shutil.copyfile(source_root / "patches/Cargo.lock", root / "Cargo.lock")
        copy_helper_inputs(root, source_root)


def bootstrap(destination, names, source_root=ROOT):
    destination = Path(destination).absolute()
    if destination.is_symlink():
        raise ValueError("Source destination must not be a symlink")
    destination.mkdir(parents=True, exist_ok=True)
    destination = destination.resolve()
    for name in names:
        target = destination / name
        if target.exists() or target.is_symlink():
            raise ValueError(f"{target} already exists; use --check to verify it")
    for name in names:
        project = PROJECTS[name]
        temp = Path(tempfile.mkdtemp(prefix=f".{name}-bootstrap-", dir=destination))
        try:
            run("git", "init", "--quiet", str(temp))
            run("git", "remote", "add", "origin", project["url"], cwd=temp)
            run("git", "fetch", "--depth", "1", "origin", project["commit"], cwd=temp)
            run("git", "checkout", "--quiet", "--detach", "FETCH_HEAD", cwd=temp)
            actual = run("git", "rev-parse", "HEAD", cwd=temp, capture=True).decode().strip()
            if actual != project["commit"]:
                raise ValueError(f"Unexpected {name} source revision")
            apply_project(temp, name, project, source_root)
            if (destination / name).exists() or (destination / name).is_symlink():
                raise ValueError(f"Destination {name} appeared during preparation")
            temp.rename(destination / name)
        except BaseException:
            shutil.rmtree(temp)
            raise
        print(f"Prepared {name} at {project['commit']}", flush=True)


def verify_project(repository, name, project, source_root=ROOT):
    """Replay patches without mutation; Xodus additionally checks every source input."""
    repository = Path(repository)
    if repository.is_symlink():
        raise ValueError("Refusing a symlink source checkout")
    actual = run("git", "rev-parse", "HEAD", cwd=repository, capture=True).decode().strip()
    if actual != project["commit"]:
        raise ValueError(f"{name} is not at the pinned source revision")
    patches = [source_root / "patches" / patch for patch in project["patches"]]
    paths = patch_paths(patches)
    tracked = {}
    for entry in run("git", "ls-tree", "-rz", project["commit"],
                     cwd=repository, capture=True).decode().split("\0"):
        if entry:
            metadata, path = entry.split("\t", 1)
            tracked[path] = metadata.split()[0]
    if name == "xodus":
        # Cargo can compile unpatched modules and auto-discover build.rs files.
        # Marker strings or only checking patched files is not a source boundary.
        paths = sorted(set(paths) | set(tracked))
        expected = set(paths) | {"Cargo.lock"} | set(HELPER_INPUTS.values())
        for directory, directories, files in os.walk(repository):
            relative = Path(directory).relative_to(repository)
            if relative == Path("."):
                directories[:] = [item for item in directories if item not in (".git", "target")]
            for item in [*directories, *files]:
                target = Path(directory) / item
                path = target.relative_to(repository).as_posix()
                if target.is_symlink() or (target.is_file() and path not in expected):
                    raise ValueError("Unexpected Xodus source input: " + path)
    with tempfile.TemporaryDirectory(prefix="bedrock-source-check-") as temp:
        prepared = Path(temp)
        for path in paths:
            if path in tracked:
                target = prepared / path
                target.parent.mkdir(parents=True, exist_ok=True)
                if tracked[path] not in ("100644", "100755"):
                    raise ValueError("Unsupported pinned source type: " + path)
                target.write_bytes(run("git", "show", project["commit"] + ":" + path,
                                       cwd=repository, capture=True))
                target.chmod(0o755 if tracked[path] == "100755" else 0o644)
        apply_project(prepared, name, project, source_root)
        if name == "xodus":
            paths = sorted(set(paths) | {"Cargo.lock"} | set(HELPER_INPUTS.values()))
        for path in paths:
            target = repository / path
            if target.is_symlink() or not target.is_file():
                raise ValueError(f"Missing regular patched source file: {name}/{path}")
            if target.read_bytes() != (prepared / path).read_bytes():
                raise ValueError(f"Source differs from preserved patches: {name}/{path}")
    return len(paths)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=ROOT / "sources")
    parser.add_argument("--project", choices=("all", *PROJECTS), default="all")
    parser.add_argument("--check", action="store_true",
                        help="verify existing patched files offline, without changing them")
    args = parser.parse_args()
    names = tuple(PROJECTS) if args.project == "all" else (args.project,)
    try:
        if args.check:
            for name in names:
                count = verify_project(args.destination / name, name, PROJECTS[name])
                print(f"Verified {name}: pinned revision and {count} patched files")
        else:
            bootstrap(args.destination, names)
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"Source preparation stopped: {exc}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
