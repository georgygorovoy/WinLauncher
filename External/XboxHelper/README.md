# WinLauncher Xbox account helper boundary

This directory is a **separate GPL-3.0 component**. It is not linked into the
MIT-licensed Swift application. WinLauncher starts one executable and exchanges
only command-line arguments, exit status, and a diagnostic log.

The helper's narrow responsibilities are:

1. show Microsoft's sign-in window;
2. keep account tokens in macOS Keychain;
3. verify that the signed-in account owns Minecraft for Windows;
4. download, authenticate, and prepare that owned Windows package;
5. serve the Xbox IPC endpoint while the game runs.

The checked-in `Sources/standalone-helper.rs` and `standalone-xvd.rs` are
unchanged copies from `1JRobertson/bedrock-mac` commit
`4b42c46131fd5b53cae7588773cac2d601471c2f`. They extend Xodus and remain GPL-3.0.
The complete corresponding build inputs are fetched and pinned by `build.sh`.

No Minecraft files, Microsoft credentials, Microsoft runtime binaries, or game
licenses are included in this repository.

## Developer build

Requirements: Git, Rust toolchain 1.98.0, and Protocol Buffers (`protoc`). Then:

```sh
External/XboxHelper/build.sh
```

The resulting executable is written to `External/XboxHelper/bin/standalone_helper`.
Release packaging must copy it to `WinLauncher.app/Contents/Resources/XboxHelper/`
and ship the exact GPL source archive and notices beside the release download.

The locally verified ARM64 candidate has SHA-256:

```text
cce9d9cc3cf72b9acf03eaae413be6f16bf838c1141ffcfa9ab182e416580ff4
```

`CorrespondingSource/` is bound to that exact binary hash. It records 436 Rust
packages, 796 notice texts, and 450 source inputs with no unresolved notices.
