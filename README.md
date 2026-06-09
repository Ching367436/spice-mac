<p align="center">
  <img src="design/icon/icon.png" width="168" height="168" alt="SpiceMac app icon">
</p>

# SpiceMac

A native macOS [SPICE](https://www.spice-space.org/) client that opens **Proxmox VE**
virtual-machine consoles from `.vv` connection files, built on a forked
[CocoaSpice](https://github.com/utmapp/CocoaSpice) (the Metal-rendered SPICE layer
UTM uses). Apple-Silicon only.

> **Status: working** against a real Proxmox VE VM (Xcode 26.5 + the UTM arm64
> sysroot). Verified end-to-end: Metal display with aspect-fit scaling and live
> resize; keyboard including ⌘/modifiers; mouse with the guest cursor aligned to
> the macOS pointer; bidirectional clipboard; and audio (needs a SPICE audio
> device on the VM). USB redirection is plumbed via the Connection menu. The `.vv`
> parser and keyboard map are also unit-tested (28 dependency-free checks).
>
> | Feature | Status |
> |---|---|
> | Display (Metal) + aspect-fit scaling + live resize | ✅ |
> | Keyboard incl. ⌘ / modifiers (self-healing on missed key-up) | ✅ |
> | Mouse + cursor alignment; optional hide-Mac-cursor | ✅ |
> | Clipboard (Mac↔VM, both directions) | ✅ |
> | Audio (guest needs a SPICE audio device) | ✅ |
> | USB redirection | plumbed |

## Download

Prebuilt `SpiceMac.app` bundles are attached to each
[Release](https://github.com/Ching367436/spice-mac/releases) (Apple-Silicon only).
You can also [build from source](#build).

### Why it's unsigned

The prebuilt `.app` is **ad-hoc signed**, not **Developer-ID-signed or notarized**.
Developer-ID signing + notarization require a paid **Apple Developer Program**
membership (US$99/yr) this project can't currently fund. Ad-hoc signing is real and
locally valid — it's why the app runs at all on Apple Silicon — but macOS Gatekeeper
still treats the download as coming from an unidentified developer and prompts once
on first launch. If a signed + notarized build matters to you, you can help fund the
membership (see [Sponsoring](#sponsoring)) or just build from source.

### Opening an unsigned build

After unzipping and moving `SpiceMac.app` to `/Applications`, do one of:

- **macOS 14 (Sonoma):** right-click (Control-click) the app ▸ **Open** ▸ **Open**
  in the dialog (only needed once).
- **macOS 15 (Sequoia) and later:** double-click once (you'll see *"Apple could not
  verify…"* — click **Done**), then **System Settings ▸ Privacy & Security ▸ Open
  Anyway**, and confirm. (Sequoia removed the old right-click→Open shortcut here.)
- **Terminal (works on both)** — clear the quarantine flag, then open:

  ```sh
  xattr -dr com.apple.quarantine /Applications/SpiceMac.app
  open /Applications/SpiceMac.app
  ```

Verify your download against the SHA-256 in the release notes before clearing
quarantine:

```sh
shasum -a 256 SpiceMac.app.zip   # compare to the value in the Release
```

See [SECURITY.md](SECURITY.md) for the full signing/trust posture.

## Why this exists

There is no pleasant native SPICE client on macOS — `remote-viewer`/`spice-gtk`
builds are heavy, GTK/X11-bound, and sluggish. SpiceMac wraps the same mature
SPICE stack but renders through Metal in a small native app, and connects to
Proxmox the way the Proxmox web UI does: by consuming the short-lived `.vv` file.

## Architecture

```
AppKit + SwiftUI chrome           Sources/SpiceMac
        │   (MTKView host, .vv open, menus, USB picker, window mgmt)
        ▼
SpiceController (Swift)           Packages/SpiceController
        │   CSConnectionDelegate, NSEvent→CSInput, NSPasteboard bridge, lifecycle
        ▼
CocoaSpice (forked, Obj-C)        ThirdParty/CocoaSpice   ← Proxmox patch
        │   Metal renderer, channels, USB, clipboard over spice-client-glib
        ▼
Native SPICE frameworks (arm64)   Frameworks/  (staged by scripts/fetch-sysroot.sh)
        spice-client-glib, glib, gstreamer, libusb, usbredir, openssl, …

Pure-Swift, independently testable:
  VVConfig        Packages/VVConfig       — virt-viewer .vv parser (+ Proxmox)
  SpiceInputMap   Packages/SpiceInputMap  — macOS keycode → PC set-1 scancode
```

The decisive design point: **CocoaSpice must be forked.** `CSConnection` keeps the
underlying `SpiceSession` private, so the Proxmox knobs (`proxy`, `ca`,
`cert-subject`, subject-verify) can only be set from inside the library. The fork
adds exactly one method, `-[CSConnection setProxy:ca:certSubject:]`
(`ThirdParty/cocoaspice-proxmox.patch`, rationale in `ThirdParty/CocoaSpice/FORK-NOTES.md`).

## Requirements

- Apple Silicon Mac, macOS 12+.
- **Full Xcode** (build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).
- The **Metal toolchain component** — on Xcode 26 it is a separate download:
  `xcodebuild -downloadComponent MetalToolchain`. Needed because SwiftPM does not
  compile `.metal` resources; `build-app.sh` compiles the shader into the bundle.
- The native SPICE frameworks staged under `Frameworks/` (see *Dependencies*).

## Build

**Prerequisites (one-time).** Full **Xcode** (Command Line Tools alone can't build
this), then select it and add the Metal toolchain component:

```sh
sudo xcode-select -s /Applications/Xcode.app
xcodebuild -downloadComponent MetalToolchain   # Xcode 26: a separate download
```

Then, from a fresh clone:

```sh
make doctor   # verify Xcode + Metal toolchain + frameworks (prints fixes if not)
make all      # fetch the pinned sysroot, then build → build/SpiceMac.app
make run      # open it
```

`make` wraps the scripts in `scripts/` and injects `DEVELOPER_DIR` so you can't
forget it (`make help` lists every target). By hand it's:

```sh
./scripts/fetch-sysroot.sh   # pinned, checksummed sysroot (OpenSSL already 3.5.6 LTS)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-app.sh
open build/SpiceMac.app
```

### Dependencies

CocoaSpice does **not** bundle the native libraries it links (glib, gstreamer,
spice-client-glib, libusb, …). `scripts/fetch-sysroot.sh` stages them. By default it
downloads a **pinned, SHA-256-checksummed** tarball published on this repo's
[releases](https://github.com/Ching367436/spice-mac/releases/tag/sysroot-arm64-v2) —
the 26-framework + 19-plugin build/runtime closure (LGPL/MIT/BSD/OpenSSL only, **no
GPL**, OpenSSL already 3.5.6 LTS). So a fresh clone builds with no extra setup, and the
script fails closed on a checksum mismatch.

Alternatives (rarely needed):

- **Your own tarball:** set `SPICEMAC_SYSROOT_URL` (+ `SPICEMAC_SYSROOT_SHA256`).
- **A fresh UTM CI build:** `SPICEMAC_SYSROOT_FROM_GH=1 ./scripts/fetch-sysroot.sh`
  (needs `gh auth login`; UTM artifacts expire ~90 days). That sysroot ships the EOL
  OpenSSL 1.1.1b, so follow it with `./scripts/upgrade-openssl.sh` (→ 3.5.6 LTS; see
  [SECURITY.md](SECURITY.md)).
- **From source:** UTM's `scripts/build_dependencies.sh -p macos -a arm64` +
  `pack_dependencies.sh`.

The vendored `ThirdParty/CocoaSpice/Sources/CocoaSpice/ExternalHeaders/` provides
the matching build-time headers; keep the sysroot version in sync with them.

## Connecting to Proxmox

1. In the Proxmox web UI, open a VM whose **Display is set to SPICE/qxl**
   (`qm set <vmid> --vga qxl`), click **Console ▸ SPICE**, and download the
   `.vv` file.
2. Open it in SpiceMac (double-click, drag onto the app, or **File ▸ Open**).
   **Do this promptly** — the SPICE ticket inside is single-use and valid for only
   ~30 seconds. To reconnect, download a fresh `.vv`.
3. For clipboard sharing and dynamic resolution, the guest must run
   **`spice-vdagent`**.

What the app does with the `.vv`: parses the opaque `host` token, `proxy`
(`http://node:3128`), `tls-port`, one-time `password`, `host-subject`, and CA
(expanding the escaped `\n`), then connects over TLS through the node's
`spiceproxy`, verifying the server by **certificate subject** against the supplied
CA.

## Verifying the tested components

The pure-Swift libraries build and test with just the Swift toolchain (no Xcode):

```sh
( cd Packages/VVConfig     && swift run vvcheck )     # .vv parser: 15 checks
( cd Packages/SpiceInputMap && swift run inputcheck )  # scancode map: 13 checks
```

The CocoaSpice fork patch was syntax-checked against the real vendored
glib/spice headers (`clang -fsyntax-only`, exit 0).

## Gotchas

- **Ticket lifetime / opaque host.** The `.vv` ticket lasts ~30 s and is
  single-use; `host` is a `pvespiceproxy:…` token, not a hostname — the connection
  *must* go through `proxy=…:3128`. Re-download for every (re)connect.
- **Inverted TLS verification.** Trust the self-signed PVE cluster CA and match
  `cert-subject`; normal hostname/pubkey checks fail by design.
- **Guest agent required** for clipboard + dynamic resolution.
- **Audio needs a SPICE audio device on the VM** — most Proxmox VMs ship without
  one, so there's no playback channel. Add **Hardware ▸ Audio Device** (e.g.
  `ich9-intel-hda`, backend **SPICE**) and reboot the guest.
- **`pveproxy` gating.** `/etc/default/pveproxy` `ALLOW_FROM`/cipher rules can
  reset port 3128 even with a valid ticket.
- **Dep ages.** The pinned sysroot ships **OpenSSL 3.5.6 (LTS)** and **spice-gtk 0.42
  (the latest upstream release)**, but **glib/gstreamer** are still the older UTM build
  (lower-priority; acceptable for personal use but carry their own CVEs). (A raw UTM
  sysroot still has OpenSSL 1.1.1b — run `upgrade-openssl.sh`.)

## USB redirection

USB redirect is available under **Connection ▸ USB Devices**, but macOS gates it:
`LIBUSB_ERROR_ACCESS` ("could not claim interface") means a **built-in kernel
driver already owns the device**. macOS auto-binds drivers to mass storage, HID
(keyboards/mice), USB audio, serial/CDC, iOS devices and hubs, and the device
must be *captured* away from that driver to redirect it — which requires one of:

- **Root** — the supported, entitlement-free path on a personal/ad-hoc build. Launch
  via `./scripts/run-as-root.sh <file>.vv` (the bundled libusb supports macOS device
  capture). The script warns and asks for confirmation (`-y` to skip).
  ⚠️ It runs the **whole app** as root — including the parsers that read data from
  the SPICE server — so use it only against a VM/node you **trust**, and only when
  you actually need a kernel-claimed device. Capture is whole-device; HID may not
  detach even as root. (A privileged helper that would keep the SPICE stack
  unprivileged was scoped and deferred — see [SECURITY.md](SECURITY.md).)
- **`com.apple.vm.device-access`** — an Apple-*restricted* entitlement (needs a
  provisioning profile + Apple approval and Developer ID signing; **ad-hoc
  signatures can't carry it**). This is what UTM's official builds use, and the
  genuinely clean fix — gated on the same Developer ID as notarization.

`com.apple.security.device.usb` and Hardened Runtime do **not** help (sandbox-only
/ no-op). **Driverless devices** (vendor-specific class `0xFF`, FTDI on macOS 12+,
many JTAG/printer dongles) redirect **without root** — check with
`ioreg -p IOUSB -l | grep IOUSBHostInterface` (no class-driver client bound → OK).

## Security

See [SECURITY.md](SECURITY.md). In short: the app code is sound (no RCE/memory-
corruption; TLS fails closed). The server-exposed native libraries are current —
**spice-gtk 0.42 is the latest upstream release** and the bundled **OpenSSL is 3.5.6
(LTS, to 2030)** — while glib/gstreamer are still the older UTM build (lower-priority;
see SECURITY.md). Clipboard sharing is on by default (toggle in the Connection menu),
and `run-as-root.sh` runs the whole parser surface as root — fine for personal use
against trusted VMs.

## Sponsoring

SpiceMac is free and open source. The one recurring cost it can't absorb is the
**Apple Developer Program** membership (US$99/yr) needed to ship Developer-ID-signed,
notarized builds that open without the Gatekeeper detour above. If you'd like to fund
that, use the repo's **Sponsor** button (see [`.github/FUNDING.yml`](.github/FUNDING.yml)),
or send ETH to **`ching367436.eth`**
([Etherscan](https://etherscan.io/address/ching367436.eth)). It's entirely optional —
building from source, and rebuilding to verify a download, will always stay free.

## Licensing

- SpiceMac's own code: **MIT** (see [LICENSE](LICENSE)).
- `ThirdParty/CocoaSpice`: **Apache-2.0** (vendored fork; `LICENSE` retained, changes in
  [FORK-NOTES.md](ThirdParty/CocoaSpice/FORK-NOTES.md)).
- The native SPICE stack (fetched at build time, bundled into a built `.app`) is mostly
  **LGPL-2.1+** (glib/spice-gtk/gstreamer/libusb/usbredir/…), with **OpenSSL** (OpenSSL/
  SSLeay) and **MIT/BSD** (pixman, opus, libffi, libjpeg-turbo). Full attribution +
  the LGPL written offer: [THIRD-PARTY-LICENSES.txt](THIRD-PARTY-LICENSES.txt).
- The GStreamer plugins are **statically** linked, so LGPL §6(a) (rebuildable open app
  source) applies. The build bundles only the runtime closure — the upstream sysroot's
  **GPL-2.0 QEMU** frameworks are *not* shipped.
- **Distributing a built `.app`?** It already self-carries the verbatim LGPL-2.1 /
  Apache-2.0 / OpenSSL / BSD / MIT texts at `Contents/Resources/Licenses/` (sources in
  [`licenses/`](licenses/)), plus the LGPL §6 written offer in
  [THIRD-PARTY-LICENSES.txt](THIRD-PARTY-LICENSES.txt). Honor those source/relink
  obligations when you redistribute.

## Layout

| Path | Purpose |
|------|---------|
| `Packages/VVConfig` | `.vv` parser + `SpiceConnectionParameters` (tested) |
| `Packages/SpiceInputMap` | keycode → set-1 scancode map (tested) |
| `Packages/SpiceController` | connection lifecycle, input/clipboard glue |
| `Sources/SpiceMac` | AppKit/Metal application |
| `ThirdParty/CocoaSpice` | vendored Apache-2.0 fork + Proxmox patch |
| `Frameworks/` | native SPICE frameworks (staged, git-ignored) |
| `Makefile` | task runner over `scripts/` (`make help`) |

### Scripts (`scripts/` — or use the `make` target)

| Script | `make` | When you'd run it |
|--------|--------|-------------------|
| `doctor.sh` | `doctor` | Check the build environment (Xcode, Metal toolchain, frameworks) |
| `fetch-sysroot.sh` | `setup` | Stage the native SPICE frameworks (pinned, checksummed) |
| `build-app.sh` | `build` | Build + assemble `build/SpiceMac.app` |
| `upgrade-openssl.sh` | `openssl` | Rebuild OpenSSL → 3.5.6 (only on a raw UTM sysroot) |
| `make-icon.sh` | `icon` | Regenerate `Resources/AppIcon.icns` from `design/icon/` |
| `debug-run.sh` | `debug VV=…` | Launch with verbose SPICE/CocoaSpice tracing |
| `run-as-root.sh` | `root VV=…` | Launch as root for USB capture (kernel-claimed devices) |
| `release.sh` | `release VERSION=…` | Cut a release (bump, changelog, build, tag, publish) |
| `check-version.sh` | `check-version` | Assert Info.plist / CHANGELOG / tag versions agree |
