# Cosmopod OS

Cosmopod OS is a 64-bit Linux distribution project for Raspberry Pi 4,
Raspberry Pi 5, and x86-64 virtual machines. It is designed to start a Wayland
desktop, expose hardened OpenSSH, ship practical administration/development
tools, and receive signed A/B updates on Raspberry Pi without a Mender server.

Pi generations and x86 VMs use separate boot targets; one kernel/boot image is
not treated as universal hardware media.

Development builds advance through `0.x.0` iterations. `1.0.0` is reserved
for the first release that passes the complete Pi, VM, Wayland, SSH, OTA,
standalone recovery, security, and publishing qualification described in
[`docs/VERSIONING.md`](docs/VERSIONING.md).

## What it produces

- `Cosmopod-OS-<version>-pi4.img.xz` or `...-pi5.img.xz`: factory image for an
  SD card or USB storage device.
- `Cosmopod-OS-<version>-<board>-unsigned.mender`: unsigned full-OS update
  emitted by the build. The offline signing helper creates the publishable
  `...-<board>.mender` artifact for devices already running Cosmopod OS.
- `Cosmopod-OS-<version>-vm-x86_64.iso`: hybrid BIOS/UEFI live VM boot media.
- `Cosmopod-OS-<version>-vm-x86_64.iso.xz`: compressed ISO for GitHub Release
  distribution; decompress it before attaching it to a VM.
- `Cosmopod-OS-<version>-vm-x86_64.qcow2`: persistent EFI VM disk.
- `SHA256SUMS`: exact release integrity hashes; signed Pi releases also contain
  `SHA256SUMS.sig`, authenticated by the device artifact key.
- required SPDX SBOM, license-manifest, CVE report, and CVE-gate evidence.

A Raspberry Pi does not boot a normal ISO9660 `.iso`. Its firmware needs a
partitioned disk image containing a FAT boot partition. The `.img.xz` file is
the Pi equivalent of an install ISO and can be flashed by Raspberry Pi Imager,
balenaEtcher, or `dd`. The ISO is for x86-64 VMs only.

## Included

- Yocto Project 6.0 Wrynose LTS, pinned by immutable commits
- Patched KAS 5.4 bootstrap with digest-pinned container and hash-locked native wheels
- Linux, systemd, U-Boot, NetworkManager, nftables, chrony
- Wayland with Weston and VC4 KMS graphics
- OpenSSH: public-key authentication only, no root/password login
- Bash, Git, curl, wget, rsync, jq, vim, nano, tmux, htop
- Python 3, GCC/G++, make, CMake, pkg-config
- Wi-Fi, Bluetooth, Avahi/mDNS, I2C, SPI, GPIO tools
- tcpdump, nmap, strace, lsof, iproute2, ethtool, storage tools
- Mender A/B rootfs updates with automatic rollback and signed-artifact checks
- Persistent `/data` state for SSH host keys, user home, network connections,
  Mender transaction state and update journal
- Update health gate checking data, NetworkManager, SSH, Weston, and Wayland
  before a new OS is committed

## Quick start on this Windows machine

Requirements: WSL2 Ubuntu, at least 150 GB free for a first build, internet,
and an 8 GB or larger SD card. Docker is optional.

```powershell
# Build Pi 4 image. Use pi5 for Raspberry Pi 5.
.\scripts\build.ps1 -Board pi4 -Version 0.1.0

# Build x86-64 ISO and QCOW2 media.
.\scripts\build.ps1 -Board vm -Version 0.1.0
```

Build stays in native WSL storage under `~/.cache/cosmopod-os`; only release
artifacts return to `out/`. This avoids slow and unreliable Yocto work on a
OneDrive/NTFS mount. When Docker is unavailable, the script installs Yocto's
pinned, unprivileged buildtools automatically.

Before first boot:

1. Flash the matching `.img.xz`.
2. Open the FAT boot partition.
3. Rename `cosmopod.conf.example` to `cosmopod.conf`.
4. Add your SSH public key and, optionally, Wi-Fi settings.
5. Boot the Pi and connect with `ssh cosmopod@cosmopod.local`.

Account `cosmopod` has no password. If no SSH key is provisioned, remote login
correctly remains unavailable; local Wayland desktop still starts.

## Standalone updates

Pi images use Mender's standalone installer. Signed board-specific updates are
published through GitHub Releases; no Mender account, managed server, or new
server hardware is required. The command checks the signed release index and
artifact hash before Mender verifies and installs the artifact. Commit is
explicit, after reboot and health checks. VM media is replaced separately.

```bash
# Values must come from an authenticated build record, independently of the
# bundle copied to the offline signer.
BUILD_INDEX_SHA256=<approved-sha256-of-SHA256SUMS>
UNSIGNED_SHA256=<approved-sha256-of-unsigned-mender>
scripts/sign-release.sh --standalone \
  --approve-build-index-sha256 "$BUILD_INDEX_SHA256" \
  --approve-unsigned-sha256 "$UNSIGNED_SHA256" \
  out/0.43.0/pi4-release/Cosmopod-OS-0.43.0-pi4-unsigned.mender

# On a Pi running a standalone factory image, once a qualified release exists:
cosmopod-update check
sudo cosmopod-update install
sudo reboot
# Reconnect, inspect the system, then accept it:
sudo cosmopod-update commit
```

Read [update system](docs/UPDATE-SYSTEM.md) before deploying an update.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Build](docs/BUILD.md)
- [Flash and first boot](docs/FIRST-BOOT.md)
- [Virtual machines](docs/VM.md)
- [Update system](docs/UPDATE-SYSTEM.md)
- [Security](docs/SECURITY.md)
- [Vulnerability reporting](SECURITY.md)
- [Historical optional backend tooling](backend/README.md)

## Current status

Version 0.72.0 completed clean native Yocto builds for the x86-64 VM,
Raspberry Pi 4, and Raspberry Pi 5. Each artifact's `BUILD-MANIFEST.txt`
records its exact source commit and tree. The VM ISO and QCOW2 passed isolated
QEMU smoke tests covering Wayland/Weston, SSH, systemd health, mounts, and
QCOW2 persistence across two boots. Both Pi builds exported factory images and
unsigned Mender artifacts whose checksums, archives, device types, and Mender
v3 structure validated successfully. No physical Pi boot is claimed.

All 0.72.0 media remains development-only. Its 2026-10-20 CVE gate denied 76 VM
findings and 125 findings for each Pi target. Version 0.73.0 introduced standalone
update tooling but its first build found a Python package-name mismatch, corrected
in 0.74.0. Build and qualification status must be verified independently.
Production signing, standalone update/rollback, and physical Pi 4/Pi 5
qualification remain required. Version 0.74.0 subsequently completed all three
development builds, VM boot/persistence tests, and Pi filesystem checks for the
standalone updater and masked managed services. Its 2026-10-25 CVE gates failed
with 149 denied findings per Pi and 89 for VM. Version 0.75.0 pins the Pi kernel
to upstream Linux 6.18.59; all development image validations and VM smoke tests
passed, but its 2026-10-26 CVE gates denied 132 findings per Pi and 89 for VM.
Version 0.76.0 updates OpenSSH to 10.6p1; its image results remain unqualified.
No public signed release is claimed. Do not
promote any build to 1.0.0 until every gate in
[versioning](docs/VERSIONING.md) passes. See [Build](docs/BUILD.md) for the
detailed record.

## License

Cosmopod OS layer, scripts, and documentation are MIT licensed. Built images
contain upstream projects under their own licenses; Yocto emits license
manifests and an SPDX SBOM.
