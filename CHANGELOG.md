# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Guest cursor no longer follows the Mac pointer outside the window.** AppKit
  sends `mouseMoved` to the key window even when the pointer is outside it, and
  in client mouse mode those events were forwarded with coordinates clamped to
  the guest edge. With a window smaller than the screen, the guest cursor stuck
  to the edge and slid along it. Motion outside the view is now dropped unless a
  button is held, so a drag that leaves the window still tracks and releases.

## [0.1.8] — 2026-08-28

### Added

- **Display zoom (View ▸ Zoom).** On a Retina Mac the client asked the guest for
  the view's full *backing pixel* count, so a 1512×982-point window drove the
  guest at 3024×1964 — the guest has no idea the Mac is HiDPI, so it rendered
  one pixel per pixel and everything came out half size, while the VM pushed
  four times the pixels it needed. Zoom is now **Z = Mac physical pixels per
  guest pixel**: the client requests `points × backing scale ÷ Z` and each guest
  pixel is drawn as a Z×Z block, so readability and cost improve together.
  Shortcuts **⌃⌘+ / ⌃⌘− / ⌃⌘0**.

- **The zoom level is per-window, and a fixed level is absolute.** Each window
  is its own session on its own display, so it carries its own level: picking
  one in the front window leaves the others alone. The commands live on the
  window controller and reach it down the responder chain the way `Connection ▸
  Send Ctrl-Alt-Del` already did, so the submenu greys out with no session open;
  the preference is only the seed a new window starts from. Nothing but the user
  ever changes a level — **Automatic** is the mode for constant apparent size
  across a move.

- **A window that changes display re-applies its geometry.** At a fixed level
  the target guest size is `points × backing scale ÷ Z`, and a move changes the
  backing scale out from under it — which is why it used to need a manual nudge
  of the window before the guest came out right. All four signals AppKit offers
  now drive it, including `NSApplicationDidChangeScreenParameters` for hotplug,
  sleep/wake and Displays scaled-mode changes, which resize the window without a
  live resize. Requests are coalesced, so four triggers cost at most one guest
  mode switch.

- **Without `spice-vdagent`, zoom and screen changes resize the *window***
  (`guest × Z ÷ backing scale` points) rather than doing nothing — the guest
  resolution is fixed, so that is the only side of the equation left. The
  geometry is a new dependency-free package, `Packages/DisplayScale`, with a
  21-check `scalecheck` runner wired into `make test` and CI.

### Changed

