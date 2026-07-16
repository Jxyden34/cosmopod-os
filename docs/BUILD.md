# Build Cosmopod OS

## Host requirements

Recommended first-build budget:

- x86-64 Linux host or WSL2
- 16 CPU threads or more
- 32 GB RAM
- 150-250 GB free disk
- no ongoing administrator/root access after host packages and locale exist
- reliable internet connection

The supplied Windows wrapper targets WSL distro `Ubuntu`. Yocto files, source
downloads and shared-state cache stay in WSL's native ext4 filesystem. Do not
place the active build tree in OneDrive, NTFS, SMB, or another case-insensitive
filesystem.

## WSL build engine

The default `auto` engine uses Docker when the current WSL user already has
access. Otherwise it installs pinned KAS modules in a private Python path and
the official Yocto 5.0.15 extended buildtools under `~/.cache/cosmopod-os`. That
fallback needs no `sudo`, Docker socket access, or persistent privilege change.
The distro administrator may still need to install Yocto's documented host
packages and generate the required locale once.

Ubuntu 26.04 supplies some core utilities through uutils, while Yocto 5.0
expects GNU `install`. When this is detected, the wrapper checksum-verifies and
extracts Ubuntu's GNU coreutils package under the private build cache. It does
not replace the distro's essential packages. The same host release ships a
patched `tar` whose `openat2` extraction path is incompatible with Yocto 5.0's
`pseudo`; the wrapper pre-seeds the compatible `tar` already supplied by the
pinned Yocto extended buildtools.

The wrapper caps BitBake and per-recipe parallelism at six jobs to avoid WSL
memory-pressure failures. Larger builders may deliberately override this with
`COSMOPOD_BB_NUMBER_THREADS` and `COSMOPOD_PARALLEL_MAKE_JOBS`; both accept
integers from 1 through 99.

```powershell
.\scripts\build.ps1 -Board pi4 -Version 0.1.0 -Engine auto
```

Select `-Engine native` to force the unprivileged buildtools route or
`-Engine container` to require the pinned kas container. No QEMU user
emulation is needed for normal Yocto cross-compilation.

BitBake also requires `en_US.UTF-8`. If the builder reports it missing, create
that one locale in the WSL distro (no package install is needed):

```powershell
wsl.exe -d Ubuntu -u root -- localedef -i en_US -f UTF-8 en_US.UTF-8
```

## Validate source

```powershell
python scripts\validate.py
python -m unittest discover -s tests -v
```

## Fetch layers without compiling

```powershell
.\scripts\build.ps1 -Board pi4 -Version 0.1.0 -Engine native -CheckoutOnly
```

This verifies container access, network access, all pinned revisions, KAS
merging, and BitBake checkout setup.

## Full build

```powershell
.\scripts\build.ps1 -Board pi4 -Version 0.1.0
.\scripts\build.ps1 -Board pi5 -Version 0.1.0
.\scripts\build.ps1 -Board vm -Version 0.1.0
```

Linux/WSL direct equivalent:

```bash
scripts/build.sh --build --board pi4 --version 0.1.0
```

Outputs appear under `out/<version>/<board>/`:

```text
Cosmopod-OS-0.1.0-pi4.img.xz
Cosmopod-OS-0.1.0-pi4-unsigned.mender
Cosmopod-OS-0.1.0-pi4-spdx.tar.xz       when emitted
Cosmopod-OS-0.1.0-pi4-licenses.tar.xz   when emitted
SHA256SUMS
```

The VM target emits `Cosmopod-OS-0.1.0-vm-x86_64.iso` for BIOS/UEFI live
boot and `Cosmopod-OS-0.1.0-vm-x86_64.qcow2` for a persistent EFI VM. Mender
A/B OTA is intentionally excluded from VM media; it applies to Pi targets.

The compressed image can be flashed directly by Raspberry Pi Imager. Git
ignores all build artifacts. Publish the image, checksum, license/SPDX archives, and signed `.mender`
file as release assets only after hardware acceptance.

## Sign an update

Factory images contain the public verification key. The development private
key defaults to `~/.config/cosmopod-os/keys`, outside Git and OneDrive.
Initialize a local key pair once with:

```bash
scripts/generate-signing-key.sh --replace-device-key
```

The flag means "replace the public key compiled into future device images."
The script deliberately refuses to overwrite an existing local pair. Key
rotation is a separate production migration requiring overlapping trusted
verification keys; do not delete the old pair and rerun this initializer.

```bash
scripts/sign-release.sh \
  out/0.1.0/pi4/Cosmopod-OS-0.1.0-pi4-unsigned.mender
```

For production, move signing to an offline machine or supported KMS/HSM. Never
copy the private key into CI, Mender Server, a Pi, or a GitHub secret unless a
formal risk decision explicitly allows online signing.

## Dependency updates

All layer revisions in `kas/common.yml` are full commit SHAs. Update them as a
tested set, never by changing a single layer to a floating branch. Pi 5 also
depends on its pinned `meta-lts-mixins` revision.

`kas/common.yml` explicitly accepts the `synaptics-killswitch` license flag
needed for the Raspberry Pi Broadcom/Synaptics Wi-Fi firmware. This is a named,
reviewable acceptance, not a wildcard acceptance of restricted licenses.

Scarthgap is used as the first hardware baseline because its Mender Raspberry
Pi integration is established. Qualify a full Yocto LTS migration separately;
do not mix Wrynose layers into a Scarthgap build.

## Version 0.1.0 validation record

Full native Yocto builds completed for Raspberry Pi 4 and generic x86-64. The
Pi factory image, signed and unsigned Mender artifacts, VM hybrid ISO, and VM
QCOW2 disk passed `scripts/validate-artifacts.sh` checks for hashes, container
formats, expected partition tables/filesystems/labels, Mender metadata and
device compatibility, and BIOS/UEFI ISO boot files. The generated OS identity
is `cosmopod` version `0.1.0`.

QEMU TCG smoke tests using a Core 2-capable CPU model reached a serial login
from the BIOS live ISO and the UEFI QCOW2 disk. The QCOW2 root and data
partitions mounted read-write and swap activated. ISO testing proved its tmpfs
`/data` fallback, persistent-state setup, NetworkManager, first-boot
provisioning, and key-only SSH daemon startup. It also found and drove fixes for
an absent live mount point, unconditional NFSD mount, and expected read-only
root remount. Weston still failed under the last tested virtio GPU run; the
latest built media sends its fatal log to the boot console. Source now includes
an opt-in, fixed-function guest reporter plus `scripts/smoke-vm.ps1`; rebuild
the VM media and pass both ISO and QCOW2 checks before VM qualification.

No real Raspberry Pi boot has been claimed. A full Raspberry Pi 5 build also
remains outstanding. Treat these artifacts as pre-release media until the
acceptance work below passes.

## Hardware acceptance gate

For each board and storage type:

1. Flash and boot five times.
2. Verify DRM/KMS, Weston, keyboard/mouse, Ethernet, Wi-Fi, Bluetooth, SSH.
3. Verify stable SSH host fingerprint after reboot and after A/B update.
4. Accept device in backend and deploy a signed update.
5. Confirm unsigned and wrong-key updates are rejected.
6. Force health failure and prove rollback.
7. Pull power during download, inactive-slot write, first trial boot, and
   pre-commit health wait. Prove old or new slot still boots safely.
8. Verify persistent user/network/Mender state.
9. Test SD card and supported USB boot media separately.

Do not label a build production-ready until this matrix passes on Pi 4 and Pi 5
independently.
