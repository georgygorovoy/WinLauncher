# Historical frozen Python worker license input

This inventory applies only to the PyInstaller worker shipped in WinLauncher
1.2.0. Version 1.2.1 and later use the pinned portable CPython distribution in
`../portable-python.lock`; this directory is retained as historical build
evidence and is not copied into the current application runtime.

Copy only `licenses/` into the candidate's license resources, and retain `index.json`
as component/source evidence. Do not copy `internal/`, source archives, build receipts,
or build formula files into the app. Re-run against RC2's final worker and TOCs.

The collection includes CPython's PSF/history license, exact-version embedded-code
license documentation and source notice blocks (including HACL*), PyInstaller's full
GPL/bootloader exception/Apache terms, and the worker's actual bundled native-library
notices. HACL copyright naming Microsoft does not make this a proprietary Microsoft
payload; this is the unchanged MIT notice from CPython's open-source hash code.

For this inspected worker, Python 3.14.8_3 has 42 compiled extensions. OpenSSL 3.6.3,
XZ/liblzma 5.8.4, mpdecimal 4.0.1 and zstd 1.5.7_1 (Homebrew package version) are bundled.
The library component of XZ is 0BSD; other XZ utility licenses included by its source
package do not establish that those utilities were shipped. BSD terms are available
for zstd; its upstream GPL alternative is preserved without claiming GPL was chosen.
System zlib, libbz2, libffi and libexpat are not bundled copies.

PyInstaller bootloader/loader terms contain an embedding exception; runtime hooks
have Apache-2.0 terms. The exception does not remove Python/native dependency terms.
No unrelated venv package is labeled shipped merely because it was installed.

Source archives are checksum-verified against the exact installed Homebrew formula
or PyPI release metadata. Source URLs/digests and formula/receipt evidence are retained.
Homebrew patches and complete bottle build inputs are not fully reconstructed; do not
claim a from-source reproducible worker. The index maps each compiled extension to
its exact CPython release source and every binary to its recorded TOC input. It records
both complete-file hashes and code-section comparisons across packaging/signing.

Unicode 16.0.0 is identified from CPython's generated database. Its versioned database
notice and the current official Unicode License V3 are preserved unchanged; the latter
is explicitly not claimed to be an archived 2024 license file.

This is component evidence and packaging input, not blanket legal assurance or a
publication approval. Keep the project's GPL source/notice material alongside this
worker dependency collection.