- **The default zoom is Automatic (Z = the screen's backing scale), which
  changes behaviour on upgrade.** The guest resolution now tracks the window's
  *point* size instead of its backing-pixel size, so on first connect after
  updating a Retina guest drops to roughly half its previous resolution and
  everything in it gets twice as big. That is the fix; **View ▸ Zoom ▸ 100%**
  restores the old behaviour. Automatic also means the requested resolution is
  the window's point size on *any* display, so dragging between screens needs no
  guest reconfiguration.

### Fixed

- **A dead connection no longer hides its own explanation.** When a session
  ended, the last guest frame stayed frozen over the window (the Metal view is
  opaque and `detach()` leaves it showing its final texture), so the
  "Disconnected — open a fresh .vv file" hint or the failure reason was drawn
  invisibly behind it and the window just looked hung. The display view now
  hides when the session ends and returns on the next connect, revealing the
  centered status message. A specific failure reason (`.failed`) is also kept
  if the generic disconnect callback arrives after the error one, instead of
  being downgraded to "Disconnected."

- **ISO / French Magic Keyboard `<>` key now reaches the guest.** The keymap was
  ANSI-only and omitted `kVK_ISO_Section` (`0x0A`), the key next to Left Shift on
  ISO hardware (e.g. French AZERTY `<` / `>`). Presses produced no guest event.
  Map it to PC set-1 `KEY_102ND` (`0x56`); `inputcheck` covers the mapping.
  (#4)

- **Guest text was blurry at some window sizes and not others**, worst on a
  normal-DPI monitor. The sampler only went nearest-neighbour at 2× or more, so
  a 1:1 presentation — what 100% means on a 1x screen — always took the bilinear
  path; and because the requested mode is floored onto the 8-wide/2-high grid
  guest drivers want, the centred quad landed on a **half-pixel** offset
  whenever that slack was odd. Nearest now applies at any whole-number
  magnification, and `viewportOrigin` nudges the quad onto whole pixels — the
  input router subtracts the same origin, so the cursor stays locked.

- **Dragging a window between a Retina panel and a 1x monitor did not re-scale
  the guest.** `MTKView` refreshes `drawableSize` lazily, so inside
  `viewDidChangeBackingProperties` — the one moment such a move offers — it
  still holds the *previous* screen's value: on a real 2.0↔1.0 drag the callback
  reports `backingScaleFactor` 1.0 while `drawableSize` is still 1800×1200 for a
  view that is now 900×600 physical pixels. The fit now measures with
  `convertToBacking(bounds)`, which follows the backing store immediately, and
  pulls the drawable up to match.
## [0.1.7] — 2026-06-15

### Fixed

- **Copying a spreadsheet cell in the guest now pastes onto the Mac.** A guest
  copy offers several clipboard representations at once (a cell = UTF-8 text + a
  bitmap image); the guest→host bridge cleared the Mac pasteboard on every write,
  so the representations clobbered each other and only the last survived — usually
  the image, leaving nothing to paste as text. The bridge now clears once per
  guest grab and accumulates the rest, so the cell's text (and image) both land.
  Plain-text copy was unaffected because it's a single type. (Fork change — see
  `ThirdParty/CocoaSpice/FORK-NOTES.md`.)

### Security

- **Hardened the `.vv` parser** (the one attacker-influenced file the app opens):
  a **1 MiB file-size cap** + UTF-8 enforcement in `VVConfig(contentsOf:)`,
  **control-character stripping** from values (a `NUL` in `host`/`proxy` would
  otherwise survive Swift validation but truncate inside the C SPICE stack — a
  smuggle), **port-range validation** (only 1–65535; junk/negative/overflow become
  "absent"), and leading-BOM tolerance. Added a deterministic **20k-iteration
  fuzzer** + edge-case tests (`vvcheck`, now 24 checks) proving the parser never
  crashes on arbitrary input.

## [0.1.6] — 2026-06-09

### Security

- **OpenSSL upgraded to 3.5.6 (LTS, maintained to 2030)**, retiring the EOL 1.1.1
  branch — the server-facing TLS stack is now current. It's built under the old
  `ssl.1.1`/`crypto.1.1` install names so spice-gtk (compiled against 1.1.1) loads it
  unchanged, and `upgrade-openssl.sh` verifies all ~72 of spice-gtk's OpenSSL symbols
  resolve in 3.x before swapping (then a real TLS connection was confirmed). The
  pinned default sysroot (`sysroot-arm64-v2`) ships 3.5.6, so a fresh clone is current
  with no extra step.

## [0.1.5] — 2026-06-09

### Changed

- **Hardened `run-as-root.sh`** (the supported USB-capture path): a clear
  trust-boundary warning + confirmation prompt (`-y` to skip), absolute-path
  resolution of the `.vv`, and a `sudo --` option-injection guard. Documented
  run-as-root honestly in the README and SECURITY.md — including **why a privileged
  USB helper was scoped and deferred**: macOS forces the boundary at the usbredirhost
  seam (a partial win that still parses guest data in root, needing a spice-gtk fork +
  framework rebuild and a sudo-installed LaunchDaemon); the genuinely clean fix is the
  `com.apple.vm.device-access` entitlement, gated on a Developer ID.

### Fixed

- **`.vv` is no longer moved to root's Trash** when launched via `run-as-root.sh`. The
  "Move .vv to Trash after connecting" preference is skipped under root (it would
  otherwise land in `/var/root/.Trash` instead of yours); the file is left in place.

## [0.1.4] — 2026-06-09

### Security

- **Multi-head monitor-config crash (DoS), second site.** A guest reporting more
  than one monitor config on a display channel — a protocol-legal multi-head
  configuration — tripped `g_assert(cfgs->len == 1)` in `cs_display_monitors` and
  aborted the whole client. Removed the assert; the handler now just creates/updates
  the (single-display-per-channel) display on any non-empty config, leaving per-head
  geometry to `cs_update_monitor_area`. Same DoS class as the `cs_update_monitor_area`
  fix already shipped. (Fork change — see `ThirdParty/CocoaSpice/FORK-NOTES.md`.)

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

[Unreleased]: https://github.com/Ching367436/spice-mac/compare/v0.1.8...HEAD
[0.1.8]: https://github.com/Ching367436/spice-mac/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/Ching367436/spice-mac/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/Ching367436/spice-mac/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/Ching367436/spice-mac/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/Ching367436/spice-mac/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/Ching367436/spice-mac/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/Ching367436/spice-mac/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Ching367436/spice-mac/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Ching367436/spice-mac/releases/tag/v0.1.0
