# Cosmopod OS

Cosmopod OS is a 64-bit Linux distribution project for Raspberry Pi 4,
Raspberry Pi 5, and x86-64 virtual machines. It is designed to start a Wayland
desktop, expose hardened OpenSSH, ship practical administration/development
tools, and receive robust A/B updates on Raspberry Pi from a Mender backend.

Pi generations and x86 VMs use separate boot targets; one kernel/boot image is
not treated as universal hardware media.

Development builds advance through `0.x.0` iterations. `1.0.0` is reserved
for the first release that passes the complete Pi, VM, Wayland, SSH, OTA,
backend, security, and publishing qualification described in
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

- Yocto Project 5.0 Scarthgap LTS, pinned by immutable commits
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
  Mender identity, and backend configuration
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
4. Add your SSH public key and, optionally, Wi-Fi/Mender settings.
5. Boot the Pi and connect with `ssh cosmopod@cosmopod.local`.

Account `cosmopod` has no password. If no SSH key is provisioned, remote login
correctly remains unavailable; local Wayland desktop still starts.

## Backend updates

`backend/` bootstraps the official Open Source Mender Server for local
evaluation and includes a production Helm values template. Devices poll the
backend outbound over HTTPS. Creating a deployment in Mender sends a signed OS
release to selected Pi devices or groups. The configured endpoint is
`https://kys.dpdns.org`; production DNS/TLS/server setup is still required.

```bash
# Values must come from an authenticated build record, independently of the
# bundle copied to the offline signer.
BUILD_INDEX_SHA256=<approved-sha256-of-SHA256SUMS>
UNSIGNED_SHA256=<approved-sha256-of-unsigned-mender>
scripts/sign-release.sh --approve-server-url https://updates.example.org \
  --approve-build-index-sha256 "$BUILD_INDEX_SHA256" \
  --approve-unsigned-sha256 "$UNSIGNED_SHA256" \
  out/0.1.0/pi4/Cosmopod-OS-0.1.0-pi4-unsigned.mender

# Local evaluation backend; not production configuration.
backend/scripts/bootstrap-evaluation.sh
backend/scripts/start.sh
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
- [Backend](backend/README.md)

## Current status

Version 0.1.0 completed full Yocto builds for Raspberry Pi 4 and x86-64 VM
media. The exported Pi `.img.xz`, signed/unsigned Mender artifacts, VM `.iso`,
and `.qcow2` passed offline checksum, format, partition, boot-file, and artifact
validation at build time. They predate the current clean-source provenance
manifest, later boot fixes, and VM reporter, so they remain historical
pre-release evidence and must be rebuilt from a new clean commit. QEMU smoke
tests reached a Cosmopod serial login from both VM
formats; the persistent QCOW2 mounted its root, data, and swap partitions. Live
ISO testing found and fixed data, NFSD, and read-only-remount failures. The last
booted ISO iteration still failed to start Weston under the test's virtual GPU;
the latest built ISO includes console diagnostics. Source now contains a safe,
non-interactive QEMU smoke reporter for mounts, SSH, DRM, Weston, and Wayland;
VM media needs rebuilding and must pass it before desktop qualification.
Raspberry Pi 5 source support is present, but a full Pi 5 build has not
completed. Real Pi hardware tests and production backend deployment at
`https://kys.dpdns.org` remain outstanding. See [Build](docs/BUILD.md).

## License

Cosmopod OS layer, scripts, and documentation are MIT licensed. Built images
contain upstream projects under their own licenses; Yocto emits license
manifests and an SPDX SBOM.
