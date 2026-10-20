# Implementation plan and release gates

The first task is research and a plan. This repository intentionally has no placeholder application, unverified compatibility profile or fabricated test results.

## Phase 0: establish feasibility

1. Implement the small laboratory specified in [UBISOFT-POC.md](UBISOFT-POC.md): explicit artifacts, isolated test data, process/log capture and result manifests.
2. Execute the baseline and targeted CEF experiments. Audit the first viable engine's sources and dependencies.
3. If needed, create a minimal Wine regression test and a source patch with clear provenance; prefer contributing it upstream.
4. Pass login rendering gate 0A before investing in the polished product. Complete login persistence and Trackmania chain gates as the next compatibility milestone.
5. Prototype an OS-enforced filesystem/process boundary independently. Do not infer security from a successful compatibility run.

Outputs: reproducible build/launch instructions, pinned artifact manifests, observed results and logs, component/license inventory, a known-good experimental profile if one exists, and an explicit go/no-go decision. No reliable delivery date for an unknown Wine bug can be promised before this phase.

## Phase 1: native vertical slice

Create a SwiftUI application with the welcome screen, Open Windows App and drag/drop; an application coordinator; persistent basic library; automatic creation of one shared default environment; environment assignment overrides; an engine adapter; and process/log supervision. Start with the engine proven in Phase 0 and simple supported Windows fixture apps. Use a minimal local engine-import flow for development before adding downloads.

Accept when two selected portable apps and an installer all resolve to the same default environment, can be added to the library and relaunched after restarting the Mac app. Verify that changing one application's assignment to a separate environment does not change other applications. A failed launch exposes a useful error with retry/details, and cancellation leaves a recoverable state. Handle filenames with spaces/Unicode, missing/deleted targets, low disk space, initialization interruption and concurrent launch requests. Do not claim compatibility with every `.exe`.

## Phase 2: installation and replaceable components

Add installer sessions, ranked application detection, icon extraction, per-app settings, environment duplication/deletion, engine installation/catalog verification and renderer packages. Introduce settings categories and Advanced Mode without exposing technical defaults on the home screen. The shared environment already exists in Phase 1; Phase 2 makes environment selection and safe duplication user-facing.

Accept against controlled installers: per-machine and per-user installs; child-process installers; multiple candidates; uninstallers/updaters; overwritten executables; shortcut arguments; no-shortcut installs. Confirm 32/64-bit detection and operation. Validate artifact tampering, interrupted downloads, archive traversal/symlinks and rollback of an engine plus migrated prefix. Confirm shared-environment deletion/reference semantics.

## Phase 3: validated compatibility profiles and Trackmania

Implement schema-validated profile resolution and independent signed profile updates. Ship default and Ubisoft profiles only with accurate evidence tiers. Add Steam, Epic, Ubisoft and generic launcher profiles as tests justify them; empty profiles must not imply support. Replay Phase 0 findings through the actual application.

Accept the complete Windows Steam → Trackmania → Ubisoft authentication → gameplay flow, including remembered sessions and launchers' current self-updates. Verify that launcher-specific renderer/CEF settings do not degrade the game or unrelated apps in the environment. Add at least one ordinary Windows application and a second unrelated D3D11 game to guard against a Trackmania-only architecture.

## Phase 4: distribution and recovery polish

Add Finder Open With handling, supported automatic repair, update rollback UI, diagnostics export, crash recovery and release packaging. Register an executable document type without making the app the default handler unilaterally. The same import pipeline handles Finder, file panels and drops.

Accept Developer ID signing/notarization for the app and runnable downloaded components, preservation of platform security, accessibility/keyboard/dark-mode coverage, bounded memory/log/disk behavior and reproducible engine source releases. Signing entitlements for JIT/translation and loaded libraries require practical validation; do not assume a notarized frontend covers arbitrary engine binaries.

## Proposed repository layout

```text
App/                    app lifecycle and composition
Core/                   orchestration and protocols
Wine/                   execution adapters and process supervision
Engines/                manifests, installation, capability probes
Prefixes/               environment lifecycle, mapping, migration
Compatibility/          schema, resolver, validated profiles
InstallDetection/       snapshots, PE/shortcut parsing, ranking
Models/                 persistent models and launch plans
UI/                     library, onboarding, sheets, settings
Resources/              localization and owned assets
Tests/                  unit, integration, security and manual matrix
Tools/                  laboratory and reproducible engine builds
docs/                   decisions, evidence, contributor guide
```

Create directories when implementation begins; avoid empty scaffolding now. Proposed application license: MIT for original frontend/orchestration code, with Wine/DXMT modifications distributed under their applicable LGPL terms. Select and publish the project license before accepting external code contributions. Keep third-party artifacts and proprietary installer/game files out of Git.

## Blockers and decisions

| Priority | Blocker | Resolution/evidence needed |
|---|---|---|
| P0 | Ubisoft login rendering with the permitted stack is unproven | Execute gate 0A; implement missing Wine behavior if reproducible |
| P0 | “Open source only” versus Rosetta/Metal and proprietary target apps | State distribution scope explicitly; a strict no-Rosetta requirement needs another architecture |
| P0 before public release | Wine prefix is not a security boundary | Demonstrate restricted host access for Wine and all children, or revise the promise |
| P0 before binary distribution | Complete redistribution compliance not audited | Exact source/dependency inventory, licenses, build recipes and corresponding source |
| P1 | General Rosetta availability changes after macOS 27 | Validate ARM-native Wine plus CPU translation; do not promise macOS 28 support prematurely |
| P1 | Launcher CEF flags may not reach helpers | Inspect process arguments; use a supported mechanism or auditable engine fix |
| P1 | Renderer or runtime fixes can conflict inside the shared default environment | Validate process-specific rules; recommend an explicit separate environment when coexistence is impossible |
| P1 | Ubisoft/Steam self-updates invalidate profiles | Capture installed versions and rerun the acceptance matrix |
| P1 | Authentication/MFA needs real user interaction | User logs in directly; no fabricated account/session result |
| P1 | Current host is macOS 15.3 | Test the chosen current supported macOS releases on real Apple Silicon |
| P1 | Sikarugir current launcher/creator reuse rights not established | Independent implementation; reuse only explicitly licensed source |
| P2 | Games may require unsupported DRM, kernel drivers or D3D12 | Publish measured compatibility; never bypass protection or promise universal support |
| P2 | Engine patches create ongoing maintenance obligations | Narrow patch queue, upstream submissions, repeatable CI builds and regression ownership |

## Verification strategy

Use unit tests for plan resolution, manifests, argument serialization, candidate scoring and state transitions. Use fixture-based parser tests and fuzzing for untrusted PE/icons/shortcuts and archive validation. Use process integration tests for stdout/stderr backpressure, child detachment, cancellation, recovery and environment locking.

Use real hardware tests for Wine architecture support, graphics presentation, signing/entitlements, confinement, CEF interaction and game behavior. Mock processes and screenshots alone cannot certify compatibility. Include fresh installs and migrated environments, multiple Apple Silicon generations where available, normal/non-ASCII paths, high-DPI displays and offline error handling.

Security verification must attempt reads/writes outside grants, traversal and symlink escapes, host shell execution, re-created drive mappings and child-process escapes. The helper should also have no access to the app's update signing secrets or another environment's data. Distinguish practical confinement guarantees from protection against all kernel/OS vulnerabilities.

Maintain a result ledger with `not-run`, `pass`, `fail`, `blocked`, configuration hashes and evidence links. All runtime gates currently remain `not-run`. Research and source inspection are complete enough to begin the controlled experiment; they do not establish the experiment's answer.
