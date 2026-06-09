# Vendored fork of utmapp/CocoaSpice

This directory is a vendored copy of [utmapp/CocoaSpice](https://github.com/utmapp/CocoaSpice)
(Apache License 2.0 — see `LICENSE`), the Objective-C/Metal SPICE client layer that
UTM uses, with a single addition for **spice-mac**.

## Why a fork is required

`CSConnection` keeps the underlying `SpiceSession *` private (declared only in the
in-`.m` class extension and in `CSSession+Protected.h`, neither of which is public).
Proxmox VE serves SPICE over TLS through the node's `spiceproxy`, which requires the
session be configured with `proxy`, `ca`, `cert-subject`, and subject-based `verify`
— none of which stock CocoaSpice exposes. So the configuration must happen *inside*
the library, where `spiceSession` is reachable.

## The change

A single category method, `-[CSConnection setProxy:ca:certSubject:]`:

- **`Sources/CocoaSpice/include/CSConnection+Proxmox.h`** — new public header (category interface).
- **`Sources/CocoaSpice/CSConnection.m`** — imports the header and implements the method
  (sets `proxy`, the `ca` GByteArray, `cert-subject`, and `verify = SPICE_SESSION_VERIFY_SUBJECT`).
- **`Sources/CocoaSpice/include/CocoaSpice.h`** — includes the new header in the umbrella.

The diff against pristine upstream is saved at `../cocoaspice-proxmox.patch`.

## Security hardening (spice-mac additions)

Beyond the Proxmox patch and the `CocoaSpiceRenderer` product, this fork carries a
few security fixes for guest-triggered crashes / unsafe defaults. Re-apply these
on a rebase:

- **`Sources/CocoaSpice/CSDisplay.m`** (`cs_update_monitor_area`) — replaced
  `g_assert(monitors->len <= 1)` (which aborts the process on a protocol-legal
  multi-head config — a remote DoS) with the upstream find-our-head-by-id loop.
- **`Sources/CocoaSpice/include/CSPasteboardDelegate.h`** — `setString:` made
  `nullable` so a guest sending non-UTF8 "text" (→ nil NSString) can't trap the
  Swift bridge.
- **`Sources/CocoaSpice/CSSession.m`** (`initWithSession:`) — removed the
  unconditional `setSharedDirectory:readOnly:NO`, which auto-shared a **writable**
  host folder with every guest.

## Bug fixes (spice-mac additions)

- **`Sources/CocoaSpice/CSDisplay.m` + `CSDisplay+Renderer.m`** — **blank screen on
  connect** (shown only after the guest next repaints, e.g. a click). Two parts:
  - The SPICE main loop runs on its own thread (`CSMain`). A display's primary
    surface is created there (`cs_primary_create` → `updateVisibleAreaWithRect:` →
    `rebuildCanvasTexture`), but the Metal **device** only arrives when a renderer
    attaches — from the app thread, via `-addRenderer:`. On connect the surface is
    usually created *before* the renderer attaches, so `rebuildCanvasTexture`
    early-returns on the nil device and there is no Metal canvas; the renderer then
    draws nothing until a later server damage event. Fix: `-addRenderer:` calls the
    new `-refreshContentsForNewRenderer`, which hops to the SPICE context and, with
    a device now available, builds the canvas (if not yet built) and repaints the
    current framebuffer.
  - In `updateVisibleAreaWithRect:`, build the vertices and set `ready` *before*
    `rebuildCanvasTexture`, so its initial `drawRegion:` sees `-isVisible` YES
    (`_CSRendererSourceData initWithRenderSource:` returns nil when vertices are
    missing, which otherwise drops the first blit) — this covers the case where a
    renderer/device *is* already attached when the surface is (re)created.

## Updating upstream

To re-base onto a newer CocoaSpice: replace this directory with the new upstream
tree and re-apply `../cocoaspice-proxmox.patch` (or re-add the three changes above).
The patch is intentionally tiny and is a good candidate to upstream as a PR.
