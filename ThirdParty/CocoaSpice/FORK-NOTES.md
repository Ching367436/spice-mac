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

## Updating upstream

To re-base onto a newer CocoaSpice: replace this directory with the new upstream
tree and re-apply `../cocoaspice-proxmox.patch` (or re-add the three changes above).
The patch is intentionally tiny and is a good candidate to upstream as a PR.
