# arcbox-qemu

A minimal, relocatable `qemu-system-aarch64` for Apple Silicon macOS. ArcBox
downloads it on demand to run its system VM under QEMU TCG on Macs without
hardware virtualization (cloud Macs and CI runners that are themselves VMs).

- QEMU 10.2.4, `aarch64-softmmu` only, TCG only
- vhost-user on (`vhost-user-fs-pci`, `vhost-user-vsock-pci`), vhost-net off
- glib 2.88.4 as a bundled dylib (LGPL-2.1); nothing from Homebrew
- macOS 15.0 or later, arm64
- Releases are signed with the ArcBox Developer ID (hardened runtime) and notarized

Pinned versions and hashes live in [`versions.env`](versions.env).

## Package layout

Release asset `qemu-darwin-arm64-vX.Y.Z.tar.gz`, with a `.sha256` file next to
it in `shasum -a 256` format. The tarball has no top-level directory; extract
it into an empty directory (ArcBox uses `~/.arcbox/runtime/qemu/<version>/`):

```
bin/qemu-system-aarch64        the emulator; LC_RPATH @executable_path/../lib
lib/libglib-2.0.0.dylib        install name @rpath/libglib-2.0.0.dylib
licenses/<component>/...       QEMU, glib, pcre2, proxy-libintl, dtc, berkeley-softfloat-3
BUILD-INFO.json                package version, QEMU/glib versions, configure options, commit
```

The tree can be moved anywhere. Every Mach-O links only macOS system
libraries (`/usr/lib`, `/System/Library`) and `@rpath/` dylibs from `lib/`.
There is no `share/qemu`: direct `-kernel` boot on the `virt` machine needs
no firmware, ROM or keymap.

### Running it

- No environment variables and no `-L` are needed.
- Add `romfile=` to every `virtio-net-pci` device. Otherwise QEMU looks for
  the `efi-virtio.rom` option ROM (only used by UEFI network boot) and fails
  with `failed to find romfile "efi-virtio.rom"`.
- Use `-accel tcg`; HVF is not compiled in.

[`scripts/boot-test.py`](scripts/boot-test.py) shows the full device set
ArcBox uses: `-kernel`, guest RAM in `memory-backend-shm,share=on`,
`virtio-blk-pci`, `-netdev dgram,local.type=fd` on a `SOCK_DGRAM`
socketpair, `virtio-serial-pci` + `virtconsole`, `virtio-rng-pci` and QMP.

### Verifying a download

Check the sha256 first. Release binaries can also be pinned to the signer:

```sh
codesign --verify --strict \
  -R='anchor apple generic and certificate leaf[subject.OU] = "422ACSY6Y5" and identifier "com.arcboxlabs.qemu.system-aarch64"' \
  bin/qemu-system-aarch64
```

Notarization covers every Mach-O, but bare Mach-O files cannot be stapled, so
Gatekeeper looks the ticket up online when it assesses a quarantined copy.
Files the daemon downloads itself carry no quarantine attribute and are not
assessed. An offline import should verify the sha256 and then remove
`com.apple.quarantine` from the extracted tree.

## Development build (unsigned)

Requirements: Apple Silicon Mac, Xcode or the Command Line Tools,
`python3`, `pkg-config` (`brew install pkgconf`) and network access.
meson and ninja are installed into a private venv by the script.

```sh
./scripts/build.sh                     # -> out/stage/
./scripts/package.sh 0.0.0-dev         # -> out/qemu-darwin-arm64-v0.0.0-dev.tar.gz
./scripts/smoke-test.sh out/qemu-darwin-arm64-v0.0.0-dev.tar.gz kernel-arm64
```

`out/stage/bin/qemu-system-aarch64` runs as is. The development build is
ad-hoc signed without the hardened runtime (library validation would reject
ad-hoc dylibs), so it behaves like any locally built binary. A clean build,
downloads included, takes about 2 minutes on a 6-core M4 Pro; reruns reuse
`build/`.

