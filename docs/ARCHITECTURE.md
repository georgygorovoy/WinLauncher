# Proposed architecture

Status: design proposal, contingent on the Ubisoft feasibility gate. The native app remains arm64 even when its Wine engine runs through Rosetta.

## Boundaries

```text
SwiftUI app / native file-open and drop handling
                    |
             ApplicationCoordinator
                    |
         LibraryStore + EnvironmentCoordinator
                    |
  ExecutableInspector -> CompatibilityResolver -> LaunchPlan
                    |
   EngineManager + PrefixManager + RenderingBackendManager
                    |
       WineExecutor + ProcessSupervisor + DiagnosticsStore
                    |
              replaceable Wine process

InstallerSession -> InstallationDetector -> Add to Library sheet
Signed update catalogs -> EngineManager / ProfileStore
```

Use Swift modules with protocol boundaries rather than nine independent services. UI state belongs on the main actor; filesystem, process, download and detection work run asynchronously. Engine-specific paths never leak into views. No privileged daemon is required for basic launching.

| Layer | Protocol/responsibility | Key contract |
|---|---|---|
| Native application | SwiftUI scenes, AppKit file panels/drop bridge | Receives user intents and renders operation states |
| Library | `LibraryRepository` | Transactional app records, environment references, launch history |
| Environment orchestration | `EnvironmentManaging` | Resolve plan; serialize changes; enforce access and lifecycle rules |
| Engine management | `EngineProviding` | Install, verify, enumerate, pin and retire immutable engine versions |
| Prefix management | `PrefixManaging` | Initialize, validate mappings, clone, snapshot, migrate, recover |
| Detection | `ExecutableInspecting`, `InstallationDetecting` | Parse PE metadata and rank installed targets without executing them |
| Graphics | `RenderingBackendProviding` | Validate ABI/capabilities and produce scoped renderer configuration |
| Compatibility | `CompatibilityResolving` | Compile typed profiles and user overrides into an explained plan |
| Execution/diagnostics | `WineExecuting`, `ProcessSupervising` | Start process tree, stream bounded logs, observe exits, stop only owned processes |

Use `Foundation.Process` or an appropriate spawn API behind `WineExecuting`. Tests substitute recorded process events and fixture files. Never interpolate file paths or profile data into a shell command. Direct launching still requires deliberate Windows command-line serialization at the Wine boundary; validate spaces, quotes, Unicode and leading punctuation.

## Data model and persistence

`LibraryApplication` stores UUID, display name, icon reference, environment UUID, Windows-relative target, working directory, arguments, profile/version reference, last successful launch and optional compatibility status.

`WindowsEnvironment` stores UUID, engine artifact ID, prefix schema revision, state, filesystem grants, renderer policy, installed dependency receipts and backup references. Multiple library entries normally reference the same default environment.

`EnvironmentAssignment` records whether an application follows the global default or is pinned to a specific environment. Following the default is intentional state, not a copied UUID: if the user changes the global default, applications that follow it change together. Pinned applications retain their selected environment.

The initial core model for this behavior lives in `Sources/WinLab/EnvironmentAssignment.swift`; it is intentionally independent of SwiftUI and persistence so the same semantics can move into the application core unchanged.

`EngineManifest` records artifact version/hash/size, signed catalog identity, source commit and patch digests, build recipe, licenses/SBOM, minimum OS, host architecture, supported Windows architectures, executable entrypoints, renderer ABI compatibility and synchronization capabilities. `wine --version` is evidence, not a sufficient capability probe.

`LaunchPlan` is an immutable snapshot: executable, working directory, argument array, environment delta, scoped registry actions, engine/renderer/profile IDs, access grants and diagnostic policy. Store the effective plan with every run, after redaction.

Use a transactional SQLite store through a small repository layer; select a maintained open-source binding during implementation. Keep large icons, prefixes, logs and artifacts outside the database. State changes and filesystem mutations use a journal so interrupted initialization is recoverable.

Proposed storage under `~/Library/Application Support/WinLauncher/`:

