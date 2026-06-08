# Security

This documents SpiceMac's security posture, the threat model, what's hardened,
and the residual risks. It reflects a threat-model-driven audit (with adversarial
verification of every finding).

## Threat model

- **Network MITM** between the Mac and the Proxmox node — defended by TLS.
- **A malicious / compromised SPICE server or guest VM** sending hostile
  display / cursor / clipboard / agent data to the client.
- **A crafted `.vv` file** the user opens.
- **Local**: the `.vv` carries a short-lived ticket + CA; the app can run as root
  for USB; ad-hoc signing; the bundled native stack is an old UTM sysroot.

## Overall posture

The app's own code (the Swift packages + the one-method ObjC fork patch) has **no
memory-corruption or RCE-class defects**: TLS verification fails closed in every
real Proxmox flow, the guest-data sizing/coordinate math is bounds-safe, and the
CA handling is memory-safe. The real risk is **supply-chain debt** (the EOL
sysroot is the sole TLS stack and the sole parser for all hostile-server data)
plus a few guest-triggered **denial-of-service** crashes and an **unsafe-by-
default** clipboard share. Solid for personal use against a **trusted** Proxmox
node; not hardened against a deliberately hostile guest, and the EOL stack should
gate any wider distribution.

## Hardened in this repo

- **Guest→host non-UTF8 clipboard crash (DoS)** — a guest could abort the client
  by sending non-UTF8 bytes labelled as text (nil trapped the Swift bridge). The
  delegate is now nullable and guards nil; guest payloads are size-capped.
- **Multi-head monitor-config crash (DoS)** — a protocol-legal multi-head config
  hit a `g_assert` and aborted the process; restored the upstream find-by-id loop
  (never assert on attacker-controlled SPICE fields).
- **Writable host folder auto-shared to every guest** — removed; folder sharing
  should be opt-in and read-only (no UI yet → nothing shared).
- **Clipboard sharing is now a preference** (Connection ▸ Share Clipboard with VM,
  default on) so it can be disabled for untrusted VMs.
- **TLS fail-closed guard** — refuse to connect if a `.vv` requests
  certificate-subject verification but supplies no CA.
- **Mandatory sysroot integrity** — `fetch-sysroot.sh` refuses an unverified URL
  download unless `SPICEMAC_SYSROOT_SHA256` is pinned.

## Residual risks (not fixed in code)

1. **EOL native stack (highest real risk).** The bundled UTM sysroot ships
   **OpenSSL 1.1.1b (Feb 2019)**, spice-gtk 0.42, glib, gstreamer 1.19.1,
   usbredir. OpenSSL 1.1.1b is reachable on the TLS path and is vulnerable to
   **CVE-2022-0778** (BN_mod_sqrt infinite loop) — a crafted server/MITM cert can
   hang the client during the handshake (DoS, not a verification bypass or RCE).
   The EOL crypto/parser stack is also where any future server-reachable
   memory-safety bug would land. **Action:** rebuild the sysroot against a
   supported OpenSSL (3.x, or ≥ 1.1.1w) with matching spice-gtk/glib/gstreamer,
   pin the versions + SHA256, and gate wider distribution on the refresh.

2. **Running as root for USB.** `scripts/run-as-root.sh` runs the *entire* GUI —
   including the SPICE/glib/gstreamer/OpenSSL/usbredir parsers that consume
   hostile-server data — as root, so any parser bug becomes root-impact. **Action
   (for distribution):** move only USB capture into a minimal privileged XPC
   helper that parses no network data; keep the SPICE stack unprivileged. For
   personal use, only run as root when you actually need USB, against trusted VMs.

3. **Distribution signing.** The default build is ad-hoc; the optional
   `HARDENED=1` entitlements include `com.apple.security.cs.disable-library-
   validation` (weakens dylib signing checks). For distribution: sign with
   **Developer ID + hardened runtime + notarization**, sign each bundled
   framework, and **drop `disable-library-validation`**.

4. **Clipboard is shared by default** (host↔guest). While on, anything copied on
   the Mac is sent to the guest. Disable it (Connection menu) for untrusted VMs.

## Reporting

This is a personal/open-source project — open an issue, or for a real
vulnerability contact the maintainer privately before public disclosure.
