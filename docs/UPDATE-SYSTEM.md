# Standalone signed updates

Cosmopod uses Mender's on-device A/B installer without a Mender server. Users
download board-specific signed files from public GitHub Releases. No device
registration, tenant token, Kubernetes cluster, or always-on home server is
required. Managed Mender daemons are disabled and masked in factory images.

This is implemented from development version 0.73.0. Implementation and source
tests are not proof of physical Pi update, rollback, watchdog, or power-loss
qualification. Do not label the OS 1.0.0 until those tests and security gates pass.

## User workflow

On a Pi already flashed with a matching standalone factory image:

```sh
cosmopod-update status
cosmopod-update check
sudo cosmopod-update install
sudo reboot
# Reconnect over SSH after the reboot and inspect the running system.
cosmopod-update status
sudo cosmopod-update commit
```

`check` reads the latest non-draft, non-prerelease `vVERSION` GitHub release.
`install --version 1.0.1` selects an explicit stable version. Both select Pi 4
or Pi 5 from the Mender device type; VM images are explicitly rejected.
Installation rejects the current version, downgrades, and another pending
wrapper-managed transaction. It never reboots or commits automatically.

Before touching a rootfs slot, the command verifies the per-board SHA256SUMS
signature using the public key built into the OS and verifies the downloaded
artifact's SHA-256. Mender then independently checks the artifact signature and
device compatibility. A plain checksum from a website is not an authenticity
check. All downloads and redirects require HTTPS; no GitHub credentials are
sent by the device. Public API rate limits apply to release discovery; use an
explicit version if latest-release discovery is temporarily unavailable.

`commit` requires a new boot ID and the requested OS version. Mender executes
the artifact's health gate: 120 continuous healthy seconds within a 300-second
deadline, checking /data, persistence, networking, SSH, Weston/Wayland, and Pi
watchdog configuration. Managed update/auth daemons are not health dependencies.
Do not commit an unhealthy system. Explicit rollback is:

```sh
sudo cosmopod-update rollback
sudo reboot
```

U-Boot's trial-boot mechanism and the hardware watchdog remain necessary for
unattended recovery. Their behaviour must be tested on each Pi and storage
type; an inactive-slot design alone does not prove power-loss safety.

## Persistent state and interrupted operations

Home, SSH host keys, network profiles, and hostname remain under `/data`.
The updater stores a root-only intent journal at `/data/cosmopod/update.json`
before invoking Mender and serializes mutations with an advisory lock.
An interrupted install retains that journal and blocks another install.
Mender's own transaction state remains authoritative; the journal is not a
replacement for it. A successfully committed or explicitly rolled-back update
removes the journal.

After automatic bootloader rollback, the old OS version will not match the
pending version and the wrapper refuses to commit. If Mender reports that no
update is in progress, inspect `mender-update show-artifact`, the current
rootfs mount, OS version, and logs before an administrator removes the stale
wrapper journal. Never clear Mender's database or rewrite boot variables just
to bypass a failed check. Factory reflashing remains the last-resort recovery
path; back up persistent data first.

An ordinary rootfs artifact does not safely replace shared Raspberry Pi boot
firmware, kernel/DTB files on the FAT partition, or the entire disk layout.
Changes there require newly flashed factory media until a separately qualified
boot-component update strategy exists. Do not distribute incompatible rootfs
and boot firmware combinations.

## Build, sign, and publish

All Cosmopod builds run on Blackwall under `/mnt/nvmestorage` for this project.
The builder records `update_mode=standalone` and an empty `mender_server_url`.
Release builds still fail closed on fresh denied CVEs. Development artifacts
with a failed gate must not be signed or published as stable updates.

Initialize a private signing key outside Git with the existing
`scripts/generate-signing-key.sh --replace-device-key` helper, if no usable key
exists. It installs only the public key into future factory images. Back up the
private key offline, protect it with mode 0400/0600, and rebuild factory images
after changing trust. Do not silently rotate keys for already deployed devices.
The checked-in key is a historical development trust root; production trust and
key custody require separate approval and verification.

```sh
bash scripts/build.sh --board pi4 --version VERSION --channel release --engine native
# Also build pi5 and vm at the same clean source commit.
bash scripts/sign-release.sh --standalone \
  --approve-build-index-sha256 APPROVED_INDEX_SHA256 \
  --approve-unsigned-sha256 APPROVED_ARTIFACT_SHA256 \
  out/VERSION/pi4-release/Cosmopod-OS-VERSION-pi4-unsigned.mender
# Sign Pi 5 independently with its approved digests.
bash scripts/publish-release.sh VERSION
```

The signer retains exact-file-set validation, provenance replay, fresh CVE
checks, required health scripts, wrong-key rejection, and signed release-index
creation. Obtain approved digests through an independent trusted channel, not
just from an untrusted copy of the files being signed.

The publisher validates all targets and signed Pi sidecars before creating a
**draft** GitHub release. Existing releases are never overwritten. The owner
must review physical qualification and approve public promotion. On publication,
use the tag `vVERSION` and do not mark it prerelease if it is intended for stable
discovery. The publisher aliases indexes to `SHA256SUMS-pi4` / `-pi5` and their
`.sig` files so both boards can share one release. Signatures authenticate the
unchanged index bytes, not their public download filenames. Build manifests and
KAS overlays are also suffixed by board to avoid duplicate asset names. Restore
their original names when replaying a full board-specific checksum set. The
raw VM ISO is represented by its compressed archive and QCOW2 is compressed at
publication time to stay below the per-asset limit; decompress before checking
the raw media digests. Unsigned intermediate Pi artifacts are included as build
evidence, but the updater selects only the signed `.mender` file.

## Acceptance gates before 1.0.0

- Fresh passing CVE evidence, clean immutable inputs, SPDX and licence evidence.
- VM ISO/QCOW2 boot, persistence, SSH, Wayland, and artifact integrity checks.
- Pi 4 and Pi 5 factory boot and hardware tests, headless SSH and watchdog proof.
- Real signed standalone installation, reboot, health-checked explicit commit.
- Unsigned, tampered, wrong-key, wrong-board, and downgrade rejection.
- Forced health failure, automatic rollback, retained user/network/SSH state.
- Power interruption during download, slot write, first boot, and pre-commit.
- At least 100 update/recovery cycles per qualified board/storage class.
- Public release assets and download/install instructions verified end to end.

The old `backend/` templates are retained as optional historical tooling, not a
release prerequisite. They do not describe the default update path.

References: [Mender standalone deployment](https://docs.mender.io/artifact-creation/standalone-deployment),
[signing and verification](https://docs.mender.io/artifact-creation/sign-and-verify),
[state scripts](https://docs.mender.io/artifact-creation/state-scripts).
