# Microsoft Store, GDK, and Minecraft for Windows research

Research date: 2026-10-21

## Decision

Minecraft for Windows is now a realistic WinLauncher target without a Windows VM or Android emulator. The viable route is the newer Win32/GDK build, not the Microsoft Store launcher executable and not the former UWP build.

WinLauncher should add an independently downloadable **Xbox Games Support** runtime composed of:

- a pinned WineGDK-derived engine for macOS;
- a separate GPL-licensed Xodus command-line helper for Microsoft authentication, entitlement, package download, and decryption;
- DXMT for Direct3D-to-Metal translation;
- a dedicated managed Windows Environment for GDK titles.

The user would open `MinecraftInstaller.exe`; WinLauncher would recognize the bootstrapper, offer **Install Minecraft for Windows**, sign the user in to Microsoft, verify the Windows entitlement, download the owned game from Microsoft, and add it to the existing library. No Store UI, PowerShell, Android purchase, Android Studio, or Windows installation would be involved.

## Why the normal Wine path fails

The downloaded Minecraft installer is a Store bootstrapper rather than a self-contained game installer. Microsoft documents that Store GDK games are Win32 programs packaged as MSIXVC and depend on the separately serviced Gaming Runtime. The runtime includes services, UI, identity, commerce, storage, and package activation components. It is not equivalent to installing a few redistributable DLLs.

Current Wine source still leaves central AppX and AppContainer operations unimplemented. Supplying random Windows DLLs cannot recreate the package repository, activation model, Store entitlement services, and Gaming Runtime processes. A generic `Add-AppxPackage` implementation is therefore a separate, very large project.

Sources:

- [Microsoft GDK overview and Gaming Runtime architecture](https://learn.microsoft.com/en-us/gaming/gdk/docs/gdk-dev/intro/introduction)
- [Microsoft GDK package testing and Gaming Services dependency](https://learn.microsoft.com/en-us/gaming/gdk/docs/features/common/packaging/packaging-testing-pc-install)
- [Wine `kernelbase.spec`, including unimplemented AppX entry points](https://github.com/wine-mirror/wine/blob/master/dlls/kernelbase/kernelbase.spec)
- [Wine AppContainer profile implementation status](https://github.com/wine-mirror/wine/blob/master/dlls/userenv/userenv_main.c)

## Evidence that the smaller GDK route works

The open-source [Bedrock for Mac](https://github.com/1JRobertson/bedrock-mac) project has reached gameplay on Apple Silicon using WineGDK, DXMT, and Xodus. It authenticates the Microsoft account, checks the Minecraft for Windows entitlement, obtains the owned MSIXVC package, and launches the Windows game through Wine and Rosetta. Its documented local RC4 DMG is approximately 155 MB and contains the compatibility runtime but not Minecraft. Its current source is still a preview: clean-machine, notarization, update, and wider hardware qualification remain incomplete.

[BedrockOnLinux](https://github.com/stirante/BedrockAnywhere) and [Ferestre](https://github.com/icex/ferestre) independently demonstrate the same GDK/Xodus model on Linux. Ferestre also establishes an important product boundary: it supports MSIXVC GDK titles, while ordinary UWP AppX/MSIX applications remain unsupported.

The game download itself is unavoidable. Bedrock for Mac also documents an approximately 197 MB ranged Microsoft component download. These are application payloads, not a multi-gigabyte Windows or Android operating system image.

## Proposed WinLauncher architecture

### 1. Package classifier

Replace the current binary yes/no Store check with these categories:

1. **Classic Win32** (`.exe`/`.msi`) — use the current shared Wine environment.
2. **GDK/MSIXVC title** — use Xbox Games Support.
3. **Packaged Win32 / Windows App SDK** — attempt a future small desktop-package compatibility path only when the app can run unpackaged or self-contained.
4. **UWP / AppContainer / Store-only app** — explain that the Windows package platform is required and do not waste time retrying Wine.

Microsoft documents that Windows App SDK desktop applications can be published unpackaged or self-contained. That gives some Store-like desktop apps a possible lightweight path, but it does not make UWP applications portable.

- [Windows App SDK deployment options](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/deploy-overview)
- [Framework-dependent unpackaged application deployment](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/deploy-unpackaged-apps)

### 2. GDK engine package

Create a new replaceable engine kind, for example `wine-gdk-macos`, delivered independently from the main application. It must be built in CI from pinned source revisions and published with:

- an archive SHA-256;
- Wine/LGPL corresponding source and patches;
- exact DXMT source revision and notices;
- the separate Xodus helper, its GPL source, and dependency notices;
- a machine-readable component manifest;
- minimum macOS and Rosetta requirements.

Do not compile Wine, Rust, Python, or DXMT on the user's Mac. The installed runtime should be comparable to the approximately 155 MB compressed Bedrock for Mac candidate, not its much larger development workspace.

### 3. Microsoft account and acquisition helper

Keep authentication and package acquisition in a separate helper process with a narrow JSON/stdio protocol:

- `sign-in`
- `list-entitlements`
- `install <product-id>`
- `check-update <product-id>`
- `update <product-id>`
- `sign-out`

Use the macOS Keychain for refresh credentials. Never write tokens to Wine logs or the application library. Verify Microsoft's package signature and hash tree before promoting a download into the game library. Refuse installation if Microsoft does not grant a valid entitlement.

### 4. Product experience

For `MinecraftInstaller.exe`:

1. Detect the known Store bootstrapper before launching Wine.
2. Show **Minecraft for Windows** with an **Install** button.
3. Download Xbox Games Support only once.
4. Open Microsoft sign-in and verify ownership.
5. Download and verify the owned game.
6. Add the real game icon and name to the WinLauncher library.
7. Launch through the dedicated GDK environment on subsequent clicks.

The technical environment remains automatic. The library card can say **Requires Xbox Games Support** rather than exposing WineGDK, Xodus, MSIXVC, or DXMT.

Although WinLauncher normally uses one shared Windows Environment, GDK titles should automatically use a dedicated managed environment. The patched engine and Xbox identity/runtime state are materially different from the normal Wine environment. This exception should remain invisible unless Advanced Mode is enabled.

### 5. Compatibility profiles

Add a data-driven profile with fields such as:

```json
{
  "id": "minecraft-for-windows",
  "acquisition": "microsoft-gdk",
  "productId": "<verified catalog product id>",
  "engine": "wine-gdk-macos",
  "renderer": "dxmt",
  "environment": "dedicated",
  "requiresRosetta": true,
  "minimumMacOS": "15.0"
}
```

The product identifier and catalog rules must come from a reviewed, updateable profile. Do not hardcode a download URL for the game.

## Licensing boundary

WinLauncher is MIT. Bedrock for Mac and Xodus are GPLv3; Wine/WineGDK and current DXMT code have LGPL obligations, with exact terms depending on the pinned revisions.

The safest design is to keep the Xodus-derived helper as a separate GPL executable invoked through command-line arguments or pipes. The Free Software Foundation describes command-line, pipe, and socket communication as mechanisms normally used between separate programs, while linking GPL crates directly into WinLauncher would make the licensing relationship much harder. The helper source, changes, license, and build materials must be offered with every distributed binary. This needs a release-specific license review before shipping.

- [GNU GPL FAQ on separate programs and aggregation](https://www.gnu.org/licenses/gpl-faq.html#MereAggregation)
- [Bedrock for Mac third-party and source obligations](https://github.com/1JRobertson/bedrock-mac/blob/main/THIRD_PARTY.md)
- [DXMT license](https://github.com/3Shain/dxmt/blob/main/LICENSE)

WinLauncher must not redistribute Minecraft, Microsoft account data, content keys, proprietary Microsoft DLLs, CrossOver, or D3DMetal. The game and permitted Microsoft components must be obtained for the signed-in owner from Microsoft at installation time.

## Smallest proof of concept

Build this outside the polished UI first:

1. Reproduce the pinned Bedrock for Mac source build on the current Apple Silicon test Mac.
2. Record the compressed runtime size and installed size.
3. Replace its launcher UI with a minimal WinLauncher-controlled helper invocation; do not copy GPL code into the MIT Swift target.
4. Sign in with an entitled Microsoft account and acquire the current Minecraft for Windows package.
5. Verify launch, menu rendering, keyboard/mouse input, local-world save/reopen, Microsoft session persistence, and one server/friend connection.
6. Re-run after a game update and after restarting macOS.
7. Only then define the downloadable engine manifest and native WinLauncher flow.

Success means the official Windows game obtained for the user's Microsoft entitlement runs on Apple Silicon with no Android purchase, Windows VM, Android image, Homebrew, compiler, or manual prefix work.

## Main blockers

- Bedrock for Mac has no public notarized binary and explicitly describes its current build as a source preview.
- Its local candidate is ad-hoc signed and still lacks clean-machine and broad hardware qualification.
- Xodus and the WineGDK patches follow private Microsoft service behavior that can change.
- Minecraft updates can break runtime patches and require profile/engine updates.
- Generic UWP/AppX/MSIX support remains out of scope; GDK/MSIXVC is a narrower class.
- Public binary distribution requires exact corresponding source, notices, and a license audit for every bundled runtime library.
- A polished public macOS release eventually needs Developer ID signing and notarization.

## Implemented proof of concept

WinLauncher 1.2.0 now bundles a player runtime built from the pinned Bedrock for
Mac source revision. It contains WineGDK 11.8, DXMT 0.80, the separate Xodus
helper, the required source-built compatibility bridges, component manifests,
licenses, and corresponding source material. The game and Microsoft DLL are not
bundled; they are obtained for the signed-in owner and verified during setup.

On October 21, 2026, the end-to-end path passed locally on the target Apple
Silicon Mac: saved Microsoft sign-in was reused, the official Microsoft component
was downloaded and verified, the dedicated environment was prepared, and
`Minecraft.Windows.exe` remained running after the worker reported the playing
state. Wider clean-machine and gameplay qualification remains open.

Do not attempt to install the Microsoft Store or Gaming Services inside the
shared WineForge environment. Generic Microsoft Store support is not implied by
this narrow GDK path.
# Implementation status (October 21, 2026)

WinLauncher now contains a separate-process integration for the narrow Xodus
account/download helper. The Swift application remains MIT and communicates
with the GPL helper only through documented command-line arguments, exit status,
and a diagnostic log. The helper is not linked into the application.

The pinned ARM64 helper was built from `1JRobertson/bedrock-mac` commit
`4b42c46131fd5b53cae7588773cac2d601471c2f` and Xodus commit
`0670e25aeb0e0e9f800f8f2f4968ae3b681842a7`. Its SHA-256 is:

```text
cce9d9cc3cf72b9acf03eaae413be6f16bf838c1141ffcfa9ab182e416580ff4
```

The app rejects a helper with any other digest, rejects symlinks and writable
shared files, and keeps Microsoft tokens in Keychain through the helper. The
corresponding-source candidate records 436 packages, 796 notice texts, and 450
source inputs with zero unresolved notice entries. Its reconstruction verifier
passed locally.

The helper can display Microsoft sign-in and prepare the legitimately owned game.
The separately bundled WineGDK/DXMT worker then prepares and launches it from a
dedicated environment. When both components are available, Minecraft appears as
a one-click Library item.