```text
Library.sqlite
Engines/<artifact-id>/          immutable after verification
Renderers/<artifact-id>/        immutable paired dependencies
Environments/<uuid>/prefix/    mutable, owner-only permissions
Environments/<uuid>/state.json
Profiles/<catalog-version>/
Icons/<content-hash>.png
Operations/<uuid>/             journal and recovery metadata
```

Logs belong in the user's Library/Logs location with rotation and a retention limit. Backups live outside the prefix, with capacity checks and user-visible disk usage. Never store changing prefixes inside the signed macOS application bundle.

## Default shared environment, overrides and process ownership

The first successful setup creates one environment named “Default Windows Environment.” Every application and installer uses it unless the user explicitly chooses another environment. Steam, Trackmania, Ubisoft Connect and ordinary Windows applications therefore see the same C: drive, registry, installed runtimes and launcher state by default. This behavior is a product invariant and must be covered by integration tests.

Settings → General exposes the default Windows Environment. An application's Settings → Windows Environment offers “Use Default,” an existing environment, and “Create Separate Environment.” The open/import sheet keeps this choice hidden under Options and preselects “Use Default.” Technical terms such as prefix remain exclusive to Advanced Mode.

Changing an assignment is not equivalent to moving an installed application. For a portable executable, the app can copy/import it into the selected environment. For installed software, offer one of three explicit operations: use the installation already present in the target environment, duplicate the complete source environment and assign the app to the duplicate, or reinstall into a new environment. Never rewrite registry paths and copy Program Files heuristically while presenting that as a safe move.

The shared default improves interoperability but also shares failures, dependencies, disk state, login sessions and malware exposure. “Create Separate Environment” is the recovery/isolation path. Compatibility profiles may recommend a separate environment after explaining why, but cannot silently split an existing application away from the default.

Keep an environment's active Wine version fixed while any associated process is running. Engine and base renderer selection belong to the environment. An application can request only settings supported as per-process overrides; otherwise changing the engine/renderer requires migrating the shared environment or duplicating it.

Serialize registry/prefix mutations. Do not consider an installer complete merely because its bootstrap process exited. Observe related processes, filesystem quiet periods and install records; retain a user-visible “Installation Finished” escape hatch for launchers that intentionally remain open. A `wineserver -w` wait needs cancellation and a deadline; background services can keep it alive indefinitely.

Stopping a run must not issue `killall wine` or kill unrelated environments. Parent PIDs alone are insufficient after children detach; combine spawn/session ownership with prefix-specific process evidence and environment locking. Force-stopping a shared environment explicitly affects every app inside it.

Duplicate only after quiescing the environment. Prefer APFS clones where suitable, with a verified copy fallback. Duplicates can contain every installed program and login token in the shared environment; explain that fact and offer a clean environment instead. Delete a library entry separately from deleting its shared Windows files. The default environment cannot be deleted while applications follow it, and no referenced environment is ever deleted silently.

## Compatibility profiles

Use versioned JSON with strict schema validation. A profile contains matching evidence, supported engine capabilities, Windows version, DPI policy, renderer policy, environment variables, scoped registry changes, DLL overrides, dependency IDs, launch arguments and optional engine-supported child-process rules.

Match by a combination of product metadata, publisher information, installer family and known hashes/version ranges. A filename alone is weak evidence and must not authorize risky fixes. Inspection is bounded and performed without loading the PE as executable code.

Profiles express only allowlisted operations. They cannot download arbitrary URLs, execute shell scripts, escape a prefix or inject unrestricted host loader variables. Dependencies refer to separately verified catalog artifacts. Apply changes transactionally with receipts and undo information.

Resolution order: supported conservative defaults → validated matching profile → user override. Reject incompatible combinations rather than silently mixing settings. Experimental profiles never auto-apply. A successful launch means observed usable behavior for a known test, not merely a zero exit status.

Defaults to evaluate: Windows 10; new WoW64; engine-default synchronization; baseline DPI; no speculative DLL/runtime installations; renderer selected from verified capability data. Exe imports are hints and cannot reliably predict every runtime or renderer requirement.

