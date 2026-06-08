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

```sh
# 1. Stage the native SPICE dependency frameworks (arm64). See "Dependencies".
SPICEMAC_SYSROOT_URL="https://…/Sysroot-macos-arm64.tgz" \
SPICEMAC_SYSROOT_SHA256="…" \
  ./scripts/fetch-sysroot.sh

# 2. Build and assemble SpiceMac.app
./scripts/build-app.sh            # → build/SpiceMac.app

# 3. Run
open build/SpiceMac.app
```

### Dependencies

CocoaSpice does **not** bundle the native libraries it links (glib, gstreamer,
spice-client-glib, libusb, …). `scripts/fetch-sysroot.sh` stages them from a
prebuilt UTM "Sysroot" of `@rpath`-relocatable frameworks:

- Preferred: set `SPICEMAC_SYSROOT_URL` (+ `SPICEMAC_SYSROOT_SHA256`) to a pinned,
  re-hosted sysroot tarball.
- Or: `gh auth login`, then run the script to pull a UTM CI `Sysroot-macos-arm64`
  artifact (these expire ~90 days, so pin and re-host one).
- Fallback: build from source with UTM's `scripts/build_dependencies.sh -p macos
  -a arm64` and `pack_dependencies.sh`.

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
- **EOL deps.** UTM sysroots pin older libraries (e.g. OpenSSL 1.1.1b); acceptable
  for personal use, but they carry their own CVEs.

## USB redirection

USB redirect is available under **Connection ▸ USB Devices**, but macOS gates it:
`LIBUSB_ERROR_ACCESS` ("could not claim interface") means a **built-in kernel
driver already owns the device**. macOS auto-binds drivers to mass storage, HID
(keyboards/mice), USB audio, serial/CDC, iOS devices and hubs, and the device
must be *captured* away from that driver to redirect it — which requires one of:

- **Root.** The only entitlement-free path on a personal/ad-hoc build. Launch via
  `./scripts/run-as-root.sh <file>.vv` (the bundled libusb supports macOS device
  capture). Running a GUI as root is discouraged; capture is whole-device; HID may
  not detach even as root.
- **`com.apple.vm.device-access`** — an Apple-*restricted* entitlement (needs a
  provisioning profile + Apple approval and Developer ID signing; **ad-hoc
  signatures can't carry it**). This is what UTM's official builds use.

`com.apple.security.device.usb` and Hardened Runtime do **not** help (sandbox-only
/ no-op). **Driverless devices** (vendor-specific class `0xFF`, FTDI on macOS 12+,
many JTAG/printer dongles) redirect **without root** — check with
`ioreg -p IOUSB -l | grep IOUSBHostInterface` (no class-driver client bound → OK).

## Security

See [SECURITY.md](SECURITY.md). In short: the app code is sound (no RCE/memory-
corruption; TLS fails closed), but it bundles an **EOL native stack** (OpenSSL
1.1.1b etc.) that should be refreshed before wider distribution, clipboard sharing
is on by default (toggle in the Connection menu), and `run-as-root.sh` runs the
whole parser surface as root — fine for personal use against trusted VMs.

## Licensing

- App code in this repo: see `LICENSE`.
- `ThirdParty/CocoaSpice`: Apache-2.0 (vendored fork; `LICENSE` retained).
- The native SPICE stack it links (glib/gstreamer/spice-gtk) is LGPL — honored by
  dynamic linking; offer the object files if you redistribute a built app.

## Layout

| Path | Purpose |
|------|---------|
| `Packages/VVConfig` | `.vv` parser + `SpiceConnectionParameters` (tested) |
| `Packages/SpiceInputMap` | keycode → set-1 scancode map (tested) |
| `Packages/SpiceController` | connection lifecycle, input/clipboard glue |
| `Sources/SpiceMac` | AppKit/Metal application |
| `ThirdParty/CocoaSpice` | vendored Apache-2.0 fork + Proxmox patch |
| `Frameworks/` | native SPICE frameworks (staged, git-ignored) |
| `scripts/` | `fetch-sysroot.sh`, `build-app.sh` |
