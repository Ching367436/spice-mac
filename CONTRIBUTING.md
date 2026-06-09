# Contributing to SpiceMac

Thanks for your interest! SpiceMac is a native macOS SPICE client for Proxmox VE.

## Ground rules

- Be respectful — see [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
- By contributing, you agree your changes are licensed under the project's
  [MIT License](LICENSE).
- Keep the dependency-free test runners green (CI runs them).

## Project layout

| Path | What |
|------|------|
| `Sources/SpiceMac` | AppKit/Metal app |
| `Packages/SpiceController` | connection lifecycle, input, clipboard glue |
| `Packages/VVConfig`, `Packages/SpiceInputMap` | pure-Swift, unit-tested |
| `ThirdParty/CocoaSpice` | vendored Apache-2.0 fork (Proxmox patch + security fixes) |

## Building & testing

`make help` lists every task. The pure-Swift libraries build and test with just the
toolchain (no Xcode/sysroot):

```sh
make test     # the two dependency-free runners: vvcheck (.vv parser) + inputcheck (keymap)
```

The full app needs **Xcode** + the **Metal toolchain component**
(`xcodebuild -downloadComponent MetalToolchain`) + the native SPICE frameworks:

```sh
make doctor   # checks the above and prints fixes if anything's missing
make all      # fetch the sysroot, then build → build/SpiceMac.app
```

See [README.md](README.md) for prerequisites and details.

### Environment variables

The scripts read these `SPICEMAC_*` knobs (none are needed for the default path):

| Variable | Script | Default | When to set |
|----------|--------|---------|-------------|
| `SPICEMAC_SYSROOT_URL` | fetch-sysroot | (pinned default) | Use your own sysroot tarball |
| `SPICEMAC_SYSROOT_SHA256` | fetch-sysroot | (pinned default) | Required digest for a custom URL |
| `SPICEMAC_SYSROOT_FROM_GH` | fetch-sysroot | `0` | `1` = pull a fresh UTM CI artifact (needs `gh`) |
| `SPICEMAC_SYSROOT_ARTIFACT` | fetch-sysroot | `Sysroot-macos-arm64` | UTM artifact name (GH path) |
| `SPICEMAC_SYSROOT_ARTIFACT_ID` | fetch-sysroot | (latest) | Pin a specific UTM artifact id |
| `SPICEMAC_UTM_REPO` | fetch-sysroot | `utmapp/UTM` | Alternate UTM repo (GH path) |
| `SPICEMAC_SYSROOT_SHA256_INSECURE` | fetch-sysroot | unset | `1` = skip the digest check (unsafe; testing only) |
| `SPICEMAC_ASSUME_YES` | run-as-root, release | unset | `1` = skip confirmation prompts |
| `SPICEMAC_LOG` | debug-run | unset | Spice log domains (e.g. `all`) |
| `ALLOW_NO_METAL` | build-app | unset | `1` = build a non-rendering app without the Metal toolchain |

## Cutting a release (maintainers)

One command does the whole ceremony — bump both `Info.plist` version fields, roll
`CHANGELOG.md` (`Unreleased` → the new version + compare-links), build the signed
`.app` + `.zip` + `.sha256`, and (after a y/N confirm) commit, tag, push, and create
the GitHub release:

```sh
# Put the changes under '## [Unreleased]' in CHANGELOG.md first, then:
make release VERSION=0.1.7
```

It refuses to run on a dirty tree, off `main`, with an existing tag, a non-increasing
version, or an empty `## [Unreleased]`. It stops and shows the diff **before** the
irreversible publish. To back out after preparing but before publishing:
`git checkout Resources/Info.plist CHANGELOG.md`. `make check-version` (also a CI
gate) asserts `Info.plist` / `CHANGELOG` / the tag stay in agreement.

## Touching the vendored fork

`ThirdParty/CocoaSpice` is a fork. If you change it, **record the change in
`ThirdParty/CocoaSpice/FORK-NOTES.md`** so it survives a rebase onto upstream. Keep
fork changes minimal and well-justified (the Proxmox patch + the security fixes are
the existing ones).

## Pull requests

- Keep PRs focused; explain the "why".
- Run the two check runners (`vvcheck` / `inputcheck`) and, for native changes,
  `clang -fsyntax-only` over the patched ObjC if relevant.
- Note any security implications — see [SECURITY.md](SECURITY.md).
