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
the official Yocto 5.0.18 extended buildtools under `~/.cache/cosmopod-os`. That
release carries the openat2-aware `pseudo`; Cosmopod also applies its
const-correct prototype compatibility patch for Ubuntu 26.04/glibc 2.43 hosts.
The layer also preserves the const-qualified `bsearch` result in elfutils 0.191
for the same host toolchain.
That fallback needs no `sudo`, Docker socket access, or persistent privilege change.
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

### Build-bootstrap integrity

KAS is pinned to 5.4. Version 4.8.1 is not an acceptable release bootstrap:
it is affected by
[CVE-2026-47191](https://github.com/siemens/kas/security/advisories/GHSA-qjwp-hrq6-r26r)
and
[CVE-2026-47192](https://github.com/siemens/kas/security/advisories/GHSA-4vqc-wpwg-vh7j);
both upstream advisories identify 5.3 as the first patched release.

The container route uses the official multi-platform KAS 5.4 image at OCI
index digest
`sha256:11f076b79b84f57cb7d933941ff619f09a7c17e562e1643d13836d5f8d0a92f3`.
Its tagged `kas-container` wrapper is accepted only at SHA-256
`9707355d1eba19e334e663ab9fcf6881ac323aed16ff7f4fd7e217f879a3894c`;
an unverified or modified cached copy is never executed.

The native route installs the official KAS 5.4 wheel and its complete runtime
closure from `scripts/requirements-kas-5.4-linux-x86_64.txt`. Pip requires the
recorded SHA-256 hashes, accepts wheels only, resolves no undeclared
dependencies, and uses the official PyPI index. The lock covers glibc x86-64
CPython 3.9 through 3.14. Wheels may remain cached, but every invocation
reinstalls into a new directory with `--require-hashes`, verifies the complete
distribution/import closure, and atomically replaces the executable runtime.
No checksum stored beside writable installed code is treated as a trust root.

Treat the image digest, wrapper hash, wheel lock, and KAS version as one
qualified set. Updating any member requires fresh source validation, layer
checkout, complete board builds, VM smoke tests, and Pi hardware acceptance.

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

Default `-Channel auto` exports clean source as release output and dirty source
as development output. To test clean committed source while a release gate is
still expected to fail, select development explicitly:

```powershell
.\scripts\build.ps1 -Board pi4 -Channel development -Version 0.40.0
```

`-Channel release` refuses dirty source. Channel choice is recorded in build
manifest; development media cannot be promoted by renaming its directory.

Linux/WSL direct equivalent:

```bash
scripts/build.sh --build --board pi4 --version 0.1.0
```

Release outputs appear under `out/<version>/<board>-release/`. Dirty-tree
development outputs appear under `out/<version>/<board>-development/`:

```text
Cosmopod-OS-0.1.0-pi4.img.xz
Cosmopod-OS-0.1.0-pi4-unsigned.mender
Cosmopod-OS-0.1.0-pi4-spdx.tar.zst
Cosmopod-OS-0.1.0-pi4-licenses.tar.xz
Cosmopod-OS-0.1.0-pi4-cve.json
Cosmopod-OS-0.1.0-pi4-cve-gate.txt
BUILD-KAS-OVERLAY.yml
BUILD-MANIFEST.txt
SHA256SUMS
```

The VM target emits `Cosmopod-OS-0.1.0-vm-x86_64.iso` for BIOS/UEFI live
boot, a matching `.iso.xz` download archive, and
`Cosmopod-OS-0.1.0-vm-x86_64.qcow2` for a persistent EFI VM. The build checks
that decompressing the archive reproduces the ISO and that the archive remains
under GitHub's 2 GiB per-release-asset limit. Keep the raw ISO for local smoke
tests; publish the compressed form. Mender A/B OTA is intentionally excluded
from VM media; it applies to Pi targets.

The compressed image can be flashed directly by Raspberry Pi Imager. Git
ignores all build artifacts. Publish the image, checksum, license/SPDX archives, and signed `.mender`
file as release assets only after hardware acceptance.

Publishable builds require a clean Git tree and refuse to replace an existing
output directory. A deliberate local pre-release rebuild can
use PowerShell `-ReplaceOutput`; `-AllowDirty` exists only for development and
is recorded as `source_dirty=true`, `output_channel=development`, and
`release_qualified=false`. Development media may export with a failed CVE gate
so boot and hardware work can continue, but its exact `decision` and denied
count remain recorded. Clean release export still fails closed unless the CVE
gate passes. Every export includes
`BUILD-MANIFEST.txt` with the source commit/tree, board/device type, KAS/Yocto
versions, build times, trust-key hash, and configuration hashes.
`SHA256SUMS` covers that manifest and every exported file.
`BUILD-KAS-OVERLAY.yml` is exact generated KAS configuration consumed by build;
manifest records its digest plus thread settings.
Build wrapper clears KAS/BitBake target, task, machine, distro, path, and
parallelism environment overrides before invoking KAS; recorded configuration
therefore cannot be silently replaced by inherited shell state.

SBOM, license, and vulnerability evidence is mandatory. Export must fail if
Yocto did not produce a structurally valid image SPDX bundle, image license
archive containing the required manifests, or image CVE JSON report. The NVD
database must have been updated no more than 48 hours before the gate; its
SHA-256, timestamp, age, and policy limit are recorded. `scripts/check-cve-report.py`
blocks every unpatched/unknown CVE with
CVSS 7.0 or higher, plus any unscored unresolved CVE. A waiver must match exact
package/CVE, name an approver, link an HTTPS tracking record, explain the risk,
and remain unexpired in `security/cve-waivers.json`. Lower-scored unresolved
issues still require human review before release promotion.

Yocto's [`create-spdx`](https://docs.yoctoproject.org/5.0/ref-manual/classes.html#create-spdx)
and [`cve-check`](https://docs.yoctoproject.org/5.0/ref-manual/classes.html#cve-check)
classes produce these source reports. CVE matching can contain false positives
or incomplete metadata; gate result supplements, not replaces, security review.

The builder's `BUILD-MANIFEST.txt` and initial `SHA256SUMS` are integrity
metadata, not builder attestation. The offline signer therefore requires their
index digest and unsigned-artifact digest through an independent authenticated
approval channel. It signs a private verified snapshot, then signs the final Pi
release index as `SHA256SUMS.sig`; that signature binds the Mender artifact,
SBOM, CVE evidence, license archive, build manifest, and signing record.
Factory images and all VM media still need an authenticated release ledger or
separate signed provenance before public promotion. Neither mechanism proves a
reproducible build or builder identity by itself.

The Pi backend origin is also a recorded build input. Until the hostname is
dedicated and approved, leave production media unqualified. Override it without
editing source using `-MenderServerUrl https://kys.dpdns.org`; only a
plain HTTPS origin is accepted.

## Sign an update

Factory images contain the public verification key. The development private
key defaults to `~/.config/cosmopod-os/keys`, outside Git and OneDrive.
Initialize a local key pair once with:

```bash
scripts/generate-signing-key.sh --replace-device-key
```

Initializer creates ECDSA P-256, matching production key policy. Repository's
current RSA-3072 public key belongs to historical development media; replacing
it changes trust for future factory images and requires a full rebuild.

The flag means "replace the public key compiled into future device images."
The script deliberately refuses to overwrite an existing local pair. Key
rotation is a separate production migration requiring overlapping trusted
verification keys; do not delete the old pair and rerun this initializer.

```bash
# On the trusted builder, send these two values to the approval ledger/channel:
sha256sum out/0.40.0/pi4-release/SHA256SUMS
sha256sum out/0.40.0/pi4-release/Cosmopod-OS-0.40.0-pi4-unsigned.mender

# On the offline signer, use approved values from that independent channel.
scripts/sign-release.sh \
  --approve-server-url https://kys.dpdns.org \
  --approve-build-index-sha256 <approved-sha256-of-SHA256SUMS> \
  --approve-unsigned-sha256 <approved-sha256-of-unsigned-mender> \
  out/0.40.0/pi4-release/Cosmopod-OS-0.40.0-pi4-unsigned.mender
```

The signer rejects extra files, symlinks, unsafe checksum paths, stale CVE
evidence, a changed source checkout, and input changes during signing. It emits
the signed `.mender`, a signing record, artifact checksum, updated
`SHA256SUMS`, and `SHA256SUMS.sig`. Verify the latter before trusting any Pi
sidecar:

```bash
openssl dgst -sha256 -verify \
  meta-cosmopod/recipes-mender/mender/files/artifact-verify-key.pem \
  -signature out/0.40.0/pi4-release/SHA256SUMS.sig \
  out/0.40.0/pi4-release/SHA256SUMS
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
is `cosmopod` version `0.1.0`. This is historical build evidence: those files
predate `BUILD-MANIFEST.txt`, later boot fixes, and the VM smoke reporter. The
current validator intentionally rejects them until fresh media is produced from
a clean, matching commit.

QEMU TCG smoke tests using a Core 2-capable CPU model reached a serial login
from the BIOS live ISO and the UEFI QCOW2 disk. The QCOW2 root and data
partitions mounted read-write and swap activated. ISO testing proved its tmpfs
`/data` fallback, persistent-state setup, NetworkManager, first-boot
provisioning, and key-only SSH daemon startup. It also found and drove fixes for
an absent live mount point, unconditional NFSD mount, and expected read-only
root remount. Weston still failed under the last tested virtio GPU run. That
historical kernel also had `CONFIG_HYPERVISOR_GUEST` disabled. Current source
uses Weston's Pixman renderer and builds Hyper-V DRM, input, storage, and
network support into the x86 kernel; it also includes an opt-in, fixed-function
guest reporter plus `scripts/smoke-vm.ps1`. Rebuild the VM media and pass both
ISO and QCOW2 checks before VM qualification.

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
