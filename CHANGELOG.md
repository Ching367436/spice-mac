# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.3] — 2026-06-09

### Added

- **Move `.vv` to Trash after connecting** (File menu, default on). Proxmox SPICE
  tickets are single-use and the file also carries the cluster CA, so the used file
  is moved to the Trash (recoverable, not a hard delete) once it's opened a
  connection. Toggle off in **File ▸ Move .vv to Trash After Connecting**.

### Fixed

- **Blank screen on connect.** The display stayed black until the guest next
  repainted (e.g. a mouse click) because the SPICE loop (its own thread) created the
  primary surface before a Metal device was available — the device only arrives when
  a renderer attaches, from the app thread — so `rebuildCanvasTexture` early-returned
  and no Metal canvas was ever built. `-addRenderer:` now repaints the current
  framebuffer on the SPICE context once a device is attached, and
  `updateVisibleAreaWithRect:` orders vertices/ready before the initial draw. (Fork
  change — see `ThirdParty/CocoaSpice/FORK-NOTES.md`.)

### Changed

- **Reproducible builds** — `fetch-sysroot.sh` now downloads a **pinned,
  SHA-256-checksummed** native-dependency tarball from the repo's releases by
  default (the 26-framework + 19-plugin closure; LGPL/MIT/BSD/OpenSSL only, no GPL;
  OpenSSL already 1.1.1w). A fresh clone builds with **no `gh`/UTM artifact and no
  extra env vars** — fixing the prior reliance on UTM CI artifacts that expire ~90
  days. A fresh UTM build is still available via `SPICEMAC_SYSROOT_FROM_GH=1`.

## [0.1.2] — 2026-06-09

### Added

- **App icon** — a warm "spice"-palette squircle with a glowing remote-console
  screen and signal arcs. Wired in via `CFBundleIconFile`; shows in the Dock,
  Finder, and ⌘-Tab. Source art + the masking pipeline live in `design/icon/`;
  regenerate the `.icns` with `scripts/make-icon.sh`.

## [0.1.1] — 2026-06-09

Adds a **prebuilt download** alongside the source release.

### Added

- **Prebuilt `SpiceMac.app`** attached to the GitHub release (Apple Silicon),
  **ad-hoc signed** (not Developer-ID-signed/notarized — that needs a paid Apple
  Developer membership the project can't yet fund). README documents how to open it
  past Gatekeeper, and each release publishes a **SHA-256** of the zipped app.
- **`.github/FUNDING.yml`** — sponsorship to fund Developer-ID signing + notarization.
- **In-bundle license notices** — `build-app.sh` now copies the verbatim LGPL-2.1 /
  Apache-2.0 / OpenSSL / BSD-3-Clause / MIT texts and `THIRD-PARTY-LICENSES.txt` into
  `Contents/Resources/Licenses/`, so a distributed binary self-carries the required
  notices (LGPL-2.1 §6/§1, Apache-2.0 §4(a), OpenSSL/BSD/MIT binary clauses).
- **`licenses/`** — the verbatim upstream license texts, in the repo.

### Changed

- `THIRD-PARTY-LICENSES.txt` now records the bundled library versions and a proper
  **LGPL §6 written offer** (valid 3 years, to any third party), replacing the
  informal source pointer.
- `build-app.sh` packages the app with `ditto` (preserves symlinks + nested ad-hoc
  signatures) and strips the leftover absolute Xcode toolchain rpath from the binary.

## [0.1.0] — 2026-06-08

First public release. A native macOS (Apple Silicon) SPICE client that opens
Proxmox VE consoles from `.vv` files, rendering through Metal over a forked
CocoaSpice.

### Added

- **Display** — Metal-rendered SPICE display with aspect-fit scaling, live window
  resize, and dynamic guest resolution (requires `spice-vdagent`).
- **Keyboard** — full keymap (macOS keycode → PC set-1 scancodes, `0xE0`
  extended), including ⌘/modifiers with self-healing on missed key-up, Caps Lock,
  and Ctrl-Alt-Del / Release-Cursor menu commands.
- **Mouse & cursor** — absolute/relative motion, scroll, buttons; guest cursor
  aligned to the macOS pointer; optional hide-Mac-cursor (View menu, off by
  default).
- **Clipboard** — bidirectional text sharing between Mac and guest, on by default
  with a Connection-menu toggle and a 64 MB transfer cap.
- **Audio** — guest audio playback (requires a SPICE audio device on the VM).
- **USB redirection** — Connection ▸ USB Devices picker; documented the macOS
  device-capture gate and shipped `scripts/run-as-root.sh` for kernel-claimed
  devices.
- **Proxmox connection** — `.vv` parser (opaque host token, proxy, tls-port,
  one-time ticket, host-subject, CA), connecting over TLS through the node's
  `spiceproxy` with certificate-subject verification.
- **Forked CocoaSpice** — adds `-[CSConnection setProxy:ca:certSubject:]` (the one
  method needed for Proxmox's proxy + subject-verify TLS); see
  `ThirdParty/CocoaSpice/FORK-NOTES.md`.
- **Tooling** — `scripts/fetch-sysroot.sh` (pinned, checksummed native frameworks),
  `scripts/build-app.sh` (compiles the Metal shader, bundles only the runtime
  closure), and dependency-free test runners (`vvcheck`, `inputcheck`).

### Security

- Upgraded the bundled OpenSSL from the EOL 1.1.1b to **1.1.1w**
  (`scripts/upgrade-openssl.sh`), fixing CVE-2022-0778.
- TLS fails closed: a TLS+subject-verify connection with no CA is rejected.
- Fixed display channel DoS crashes (multi-head `g_assert`, non-UTF8 clipboard).
- Bundle only the 26-framework runtime closure — the upstream sysroot's GPL-2.0
  QEMU frameworks are no longer shipped (app size 443 MB → 23 MB).
- See [SECURITY.md](SECURITY.md) for the threat model and residual risks.

[Unreleased]: https://github.com/Ching367436/spice-mac/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/Ching367436/spice-mac/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/Ching367436/spice-mac/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Ching367436/spice-mac/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Ching367436/spice-mac/releases/tag/v0.1.0
