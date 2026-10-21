# Security and privacy

This repository is an experimental source preview. No public binary release or
supported security-maintenance schedule is established. The latest source and
the known release gates are documented in [docs/RELEASE.md](docs/RELEASE.md).

## Reporting a security issue

Use the repository's GitHub **Security → Report a vulnerability** action if it
is available. If private reporting is unavailable, open an issue asking for a
private contact channel without publishing exploit details, account data, or
secrets. No separate security email or response-time guarantee is configured.
Ordinary setup failures belong in the bug template.

A useful private report gives the affected commit, Mac/OS, component, steps using
synthetic data, expected/actual behavior, and impact. Never send a password,
Keychain export, Microsoft token, content key, complete account response, or
signed download URL. Review logs before sharing excerpts.

## Current boundaries and known gaps

- Microsoft user/device credentials are kept in macOS Keychain. The account
  helper caches one saved item per process and uses direct Keychain writes.
  No plaintext credential fallback is intended.
- The worker forwards only known progress messages and safe error codes to the
  UI. Logs stay on the local Mac; upstream/runtime output still needs review
  before anyone shares it. No automatic bug-report upload is implemented.
- The helper checks the owner's Microsoft license for downloading and launching.
  A copied game directory does not establish ownership.
- Account/catalog/license requests use certificate-verified HTTPS and do not
  follow redirects. The Xbox service uses the same transport restrictions.
- The current source uses a separate package client with no account headers,
  cookies, Referer or redirects. Only catalog-provided `assets1.xboxlive.com`
  and `assets2.xboxlive.com` HTTP origins on port 80 are accepted, without query
  strings, credentials or fragments. HTTPS on those hosts and
  `dlassets-ssl.xboxlive.com` uses normal certificate and hostname validation.
  HTTP bytes are untrusted and enter an exclusive mode-0600 quarantine file.
- Before interpreting header-controlled offsets, the helper verifies the fixed
  4096-byte header with the pinned production GreenGames RSA-4096 public key
  (PSS, SHA-256, MGF1-SHA-256, 32-byte salt). It then checks the signed static
  layout, catalog size and version. DisplayCatalog, PackageDetails, the selected
  file and the signed header must agree on the content UUID before licensing.
  The signed content ID supports the normal
  Microsoft ownership check before polling further bulk download data.
- Before the existing XVD parser or extraction runs, the complete quarantine
  must pass signature, every hash-tree page, every stored data page and exact
  signed package-full-name checks against the authenticated catalog. The final
  header must match the header used for ownership. Parsing and extraction use
  independently positioned readers of that verified local file; each read
  rechecks its page proof. Unauthenticated padding/mutable areas return zeros.
  No per-file network fetch is used. Hash entries retain the XVD format's
  192-bit internal and 160/192-bit leaf digest widths.
- The integrated helper
  passes 36 default fixture tests and an isolated optimized build. Five explicit
  signed-header cases also prove rejection/cleanup on wrong catalog identity,
  denied ownership, EOF, stream error and cancellation. The cached package's
  signed header, 2,975 tree pages and 589 metadata pages also pass isolated checks.
  A fresh owned-package download then passed the current account-catalog UUID
  and version binding, real ownership, complete signature/hash verification,
  extraction and licensed executable preparation in isolated private output.
  This checked 2,975 tree pages and all 502,386 data pages. No game/runtime was
  replaced. Packaged integration, launch of this newly acquired copy, update
  acceptance and clean-Mac distribution checks remain separate release gates. RC3 still contains
  the older helper whose rewritten HTTPS package requests returned HTTP404;
  a successful two-byte routing probe did not establish package availability.
- Public-key provenance is recorded in
  [LICENSES/XVD-PUBLIC-KEY-PROVENANCE.txt](LICENSES/XVD-PUBLIC-KEY-PROVENANCE.txt).
  The retained Microsoft DLL's signed public-key region, Authenticode digest,
  PKCS#7 signature and current chain/CRLs were checked independently. This does
  not claim complete Windows Authenticode policy or timestamp validation.
- Downloads use mode-0700 temporary staging, validated relative paths, exclusive
  file creation, file-size checks and atomic no-replace promotion after preparation.
  Traversal, colon paths, empty/dot components, trailing dots/spaces and reserved
  staging names are rejected. The Microsoft threading component separately requires exact pinned
  SHA-256 values for both downloaded compressed bytes and the final DLL.
- Launcher-owned helpers can require a private parent-written session receipt
  before accessing credentials. They monitor the actual parent process and stop
  themselves if it dies, including during sign-in. Forced termination may leave
  private staging and a stale receipt/socket for recognized recovery.
- The Xbox service uses a user-owned mode-0600 Unix socket and process/lock checks.
  This is not a sandbox against other software already running as the same user.
- Current app builds use ad-hoc signatures. Source/resource checksums detect
  differences from recorded bytes; they do not establish a trusted publisher.
  Signing/notarization and clean-Mac checks are separate distribution work.

Do not work around failures by disabling Gatekeeper, skipping hash checks,
trusting all TLS certificates, widening Keychain access, or deleting another
process's socket. Report the failed boundary with redacted evidence instead.

## Source and binary distribution

Only files explicitly listed in `export-source.py` enter source exports.
Ignored runtime directories are not a publication boundary by themselves.
Review the staged file list and checksum inventory before pushing changes.
Never include a game, user data, Microsoft payloads, or raw local logs.

A binary release additionally needs the dependency/notices/corresponding-source
inventory in [THIRD_PARTY.md](THIRD_PARTY.md) and every gate in
[docs/RELEASE.md](docs/RELEASE.md). This document records outstanding risks; it
does not claim that public binary distribution is ready.
