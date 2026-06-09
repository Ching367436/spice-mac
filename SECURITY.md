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
  hit a `g_assert` and aborted the process, in two places: the per-surface area
  update (restored the upstream find-by-id loop) and the display create/update
  handler (`cs_display_monitors`, where the assert was simply removed). Never
  assert on attacker-controlled SPICE fields.
- **Writable host folder auto-shared to every guest** — removed; folder sharing
  should be opt-in and read-only (no UI yet → nothing shared).
- **Clipboard sharing is now a preference** (Connection ▸ Share Clipboard with VM,
  default on) so it can be disabled for untrusted VMs.
- **TLS fail-closed guard** — refuse to connect if a `.vv` requests
  certificate-subject verification but supplies no CA.
- **Mandatory sysroot integrity** — `fetch-sysroot.sh` downloads a **pinned,
  SHA-256-checksummed** sysroot by default and refuses any URL download whose digest
  doesn't match (a custom `SPICEMAC_SYSROOT_URL` still requires `SPICEMAC_SYSROOT_SHA256`).
- **OpenSSL upgraded 1.1.1b → 1.1.1w** — `scripts/upgrade-openssl.sh` builds the
  final 1.1.1 release from (SHA-256-verified) source and drops it into
  `Frameworks/` (ABI-compatible; no spice-gtk rebuild). This fixes the reachable
  **CVE-2022-0778** handshake DoS and every other 1.1.1 CVE through Sept 2023.

## Residual risks (not fixed in code)

1. **EOL native stack.** The bundled UTM sysroot still ships spice-gtk 0.42, glib,
   gstreamer 1.19.1, usbredir — and the OpenSSL **1.1.1** branch (now 1.1.1w via
   `scripts/upgrade-openssl.sh`). The known reachable **CVE-2022-0778** handshake
   DoS is **fixed** by the 1.1.1w upgrade, but 1.1.1 is itself EOL (no *future*
   fixes), and the rest of the stack is old and is the parser for all
   hostile-server data — where any future server-reachable memory-safety bug would
   land. **Action (for wider distribution):** rebuild the sysroot against a
   supported **OpenSSL 3.x** (requires rebuilding spice-gtk) with current
   glib/gstreamer/usbredir, pin the versions + SHA256.

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

## Verifying a downloaded build

Prebuilt release `.app`s are **ad-hoc signed**, **not Developer-ID-signed or
notarized** (residual risk 3). Ad-hoc signing gives the bundle a valid local code
signature but no identity Apple can attribute to a developer, so Gatekeeper warns on
first launch and the binary's provenance rests on this repo, not on Apple's
notarization. Notarization is gated on a paid Apple Developer membership (US$99/yr)
the project can't currently fund; sponsoring (the repo **Sponsor** button) would
change that.

To establish trust independently:

- **Rebuild from source** and run that instead of the download — the whole build is
  reproducible from this repo (README *Build*).
- **Compare the SHA-256.** Each release publishes `shasum -a 256` of the zipped
  `.app`; check your download matches **before** clearing quarantine.

Never clear quarantine on a build whose hash you haven't verified against the
release.

## Reporting

This is a personal/open-source project. For a suspected vulnerability, please
**report privately before public disclosure** via GitHub's
[private vulnerability reporting](https://github.com/Ching367436/spice-mac/security/advisories/new)
(Security ▸ Report a vulnerability), or contact the maintainer **Ching367436**
through [GitHub](https://github.com/Ching367436). For non-sensitive bugs, open a
regular issue. There is no formal SLA, but reports are reviewed as soon as
practical. Please don't include a live `.vv` ticket/CA in any report.
