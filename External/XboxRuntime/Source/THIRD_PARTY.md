# Licensing and upstream work

The original scripts, documentation, probes, and Xodus helper additions in this
source package are offered under GNU GPL version 3; see [LICENSE](LICENSE).
The WineGDK patches are covered by GNU LGPL version 2.1 or later, preserving their
upstream terms. Existing per-file notices continue to apply. This is a collection
of compatibility work, not an independently implemented Windows or Xbox runtime.

| Component | Source revision | License and attribution |
| --- | --- | --- |
| Xodus | [xodus-gaming/xodus](https://github.com/xodus-gaming/xodus/tree/0670e25aeb0e0e9f800f8f2f4968ae3b681842a7) | GPLv3; Xodus contributors. The root [LICENSE](LICENSE) is an unchanged copy of this revision's license. |
| WineGDK and Wine | [Sightem/WineGDK](https://github.com/Sightem/WineGDK/tree/b5d23b074cfd5e28e79acceaaefaf41a26ce6272) | LGPL 2.1 or later; Wine project authors and WineGDK contributors. Upstream XUser identifies Olivia Ryan. See the unchanged [notice](LICENSES/Wine-NOTICE.txt), [license](LICENSES/Wine-LGPL-2.1-or-later.txt), and upstream AUTHORS/per-file notices. |
| macOS Store/runtime integration | [wtfsayo/cricket26-crossover](https://github.com/wtfsayo/cricket26-crossover/tree/81c7a2f80023a9f03fc42fbc16f491d97306c54b) | GPLv3 for original scripts and Xodus-derived work; its README expressly retains LGPL terms for Wine-derived patches. Credit belongs to that repository's contributors and the upstream authors identified there. |
| GameInput MSI/CAB reader | [Wyze3306/BedrockOnLinux](https://github.com/Wyze3306/BedrockOnLinux/tree/7a315c836b7ae8068042bc466b0540c16ffe3a5e) | MIT; BedrockOnLinux contributors. The adapted OLE/MSZIP reader in `standalone-gameinput.py` preserves the full upstream notice. Microsoft payloads are obtained from the owned game's installer and are not included here. |
| DXMT 0.80 | [3Shain/dxmt](https://github.com/3Shain/dxmt/tree/589adb780354b461645b29999cefaf533594ee99) | MIT at this revision; copyright 2023 Feifan He. The [license](LICENSES/dxmt-LICENSE.txt) is copied unchanged. Its vendored code carries additional [DXVK](LICENSES/dxmt-DXVK-LICENSE.txt), [LLVM](LICENSES/dxmt-LLVM-LICENSE.txt), and [MinGW](LICENSES/dxmt-MinGW-LICENSE.txt) notices. |

`patches/xodus-real-store-license.patch` and `patches/winegdk-macos-local.patch`
are unchanged copies from the reference revision above. The first is GPLv3;
the second is LGPL 2.1 or later. `patches/minecraft-store-callback.patch`
modifies the reference WineGDK implementation and retains LGPL 2.1 or later.
`patches/keychain-cache.patch`, `patches/unified-helper.patch`,
`bedrock-helper.rs`, `standalone-helper.rs`, and `prepare-owned-game.rs` extend
Xodus under GPLv3. `patches/standalone-wine-dxmt-abi.patch` changes Wine's macOS
driver, `patches/standalone-wine-idl-list.patch` fixes a duplicate install entry,
and `patches/standalone-wine-storage-linkage.patch` fixes C/C++ linkage in
the storage module. `patches/standalone-wine-user-privileges.patch` implements
account privilege and age-group checks using authenticated Xbox display claims.
`patches/standalone-wine-xuser-realms.patch` maps the exact Realms API hosts to
their original XSTS audience, cross-checked against BedrockOnLinux's runtime.
All five Wine patches retain LGPL 2.1 or later.
`patches/standalone-wine-xuser-token-refresh.patch` and
`patches/standalone-wine-xuser-z-device-auth.patch` also retain LGPL 2.1 or later;
they extend token renewal and device/title authentication in WineGDK.
Build scripts and the pinned Cargo lockfile use the same upstream dependencies;
each dependency retains its own license and notices.

`patches/standalone-signin-window.patch` changes the Xodus login window title to
“Microsoft sign-in” for the native launcher; it retains Xodus's GPLv3 license.
The native launcher and packaging scripts are original GPLv3 project code.
`patches/standalone-keychain-write.patch` adds a direct dependency on the already
pinned `security-framework` 3.7.0 crate for Keychain updates that do not reread
secrets. The patch retains GPLv3; security-framework retains its MIT/Apache-2.0
licensing.

`standalone-xvd.rs` is original GPLv3 verification code using the already pinned
`rsa` 0.9.10 crate (MIT/Apache-2.0) with its SHA-256 feature. The build includes
only the 539-byte production verification public key documented in
[LICENSES/XVD-PUBLIC-KEY-PROVENANCE.txt](LICENSES/XVD-PUBLIC-KEY-PROVENANCE.txt).
This mathematical public key grants no Microsoft software or game license.
The Microsoft DLL used to verify its origin is private audit evidence and is
not included in source exports or app resources. Existing helper notice bundles
remain tied to their recorded binary; the changed helper needs a fresh inventory.

The WineGDK startup fixes reuse its `windows.web`, `twinapi.appcore`,
`windows.ui.core.textinput`, and `wintypes` implementations. Their full source
and notices are in the pinned WineGDK tree fetched by `bootstrap-sources.py`.

No license in this package grants rights to Minecraft, its assets or trademarks,
Microsoft's GDK/GameInput DLLs, CrossOver, D3DMetal, Apple SDKs, or Rosetta. These
items are not included in source exports. Users obtain their own legitimate
game and any separately required components. Microsoft account sign-in and
server-issued ownership licenses are still required by the existing preparation
path. This project is not affiliated with Microsoft, Mojang, CodeWeavers, or Apple.

The source exporter is not a binary redistribution tool. Before distributing a
compiled runtime, inventory every bundled dependency and include the applicable
notices and corresponding source/build materials for the exact binary versions.
Do not present a third-party runtime as wholly original project code.

## Standalone runtime dependency provenance

Earlier local Wine builds obtained x86-64 native dependencies, including GnuTLS and FreeType,
from [Gcenx's Wine 11.8 macOS archive](https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.8/wine-devel-11.8-osx64.tar.xz):

```text
SHA-256: 5c9f0984961ee6289f4f2c4fe751c27f02b6c28855154e3f99b7e2bd8108b620
```

The Wine runtime itself is built from the pinned WineGDK sources. Extracting these
native dependencies locally does not make them original project code or establish
their binary redistribution status. Their component-specific licenses, notices,
and source requirements still need inventory before any binary bundle is shipped.
The archive, extracted libraries, and compiled Wine are excluded from this source
release.

`build-standalone-graphics.sh` retrieves a pinned official DXMT 0.80 binary release
for local use, verifies its SHA-256, and saves the source revision and notices.
The optional `standalone-dxmt-shared.py` build applies
`patches/standalone-dxmt-shared-buffers.patch` to that pinned source revision and
rebuilds the Windows graphics DLL locally. Its `--packed-constants` profile also
applies `patches/standalone-dxmt-packed-constants.patch`, reusing the existing
DXMT page allocator for DEFAULT constant buffers on Apple GPUs. Its
`--reuse-input-layout` profile additionally applies
`patches/standalone-dxmt-input-layout-reuse.patch`, preserving already prepared
pipelines when an identical input layout is rebound in ordinary VS/PS rendering.
It reuses the verified upstream Metal
shader library and native bridge. The source export includes the build script,
patch, probes, correctness test, and unchanged license texts; it excludes compiled
and downloaded graphics binaries.
Additional [embedded upstream notices](LICENSES/DXMT-embedded-NOTICES.txt) identify
the Microsoft DXBC parser and utilities credited to Philip Rebohle and Alexander
Bessonov. This collection preserves known attribution; it is not a completed
license audit of a future binary bundle.

The optional `patches/experimental-wine-heap-reuse.patch` retains Wine's LGPL
2.1-or-later terms. Its process-heap 48-byte LFH group-cache experiment follows
[Roritharr/bedrock-on-macos performance research](https://github.com/Roritharr/bedrock-on-macos/blob/main/docs/performance.md)
and that project's `patches/wine/lfh48-group-cache.patch`. Credit for identifying
this optimization belongs to that project. Local tests evaluate it separately
with WineGDK 11.8 and DXMT on M4 Pro; upstream benchmark results are not our results.
`standalone-wine-heap.py` records the exact local patch, source-input and artifact
checksums and provides explicit staging and rollback. The experimental filename
keeps it outside the standard Wine builder's automatic patch selection.

The separate `patches/experimental-bedrock-refmove.patch` is a local Wine loader
experiment under Wine's LGPL 2.1-or-later terms. It transfers existing allocator
ownership instead of copying and immediately releasing the same reference in
one exact, checksum-verified Bedrock executable. It changes only the loaded
process image; the source export contains no game executable or game assets.
`standalone-bedrock-refmove.py` records the reviewed Wine sources and frozen
artifact, defaults to disabled, and provides verified staging and rollback.
This experiment is independent of the LFH cache optimization credited above.

## October 7, 2026 binary inventory review

**The binary distribution inventory is incomplete.** An isolated review found
20 native libraries (30 paths including symlinks) in the Wine dependency closure.
The Gcenx archive digest identifies the downloaded archive, but does not identify
the exact source, patches and license terms for each compiled library.

| Native dependency group | Observed evidence | Still required |
| --- | --- | --- |
| Brotli, bzip2, zlib, zstd | Filenames suggest 1.1.0, 1.0.8, 1.3.1, 1.5.6 respectively | Verify versions against exact build records; retain source, patches and notices |
| GnuTLS, FreeType, GMP, Nettle/Hogweed, libiconv, libidn2, gettext/libintl, p11-kit, libpng, libtasn1, libunistring, libffi | Hashed local dylibs and load-command dependency closure | Exact upstream versions and distributor port/overlay revisions; applicable notices and source materials |
| MacPorts Legacy Support | `libMacportsLegacySupport.dylib` | Exact compiled source/file list; upstream contains mixed MIT and Apple Public Source License 2.0 terms |

[MacPorts Legacy Support's license](https://github.com/macports/macports-legacy-support/blob/master/LICENSE)
must be evaluated per included file; do not label this whole library MIT.
[Gcenx's upstream repository](https://github.com/Gcenx/macOS_Wine_builds) identifies
MacPorts and its overlay as dependency sources. Exact build records or a new
pinned-source dependency build are needed before public binary distribution.
ABI filenames alone are not source-version evidence.

The helper lockfile contains 690 packages across platforms. A lockfile inventory
is a superset, not a list of code linked into the macOS helper. Final notices
must use the actual target/features and include vendored C/assembly notices
(for example aws-lc/ring/OpenSSL) as applicable. Preserve the pinned Git sources
selected by the build and the applicable MPL/Unicode and other component terms.
The standalone helper disables the legacy eappx feature; the original Xodus CLI
retains that feature by default.
`patches/standalone-account-transport.patch` retains Xodus's GPLv3 license; it
restricts helper service clients to HTTPS and disables account redirects.

The frozen worker additionally needs its actual CPython version, PyInstaller
inputs/TOC and bundled extension libraries recorded. The [PyInstaller exception](https://pyinstaller.org/en/stable/license.html)
does not waive other bundled software's terms. Preserve the [Python license and
incorporated notices](https://docs.python.org/3/license.html) from the actual
embedded version.

For the final candidate, every binary and data file needs a component/version,
hash, notice and exact source/build-material mapping. The corresponding source
must match the shipped Wine patches, DXMT variants, helper and worker; a link to
a moving branch or only this project's source export is insufficient. Prepare
reviewable corresponding-source materials and access directions alongside the
binary before publication. See [GNU GPLv3](https://www.gnu.org/licenses/gpl-3.0.html)
and the [GNU source-distribution FAQ](https://www.gnu.org/licenses/gpl-faq.html#AnonFTPAndSendSources).
Do not bundle Minecraft, worlds, account data, proprietary Microsoft runtime
payloads, CrossOver/D3DMetal, Rosetta or Apple SDKs under this inventory.

## Pinned-source native dependency alternative

`build-native-dependencies.py` and `native-dependencies.lock.json` now provide an
isolated source build for GMP 6.3.0, Nettle 3.10.2, libtasn1 4.21.0,
libunistring 1.4.2, GnuTLS 3.8.13 and FreeType 2.14.3. The source archives are
HTTPS-acquired with exact SHA-256 pins. The output retains license/author files,
FreeType's referenced contributed-code notices and FTL attribution, exact headers,
build commands/tool identity, component source URLs and per-file hashes.
GMP/Nettle/libtasn1/libunistring/GnuTLS retain their upstream terms; selecting
FreeType's FTL does not replace its contributed-code notices.

This produces seven x86-64 dylibs using macOS's system zlib/iconv libraries.
It excludes the old Gcenx closure, including MacPorts LegacySupport. Its manifest
explicitly records omitted optional features; this is a new compatibility
candidate. A local probe passed SHA-256, certificate/hostname verification,
wrong-host rejection, an HTTPS routing response and basic font rasterization.
Those checks do not establish gameplay, all language/font behavior, or multiplayer.
The first privately prepared app candidate still uses its separately audited
historical runtime until the new source-built Wine/runtime is validated.

The Wine builder requires `STANDALONE_DEPENDENCY_PREFIX` pointing to this verified
prefix and uses its matching headers. It rejects unknown leftover dependencies.
The public dependency builder refuses source/output cache reuse, retains only
verified download caches and runs compilation with an explicit environment.
Existing receipts are checked with `--verify`; they are never regenerated to
approve changed files. Source archives and build records remain local outputs
until distribution is separately approved.

`collect-helper-licenses.py` generates the macOS helper's locked dependency
notices and corresponding-source materials, with exact-input verification and
an included reconstruction script. The tested standalone target uses
`--no-default-features`: its conservative normal/build graph has 436 packages,
796 distinct notice texts and 447 source inputs, with no unresolved notices
recorded. All 447 inputs passed hash verification and source reconstruction;
a clean reconstruction build remains separate validation. The unused legacy
eappx/xmlserde dependencies are excluded by
`patches/standalone-helper-dependencies.patch`, which retains Xodus's GPLv3 terms.
Earlier candidates built with the default legacy feature retain their separate
notice inventory and unresolved xmlserde notice gap. Generated bulk archives
and local machine evidence do not enter the source allowlist or app automatically.

`collect-python-notices.py` records the frozen worker's actual PyInstaller inputs,
CPython source and license texts, bundled native extensions, and source mappings.
The reviewed local worker uses CPython 3.14.5 and PyInstaller 6.22.3; 73 notice
texts cover its selected Python/native inputs. All 49 packaged native code
sections matched the build inputs, and the candidate's 73 packaged notices
matched the generated texts. These checks do not establish a complete rebuild
of Homebrew's original dependencies. Preserve the matching source archives,
build evidence and per-candidate index separately from app notice texts.