`kernel-arm64` for the boot test comes from
[arcboxlabs/kernel](https://github.com/arcboxlabs/kernel/releases):

```sh
curl -fLO https://github.com/arcboxlabs/kernel/releases/download/v0.0.25/kernel-arm64
```

Every push to `master` and every pull request also uploads an unsigned package
as the `qemu-darwin-arm64` workflow artifact.

## Release build

```sh
VERSION=0.1.0 ./scripts/build.sh
./scripts/sign.sh "Developer ID Application: ArcBox, Inc. (422ACSY6Y5)"
./scripts/notarize.sh arcbox-notarize  # keychain profile from `xcrun notarytool store-credentials`
./scripts/package.sh 0.1.0
EXPECT_TEAM_ID=422ACSY6Y5 ./scripts/smoke-test.sh out/qemu-darwin-arm64-v0.1.0.tar.gz kernel-arm64
```

`sign.sh` signs every Mach-O with the hardened runtime and a secure
timestamp. The dylibs carry the same team ID as the executable, so library
validation passes without `disable-library-validation`. Only the executable
has entitlements: `com.apple.security.cs.allow-jit`
([`entitlements.plist`](entitlements.plist)), because TCG maps its
translation buffer with `MAP_JIT`.

`package.sh` also writes `qemu-darwin-arm64-vX.Y.Z-sources.tar`: the QEMU and
glib release tarballs, the meson wrap sources glib pulled in (pcre2,
proxy-libintl, libffi), QEMU's `dtc` subproject, and this repository.

## CI

[`.github/workflows/release.yml`](.github/workflows/release.yml) runs on a
`macos-26` (Apple Silicon) runner:

| Trigger | Signed | Published |
| --- | --- | --- |
| pull request, push to `master` | no (ad-hoc) | workflow artifact |
| `workflow_dispatch` with `sign` | Developer ID + notarized | workflow artifact |
| tag `vX.Y.Z` | Developer ID + notarized | GitHub Release, `boot.arcboxcdn.com/qemu/vX.Y.Z/` |

Each run builds, signs and notarizes when applicable, packages, and runs
`smoke-test.sh` against the packaged tarball, including the boot test.

Repository secrets and variables, with the same names arcbox-desktop and
boot-assets use:

| Name | Kind | Used for |
| --- | --- | --- |
| `APPLE_CERTIFICATE_P12` | secret | Developer ID Application certificate + key, base64 `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | secret | password of that `.p12` |
| `NOTARY_KEY` | secret | App Store Connect API key (`.p8` contents) |
| `NOTARY_KEY_ID` | secret | its key ID |
| `NOTARY_ISSUER` | secret | its issuer ID |
| `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | secret | R2 token with Object Read & Write on `arcboxcdn-boot` |
| `R2_ACCOUNT_ID` | variable | Cloudflare account ID |

## Versioning

Tags are `vX.Y.Z` for this repository, independent of the QEMU version (as in
arcboxlabs/kernel and arcboxlabs/boot-assets). `BUILD-INFO.json` and the
release notes record the QEMU version.

ArcBox pins a release in `assets.lock`, for example:

```toml
[qemu]
version = "0.1.0"
cdn = "https://boot.arcboxcdn.com/qemu"
# sha256 of qemu-darwin-arm64-v0.1.0.tar.gz
arch.arm64.sha256 = "..."
```

and downloads `{cdn}/v{version}/qemu-darwin-arm64-v{version}.tar.gz`
(mirror: `https://github.com/arcboxlabs/qemu/releases/download/v{version}/qemu-darwin-arm64-v{version}.tar.gz`).

## Configure options

```
--target-list=aarch64-softmmu
--without-default-features   every optional feature off unless enabled below,
                             so Homebrew packages on the build host cannot leak in
--enable-tcg
--enable-vhost-user          vhost-user-fs-pci, vhost-user-vsock-pci
--disable-vhost-net          Linux-only; with vhost-user on, hw/net/vhost_net.c
                             fails to build (needs linux/vhost_types.h)
--enable-fdt=internal        libfdt from QEMU's dtc subproject, linked statically
--disable-docs
--disable-install-blobs
```

With `--without-default-features`, the UI (Cocoa, SDL, GTK, VNC, curses),
audio, USB, gnutls, libssh, PNG, capstone, slirp, vmnet, HVF, zstd, the tools
and the guest agent are all off. `memory-backend-shm`, `-netdev dgram`,
vhost-user chardevs and QMP are part of every POSIX system-emulator build.
The device set is QEMU's default for `aarch64-softmmu`.

## License

QEMU is GPL-2.0 (some parts under other compatible licenses, see
`licenses/qemu/LICENSE`); glib is LGPL-2.1-or-later and proxy-libintl
LGPL-2.0-or-later; pcre2, dtc's libfdt and berkeley-softfloat-3 are
BSD-licensed. The package carries
each license under `licenses/`, and every release carries the corresponding
source.