Per-process renderer rules need actual engine support. Setting an environment variable before launching Steam generally passes it to children; it does not implement arbitrary child-specific policy. Wine AppDefaults may support selected scoped settings, while more advanced rules need a reviewed engine patch. The resolver rejects unsupported process rules.

Keep upstream code fixes in versioned engine releases. A JSON update cannot fix a missing Wine API. Profiles select engines by capabilities and tested revisions rather than embed native patch payloads.

## Updates and rollback

Maintain independent signed engine, renderer and profile catalogs. Validate signature, expiry, schema, supported app version, artifact hash and size. Reject traversal, absolute paths and escaping archive links during extraction. Stage updates and atomically activate after verification. TLS alone is insufficient provenance.

Pin installed environments to exact artifacts. New catalog versions do not modify running environments. Preserve last-known-good engine and profile metadata. Engine migration operates on a quiescent prefix snapshot and validates before activation. Rolling back an engine binary alone does not undo registry/prefix migrations.

Use stable and experimental channels, revocation handling, key rotation and an offline last-known-good policy. A deliberate local rollback remains possible without allowing a remote attacker to replay stale metadata. Engine/source availability and license notices are release requirements.

## Installation detection

Snapshot Program Files, Program Files (x86), per-user AppData/Local/Programs, public/user Desktop and Start Menu, and both registry views of uninstall entries. Read registry data through Wine-aware APIs/commands while running, not by editing live hive text.

Combine bounded filesystem events with post-install reconciliation. Score candidates by shortcut target, uninstall DisplayName/InstallLocation/DisplayIcon, PE product metadata and modified paths. Penalize uninstallers, crash reporters, updaters and redistributable installers. Preserve shortcut arguments and working directory. Support unchanged executable names whose contents were replaced.

Parse PE icon resources and shortcut structures defensively in an isolated helper; bound file size, nesting and decode memory. Use a generic SF Symbol if extraction fails. Present “Add to Library” with ranked choices, not a claim of perfect automatic identification. An empty result leads to “Choose Installed App,” not an automatic installation-failed verdict.

## Native experience

First window: “Run Windows apps on your Mac.” Primary “Open Windows App,” secondary “Choose Installer,” and a quiet file drop target. Preparation appears inline with cancellation. Engine installation and creation of the shared default environment are automatic after a concise download notice; no engine-selection wizard.

Library uses native typography, semantic colors/materials, generous spacing and large accessible cards. Clicking launches; running state prevents duplicate requests. Cards show icon, name, last launch and only useful status. Search and a native toolbar provide navigation. Light/dark mode, keyboard navigation, VoiceOver and reduced-motion behavior are acceptance criteria.

Context menu: Run, Show Windows Files, Open C: Drive, Settings, Duplicate Environment, Delete. Settings categories: General, Windows Environment, Graphics, Compatibility, Diagnostics. Graphics labels are Automatic, Compatibility and Performance. Only Advanced Mode reveals backend/engine names, registry tools, DLL overrides, variables and raw arguments.

Errors use “Windows app couldn't start,” with Try Again, Repair Environment and View Details. Repair is a defined, recoverable operation with a preview of affected data; it never resets a user's prefix without explaining data loss. Diagnostics expose a redacted effective plan, bounded stdout/stderr and relevant crash records, with Copy Diagnostic Report. Never include account tokens, cookies, complete environment variables or memory dumps by default.

## Security gate

No root execution, privileged installer, host-root drive or automatic home-directory links. Import the selected executable into controlled storage; multi-file applications need an explicit folder grant. Validate symlinks and maintain owner-only writable directories. Preserve Gatekeeper and normal OS security.

These controls prevent accidental broad sharing; they do not make Wine a sandbox. Before general release, prototype and penetration-test an OS-enforced helper boundary compatible with Wine child processes, JIT/translation, GPU access and file grants. A sandbox entitlement on the SwiftUI frontend alone proves nothing about its Wine children. If this boundary cannot be delivered, disclose the limitation and revise the security/product promise before shipping arbitrary downloaded executables.

Native UI polish does not alter third-party Windows installer/game windows; those remain Wine-rendered. The product can simplify orchestration without promising to restyle every Windows dialog.
