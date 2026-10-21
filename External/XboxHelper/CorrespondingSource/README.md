# Helper notice and corresponding-source candidate

Verify/reconstruct into a new directory using Python 3.11+:

```sh
python3 reconstruct.py /absolute/path/to/new-source-directory
cd /absolute/path/to/new-source-directory/xodus
cargo +1.98.0 build --release --locked --no-default-features -j 4 -p xodus-cli --example standalone_helper
```

`reconstruct.py` checks every recorded source/archive hash before extraction. It
restores patched Xodus source, exact git source snapshots and original registry
`.crate` archives. It does not execute source or compile. Provision the recorded
Rust toolchain, protoc, macOS SDK/command-line tools, and native build prerequisites
separately. Cargo may fetch dependencies using the original pinned lockfile;
these archives are source materials, **not a configured offline Cargo vendor tree**.
A clean isolated reconstruction/build remains required before a reproducibility claim.

The generator replays the pinned upstream Xodus patches in a temporary directory
and compares every supplied source file, excluding only `.git` and `target`.
Unknown source files, symlinks, changed files and missing files cause failure.
The helper's hash binds the report to the supplied binary; it does not prove
that this binary was built from these sources without trusted build evidence.

`index.json` records the selected target/features, crate checksums, Git commits,
source URLs, source/notice hashes and unresolved license text. The conservative
normal/build graph includes build tools and proc-macros. It is not a linker-level
inventory. Native build observations are in `native-build-evidence.json`.

Seven eappx prebuilt sample-package/certificate/signature/content-key fixtures
are excluded when present and explicitly listed in its source record. Library
source is preserved; the omitted fixture tests cannot run from this candidate.
Unchanged published source crates may contain public test keys/certificates;
these are upstream fixtures, not private account credentials.

Unknown/missing notices remain explicit; do not invent copyright holders or use
moving upstream HEAD as evidence for old package versions. Unresolved notices
in this selected graph: none recorded.
This is a bounded evidence inventory, not a blanket license assurance.

`internal/` contains local machine paths and is private build evidence. Bulk
notices/source archives are generated build output; never add these directories
recursively to the public source allowlist or the app bundle. No game, account,
Keychain, save or compiled target data is collected. This is preparation evidence,
not blanket legal assurance or permission to publish.
