# Ubisoft Connect proof of concept

**Status: engine-side rendering fix reproduced on 25 September 2026. Ubisoft authentication and Trackmania launch were subsequently confirmed in the shared environment during interactive testing.**

The current host installed the official Ubisoft Connect build 173.1.13333 into the shared environment and launched it with WineForge 0.6.0.5 / Wine 11.18. The effective `upc.exe` command line contained `--in-process-gpu`; CEF renderer, network, storage, audio and video processes remained alive; Ubisoft logged `Using CEF with native rendering` and completed `StartView`; and the prior repeating `macdrv_surface_create ... of other process` failure disappeared. A visual screenshot could not be captured because Screen Recording permission was unavailable, so responsive controls and credential entry remain the next interactive check.

Question: can current Ubisoft Connect install and display a responsive login UI on Apple Silicon with an open-source Wine/graphics distribution, excluding CrossOver binaries and D3DMetal?

Host prerequisite exception: macOS, Metal and Apple-provided Rosetta. Ubisoft Connect itself is proprietary user-installed test software. A literally all-open-source runtime is not what this experiment establishes.

## Smallest deliverable

A reproducible command-line laboratory, not a SwiftUI product. It accepts explicit engine and official installer paths, creates one disposable environment per experiment, records the effective configuration and captures logs/results. Within an experiment, Steam, Ubisoft Connect and Trackmania share that same environment, matching the product default. Separate environments between experiments preserve scientific repeatability; they do not represent the eventual user default. Build only the minimum engine/prefix/process primitives this requires. No auto-updater, library, icons or general compatibility database yet.

The current research host reports arm64, macOS 15.3 (24D2059). That is not a current-OS compatibility result. Record the chip model, RAM, Rosetta availability, Xcode/SDK and current host build during execution; repeat on a current supported macOS machine before claiming current-platform support. No Rosetta installation or Windows runtime was performed during research.

## Reproducible inputs

Create a manifest before running, with exact engine source commit and patch IDs, artifact SHA-256, license/source bundle, renderer builds and host libraries, host version, installer hash/version/source URL and timestamp. Hash installed Ubisoft/CEF binaries after self-update as well: an installer hash alone does not pin a network-updating launcher.

Baseline candidate A: verified WineHQ macOS Wine 11.17 development package. Candidate B: own upstream Wine 11.18 build with a recorded toolchain. A pinned staging build is a comparison only after checking which patches it adds. Wine 11.0 is a regression control, not the preferred Ubisoft fix candidate.

Check both 32-bit and 64-bit PE smoke tests. Verify actual graphics modules with loader logs and host-library paths. Check that no D3DMetal, CrossOver executable, or unaudited Microsoft runtime entered the environment indirectly. Before redistributing any engine, complete the dependency/source audit.

Use a disposable macOS test account with no personal data and controlled shared directories for the laboratory. A separate Wine prefix alone is not containment. Do not install or run untrusted test software on the user's main account while claiming restricted host access has been proven.

## Experimental sequence

Each row starts from a fresh initialized prefix or a quiescent clone of an explicitly recorded pre-launch snapshot. Hold host, Ubisoft/CEF version, Windows version, DPI and synchronization constant. Change one factor at a time.

| ID | Change | What it tests | Status |
|---|---|---|---|
| A0 | New WoW64, Windows 10, default sync, no CEF flags, built-in renderer | Baseline install/start/window behavior | Not run |
| A1 | Newer upstream build, same settings | Whether upstream fixes resolve baseline failure | Not run |
| B0 | `--disable-gpu` only, if verified accepted by actual CEF host | Accelerated vs CPU UI rendering | Not run |
| B1 | Add `--disable-gpu-compositing` only if needed/recognized | Residual compositor acceleration | Not run |
| C0 | Separate branch: `--in-process-gpu` with otherwise working GPU configuration | Cross-process GPU handoff | Reproduced with WineForge 0.6.0.5 |
| C1 | Diagnostic-only `--single-process`, with confirmed argument delivery | Multi-process window/presentation involvement | Not run |
| D0 | Pinned DXMT pair | ANGLE D3D11 device/swapchain behavior | Active for Ubisoft CEF; process/log gate passed |
| D1 | Pinned DXVK-macOS + compatible MoltenVK | Alternative D3D11 path | Not run |
| E0 | Minimal source patch derived from observed failing path | Actual Wine API/window-system defect | Not run |

Avoid a full factorial sweep initially. First identify a reproducible failure and follow the relevant branch. Test flags separately; do not paste every Chromium flag into one command and infer a cause from the result.

Passing flags to `UbisoftConnect.exe` or `upc.exe` is not enough evidence: inspect which executable hosts CEF, its version, architecture, parent PID and effective command line. Discover helper names at runtime rather than assume them. If the launcher does not propagate flags, mark the experiment “not applied,” not “flag ineffective.” Prefer supported launcher configuration or a small reviewed engine-side mechanism over modifying vendor executables.

`--no-sandbox` is not a default remedy. Investigate it only if logs establish a CEF sandbox startup failure, in the disposable laboratory, with the reduction in browser-process isolation recorded. It does not mean disabling macOS SIP/Gatekeeper. Similarly, single-process mode is a diagnostic discriminator with stability/isolation tradeoffs, not a production preset without further evaluation.

Do not apply Windows 7 mode, arbitrary DLL overrides, .NET installations, update-server blocking or old insecure launcher builds as unexplained fixes. No verified Ubisoft-specific registry cure was found. Registry changes must be tied to observed behavior and reversible. DPI/Retina changes test sizing/composition issues separately from CEF initialization.

The inspected WineHQ package configuration disables OpenGL. Do not label its renderer as an OpenGL fallback. If investigating a GL path, create and identify an OpenGL-enabled source build. DXMT and DXVK experiments must keep their native/PE libraries and override semantics paired to the engine.

## Evidence and diagnosis

Capture bounded stdout/stderr, timestamps and exit codes; installer and CEF logs; process creation and loaded modules; selected renderer; environment/profile manifest; relevant macOS crash reports; and screenshots/short recordings of the window before credentials are entered. Debug channels should be validated against the tested build; start with process/module/exception traces, then enable targeted macOS-driver/surface traces. Full relay traces are too costly as a default.

Differentiate these failure signatures:

| Observation | Next investigation |
|---|---|
| No helper process | Process creation, missing imports, permissions, launcher self-update |
| Repeated GPU process death | ANGLE device/swapchain, renderer ABI, resource-sharing failures |
| `EGL_BAD_ALLOC` or unsupported child swapchain | D3D/window presentation path; correlate exact PID and HWND |
| CPU rendering works, GPU fails | Scope UI workaround; retain game acceleration separately |
| Frames submitted but window remains blank | Cross-process surface delivery, clipping, ownership, hide/show |
| Visible UI but login fails | TLS, network/authentication, system time, cookies; not automatically graphics |
| Login works until restart | Persistent storage, shutdown completion and self-update behavior |

For the source-patch branch, reproduce the faulty behavior with a minimal CEF/Win32 test when possible. Trace child-window ownership, frame transfer, resize/clipping and destruction. Implement the missing behavior or a narrowly justified fallback in Wine; add regression coverage and retain upstream attribution. Do not copy proprietary binaries or remove authentication/DRM checks.

WineForge is a source lead only. Audit any candidate patch independently and demonstrate operation with no D3DMetal loaded. Its advertised Ubisoft support is not an accepted test result for this project.

## Acceptance gates

**Gate 0A — installation and login rendering:** current official installer completes; login controls and text render; keyboard input/focus, resize, minimize/restore and repaint work; no persistent blank region or GPU crash loop. Repeat three cold starts and one clean-prefix reinstall. Record screenshots, exact manifests and a human observation. Exit code zero alone is insufficient.

**Gate 0B — authentication and persistence:** the user enters credentials/MFA directly into the trusted vendor UI; never capture passwords or tokens in diagnostics. Login completes, authenticated UI works, and the session survives a clean shutdown and fresh launch where the vendor's security policy permits. Do not treat a legitimate MFA recheck as a rendering regression. Redact or omit post-login images.

**Gate 0C — first end-to-end chain:** install Windows Steam and Trackmania in a shared environment with Ubisoft Connect. Start from Steam → Trackmania → Ubisoft Connect → user login → Trackmania. Reach actual gameplay, exercise input/audio, finish a short race, quit and relaunch. Repeat with a remembered session and after launcher self-updates. Record the Steam app ID, game build, all launcher versions and per-process renderer choices.

Gate 0A answers the first proof question. Gates 0B/0C answer the broader product requirement. Success at one gate must not be reported as success at the next.

Stop and report a blocker if every audited open-source configuration fails and the only working path requires proprietary compatibility code or D3DMetal. Produce the minimized failing case and missing feature, not a speculative “working” profile. If CPU UI rendering works but the game does not, publish those as separate results.

## Proposed profile artifact after success

Create `Compatibility/Profiles/ubisoft-connect.json` only after establishing a reproducible configuration, or mark any earlier laboratory file explicitly experimental and excluded from automatic resolution. Required fields:

- Schema/profile version; application/version match evidence.
- Exact tested engine/renderer capabilities and allowed ranges.
- Windows version, DPI and synchronization policy.
- Confirmed CEF argument delivery mechanism and process scope.
- Registry/DLL/dependency actions with reasons and undo receipts.
- Test-run references and evidence tier: experimental, reproduced, validated.
- Known limitations and date/version of last successful test.

Do not record “Wine >= 11 works” from a single passing build. Pin the initial known-good combination and broaden it only through regression tests.
