# Cosmopod OS update system

Cosmopod OS uses [Mender](https://docs.mender.io/overview/introduction) for managed, signed, A/B operating-system updates. This design targets Raspberry Pi 4 and Raspberry Pi 5. The first release updates the root filesystem, its system packages, services, and applications. Shared Raspberry Pi boot firmware, kernels/DTBs stored on that partition, and EEPROM are deliberately outside the normal OTA path.

## Implementation status

Implemented in this repository: A/B image integration, compiled-in RSA-3072
artifact verification key, a 300-second health deadline requiring 120 seconds
of continuous stability, persistent home/network/SSH/Mender state, separate Pi
device types, signing helper, and backend templates. Version 0.1.0's Pi 4
artifact was built, signed, and validated locally, but predates the current
source-provenance manifest and must not be promoted. Current GitHub CI performs
source/unit checks; it does not yet build, sign, upload, or deploy releases.
The production backend is not yet deployed. Hardware watchdog,
data-schema migration/rollback, full UI self-test, retained diagnostics, and
automated release evidence below are production requirements/backlog, not
claims about version 0.1.0.

## Safety invariants

- A device always boots from one active root filesystem while Mender writes the new image to the inactive root filesystem.
- The device commits an update only after a local health gate passes. A failed gate causes automatic rollback.
- `/data` survives a root filesystem replacement. Mutable product state belongs there, not in `/etc`, `/var`, or a home directory on the root filesystem.
- Every production artifact is signed offline. Devices reject unsigned artifacts and artifacts signed by an unknown key.
- Raspberry Pi 4 and Pi 5 artifacts are separate, even when they share one release name.
- A release moves through explicit rings. Uploading a release never means automatic fleet-wide deployment.
- The normal OTA path does not modify the shared FAT boot partition or Raspberry Pi EEPROM.

These rules follow Mender's [dual A/B model](https://github.com/mendersoftware/mender) and [system-update transaction](https://docs.mender.io/artifact-creation/combining-system-and-application-updates).

## Disk and boot layout

The image uses the standard Mender layout described in its [Yocto partition documentation](https://docs.mender.io/operating-system-updates-yocto-project/board-integration/partition-configuration):

| Partition | Purpose | Updated by normal rootfs OTA |
| --- | --- | --- |
| Boot | Shared Raspberry Pi firmware, U-Boot, `config.txt`, and any boot-chain DTB/overlays | No |
| Rootfs A | Active or inactive complete OS image | Yes |
| Rootfs B | Inactive or active complete OS image | Yes |
| Data | Persistent identity, state, configuration, logs, and recovery data | No |

The exact block device must be set through the Mender Yocto integration for each qualified storage class. Do not hard-code `/dev/mmcblk0`: SD, eMMC, and NVMe name devices and partitions differently.

Version 0.1.0 persists these implemented paths:

- `/data/mender`: Mender device identity and keys.
- `/data/cosmopod/home`: user home.
- `/data/cosmopod/network`: NetworkManager profiles.
- `/data/cosmopod/ssh`: SSH host keys.
- `/data/cosmopod/hostname`: configured hostname.

Application config/state, bounded retained logs, and migration recovery areas
must be designed before an application begins storing mutable fleet data.

A full rootfs update replaces everything on the selected root partition. A file placed only in the active rootfs will not survive the next update.

Cosmopod's Yocto build uses the Raspberry Pi integration from [`meta-mender-community`](https://github.com/mendersoftware/meta-mender-community/tree/scarthgap/meta-mender-raspberrypi), enables the Mender U-Boot integration, and produces both:

- a complete disk image for factory provisioning; and
- a `.mender` rootfs artifact for OTA.

U-Boot integration is board-specific and must be tested on real hardware. Mender documents the required integration flags and caveats in [U-Boot support](https://docs.mender.io/operating-system-updates-yocto-project/board-integration/bootloader-support/u-boot).

## Managed update flow

1. The release procedure builds one unsigned `.mender` artifact for each supported device type and records the source commit, Yocto lock data, mandatory license/SPDX archives, image CVE report, CVE-gate decision, test result, and SHA-256 digest.
2. An authenticated build record supplies the checksum-index and unsigned-artifact digests independently of the bundle sent to the offline signer.
3. A separate trusted signing step verifies a private snapshot, signs the artifact, validates it with the public key, records its final digest, and signs the final release index.
4. An operator uploads only the signed artifact to the Mender server as a release. Upload is not deployment.
5. An operator creates a deployment for the next approved static device group.
6. Each device polls the server over outbound HTTPS. No inbound device port is needed for Mender. Polling behavior is documented in [Mender client polling intervals](https://docs.mender.io/client-installation/configuration/polling-intervals).
7. The client verifies TLS, artifact signature, artifact checksum, and device compatibility before installation.
8. Mender writes the image to the inactive rootfs, verifies it, asks U-Boot to try that slot, and reboots.
9. The new slot starts. Before commit, `ArtifactCommit_Enter_50_cosmopod-health` runs the Cosmopod health contract.
10. A passing gate lets Mender commit the slot. A failing gate triggers rollback and reboot to the previous slot.
11. The deployment result and diagnostic logs return to the server. Promotion waits for the ring's soak period and acceptance gates.

Do not use the Mender **Force update** option in normal operation. It can bypass safeguards around the device's current update state and belongs only in a reviewed recovery runbook.

## Release identity and compatibility

Use an immutable release name:

```text
cosmopod-<semver>+<build-id>
```

Example:

```text
cosmopod-1.4.0+20260715.3
```

The release may contain multiple artifacts, but each artifact has exactly the intended compatible device type: `cosmopod-rpi4-64` for Pi 4 or `cosmopod-rpi5` for Pi 5. Mender uses device compatibility to block installation on the wrong hardware; see [deploying an OS update](https://docs.mender.io/get-started/deploy-an-operating-system-update).

Never overwrite or reuse an artifact name. If the fleet must return to last-known-good source, build and sign a new forward-moving recovery release with a new version and artifact name. Reusing an already-installed artifact can cause clients to treat the deployment as already satisfied.

## Production artifact signing

### Key policy

Use ECDSA P-256 for the first production signing key. Keep the private key offline or in an HSM/PKCS#11 device. The private key must never exist in:

- the Git repository;
- the normal CI runner;
- the Mender server;
- a device image; or
- an operator laptop used for routine deployment.

Keep separate development and production trust roots. Maintain an encrypted offline backup of the production key, an access log, and two-person approval for production signing.

Mender supports ECDSA P-256 and RSA keys of at least 3072 bits. Its complete signing and verification behavior is in [Sign and verify](https://docs.mender.io/artifact-creation/sign-and-verify).

### One-time offline key creation

Run on the isolated signing system:

```sh
umask 077
openssl ecparam -genkey -name prime256v1 -out private-and-params.key
openssl ec -in private-and-params.key -out cosmopod-prod-signing.key
openssl ec -in private-and-params.key -pubout -out artifact-verify-key.pem
```

Archive `cosmopod-prod-signing.key` and its encrypted backup offline. Export only `artifact-verify-key.pem` to the build workspace.

Bake the public verification key into the production image with a custom Yocto recipe append. For Mender Client 4 and newer, append to the `mender` recipe as described in [Build for production](https://docs.mender.io/operating-system-updates-yocto-project/build-for-production):

```bitbake
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://artifact-verify-key.pem"
```

Configure `ArtifactVerifyKey` or `ArtifactVerifyKeys` on the device. With a verification key configured, an unsigned or wrongly signed artifact must be rejected. Make that rejection an automated release test.

### Sign and validate a release

The trusted signer receives the unsigned artifact plus immutable release
evidence. The two approved hashes must arrive through a separate authenticated
build record, not be copied from the untrusted transfer bundle. After review:

```sh
scripts/sign-release.sh \
  --approve-server-url https://updates.example.org \
  --approve-build-index-sha256 <approved-sha256-of-SHA256SUMS> \
  --approve-unsigned-sha256 <approved-sha256-of-unsigned-mender> \
  out/1.4.0+20260715.3/pi4/Cosmopod-OS-1.4.0+20260715.3-pi4-unsigned.mender

openssl dgst -sha256 -verify artifact-verify-key.pem \
  -signature out/1.4.0+20260715.3/pi4/SHA256SUMS.sig \
  out/1.4.0+20260715.3/pi4/SHA256SUMS
```

Repeat for Pi 5. Upload only the signed `.mender` to Mender; publish its
authenticated evidence set as release records. Record artifact name, release
name, compatible device type, final digest, source commit, SBOM digest, signer
identity, approvers, and signing time in the release ledger.

The builder's original index is not attestation; the independent approved
digest is the transfer trust anchor. After signing, `SHA256SUMS.sig`
authenticates the final Pi index and the sidecars it covers. Factory/VM media
still require an authenticated release ledger or separate signed provenance.

### Verification-key rotation

1. Build a release signed by the old key that installs both old and new public keys through `ArtifactVerifyKeys`.
2. Deploy it through every ring and prove that the entire reachable fleet trusts both keys.
3. Sign later releases with the new private key.
4. After the old key's retirement window and recovery review, deploy a release that removes the old public key.
5. Revoke and investigate immediately if a private key may be compromised. Do not remove the old public key before devices can accept a trusted transition release.

Artifact signing authenticates an artifact. It is not secure boot, and by itself it does not prevent an authorized backend operator from deploying an older artifact that still has a valid signature. Use RBAC, two-person promotion approval, an immutable release ledger, and a custom monotonic-version check if anti-downgrade is required by the threat model.

## Health-gated commit

Package this executable as an Artifact state script:

```text
ArtifactCommit_Enter_50_cosmopod-health
```

`cosmopod-config` inherits `mender-state-scripts`, so the script is placed in
the `.mender` Artifact deploy payload rather than incorrectly baked into the
rootfs. See [including state scripts in an image](https://docs.mender.io/operating-system-updates-yocto-project/image-customization/state-scripts).

Mender recommends `ArtifactCommit_Enter` for post-boot sanity checks. Exit `0` permits commit; any non-zero exit triggers rollback. See the [state-script state machine](https://docs.mender.io/artifact-creation/state-scripts).

### Health contract

The implemented script observes continuous health for 120 seconds, not one successful instant. It exits non-zero on timeout or any hard failure. It checks:

- `/data` is mounted read-write and passes a real write/sync/remove probe;
- `mender-authd` and `mender-updated` are active;
- SSH service is active and `sshd -t` validates configuration;
- NetworkManager and Weston are active; and
- the compositor exposes its Wayland socket.

Running-slot/version verification, failed-unit policy, UI render self-test,
watchdog proof, schema compatibility, disk thresholds, and filesystem counters
remain production backlog and must be added before those properties are used as
promotion claims.

The checker must not require an arbitrary public Internet host. Mender manages update-server reachability as part of its own transaction. Local product health should not fail because a third-party website is unavailable.

State scripts must be idempotent, bounded by timeouts, and write concise diagnostics to standard error. Mender includes state-script output in failure reporting. Never put a blocking interactive command in the health path.

### Persistent-data migrations

Rollback can boot old code against new `/data`. Therefore:

- Use expand-migrate-contract migrations.
- The pre-commit phase may only add backward-compatible data structures.
- Back up affected state under a versioned recovery path before mutation.
- Keep the previous image able to read the data until the new release is committed and the rollback window has expired.
- Use `ArtifactRollback_Enter` for a tested restoration step when a migration cannot be naturally backward compatible.
- Never delete old fields, rewrite secrets irreversibly, or perform a one-way database upgrade before commit.

A migration failure is a health-gate failure. Version 0.1.0 has no migration
framework; releases requiring persistent-schema changes are therefore blocked.

### Hung-kernel protection

An `ArtifactCommit_Enter` script cannot run if the new kernel never reaches userspace. Hardware watchdog and explicit forced-hang qualification remain backlog. A production release must enable and test them before claiming automatic recovery from pre-userspace hangs.

## Backend upload and deployment

The Mender server is the release inventory, device registry, deployment controller, and audit point. It is not the production signing authority.

Upload a signed artifact through the UI under **Releases**, or with `mender-cli`:

```sh
mender-cli artifacts \
  --server "$MENDER_SERVER_URL" \
  --token-value "$MENDER_PAT" \
  upload "$SIGNED_ARTIFACT"
```

This command is documented in [Using the APIs](https://docs.mender.io/server-integration/using-the-apis). For automation, use a short-lived, least-privilege personal access token from the deployment environment's secret manager. Never echo the token or embed it in an image.

After upload, an operator verifies in Mender:

- release and artifact names;
- compatible device type;
- final SHA-256 digest against the signed release ledger;
- artifact size and upload completion; and
- that both Pi 4 and Pi 5 variants are present when the release claims both.

Then create a deployment for one approved static group. Mender deployments and status values are described in [Deployment](https://docs.mender.io/overview/deployment). Device grouping is described in [Device groups](https://docs.mender.io/overview/device-group).

Keep build, sign, upload, and promote as separate permissions. A CI job may build and request signing. It must not automatically deploy to the stable fleet.

## Staged rollout

Use static groups as durable rollout rings:

| Ring | Membership | Minimum soak | Promotion gate |
| --- | --- | --- | --- |
| `ring-0-lab` | Engineering Pi 4 and Pi 5; every supported storage class | Destructive test campaign | All update, reboot, rollback, watchdog, and power-cut tests pass |
| `ring-1-canary` | At least two devices of each hardware/storage class, or 1% of fleet if larger | 24 hours | 100% expected success; zero unexplained rollback; no critical alert |
| `ring-2-beta` | Representative 10% of fleet | 48 hours | At least 99% success; failures explained; health and workload metrics unchanged |
| `ring-3-stable` | Remaining production fleet | Release-specific | No stop condition; two-person promotion approval |

Create each ring's deployment only after the previous ring passes. Do not pre-create all deployments. The same signed release moves forward; it is never rebuilt between rings.

If the server edition supports phased deployments, the stable ring may use a 25% phase followed by the remainder. Otherwise subdivide stable devices into static groups before the rollout. Manual ring approval remains the authority either way.

Stop promotion immediately if any of these occurs:

- boot loop, shared boot-partition corruption, or failure to return to the old slot;
- security control regression;
- more than 2% unexpected deployment failures in a ring;
- more than 1% automatic rollback in a ring;
- loss or corruption of persistent data;
- common failure across a hardware or storage class; or
- a severity-1 operational alert plausibly linked to the release.

On stop, pause or abort the active deployment, preserve logs, quarantine the suspect release, and open an incident. Do not continue merely because most devices succeeded.

## Rollback and recovery

| Failure | Expected response | Operator action |
| --- | --- | --- |
| Network or power loss during download | Active slot is untouched; client retries | Confirm device returns and deployment resumes |
| Power loss while writing inactive rootfs | Active slot remains bootable; incomplete inactive image is not committed | Confirm old slot boots; retry or redeploy after storage check |
| New userspace fails health gate | State script exits non-zero; Mender rolls back and reboots | Inspect deployment and journal logs; stop promotion |
| New kernel panics or hangs before userspace | Watchdog recovery is not yet qualified | Reflash known-good factory media; block production promotion |
| `/data` migration breaks fallback | Migration framework is not yet implemented | Do not deploy schema-changing releases |
| Both rootfs slots are damaged | A/B rollback cannot help | Reprovision from known-good factory media |
| Shared boot partition, U-Boot, or Pi EEPROM is damaged | Rootfs A/B cannot help | Use documented serial/factory recovery and known-good boot media |
| Backend sends a bad but validly signed release | Staged rings limit impact; device may still accept it | Abort deployment; create a new signed recovery release; audit approvals |

Useful on-device diagnostics:

```sh
journalctl -u mender-updated -u mender-authd --no-pager
systemctl --failed
findmnt /data
```

Preserve the previous signed artifacts, factory image, exact build inputs, public trust keys, and release evidence. Keep a known-good SD card per supported board class. Compute Module products should also have a tested `rpiboot` recovery path where applicable.

Do not issue a manual Mender rollback while the client is inside a managed deployment unless the recovery runbook explicitly accounts for the Mender state machine. Prefer aborting at the server and letting the health gate perform its normal rollback.

## Raspberry Pi boot-firmware and DTB boundary

The normal Mender rootfs artifact updates the inactive root filesystem. It does not provide atomic A/B protection for every Raspberry Pi boot component.

Depending on the final BSP and boot chain, the shared FAT boot partition may contain:

- Raspberry Pi GPU firmware such as `start*.elf` and `fixup*.dat`;
- `config.txt` and `cmdline.txt`;
- U-Boot binaries and environment data;
- board DTBs and overlay files; and
- boot scripts or boot-selection metadata.

Raspberry Pi Device Tree configuration is driven through the boot configuration and overlays documented in the official [overlay README](https://github.com/raspberrypi/firmware/blob/master/boot/overlays/README). Raspberry Pi 4 and Pi 5 also have an EEPROM bootloader maintained separately in [`rpi-eeprom`](https://github.com/raspberrypi/rpi-eeprom).

These components may be shared by both rootfs slots. Updating them in place can make both slots unbootable, so a rootfs rollback may not recover the device.

Production policy for the first release:

- Pin known-good Raspberry Pi firmware, U-Boot, boot configuration, DTBs/overlays, and EEPROM policy in the factory image.
- Do not update the shared boot partition through a normal rootfs artifact.
- Do not update Raspberry Pi EEPROM through normal unattended OTA.
- Keep kernel modules and the kernel version in the same rootfs transaction. Verify experimentally where the final boot chain loads the kernel and DTB for both Pi models.
- Qualify Pi 4 and Pi 5 separately. Qualify SD, eMMC, and NVMe separately before enabling each storage type.

If shared boot firmware must later become updateable, design it as a separate project with redundant or recoverable boot assets, power-failure-safe switching, explicit maintenance power requirements, and a destructive power-cut test matrix. A custom Mender Update Module alone does not make an in-place boot-firmware update atomic.

Artifact signing is not secure boot. If the threat model includes physical modification of the SD card or shared boot files, add Raspberry Pi verified/secure boot and measured device identity as separate controls.

## Release qualification

Before `ring-0-lab`, automate and record:

- artifact signature acceptance with the production public key;
- rejection of unsigned, modified, wrong-key, wrong-device-type, and replay-disallowed artifacts;
- clean update from every supported prior version;
- update with nearly full rootfs and `/data` thresholds;
- power removal during download, inactive-slot write, boot switch, first boot, health gate, and commit;
- forced health-check failure and verified old-slot return;
- forced kernel panic and pre-userspace hang with watchdog recovery;
- network loss before and after reboot;
- persistent-state survival and backward-compatible migration rollback;
- Wayland compositor and shell health after cold boot and update reboot;
- SSH key access after update, with password and root login still blocked;
- 100 consecutive A/B update/rollback cycles on each hardware/storage class; and
- recovery from known-good factory media by a technician following only the runbook.

## Production security checklist

- [ ] Remove `meta-mender-demo`, demo keys, demo certificates, default passwords, and development services. Follow [Mender's production-build guidance](https://docs.mender.io/operating-system-updates-yocto-project/build-for-production).
- [ ] Use only HTTPS with a trusted server certificate. Keep device time correct so TLS validation works.
- [ ] Require artifact signature verification on every production device.
- [ ] Keep the production signing key offline or in an HSM; use separate development and production keys.
- [ ] Encrypt `/data` where the product threat model requires protection at rest, and ensure recovery keys are operationally backed up.
- [ ] Give every device a unique authentication key. Never clone `/data/mender` from a provisioned device into the factory image.
- [ ] Approve or preauthorize only inventoried device identities. Reject unknown devices.
- [ ] Require management MFA/SSO, least-privilege RBAC, and two-person approval for stable promotion.
- [ ] Use short-lived, least-privilege API tokens from a secret manager. Rotate and audit them.
- [ ] Keep build, signing, server administration, release upload, and stable deployment permissions separate.
- [ ] Configure SSH for keys only, disable direct root login and password authentication, restrict listening interfaces where practical, and firewall all unnecessary ports.
- [ ] Expose no inbound Mender port on devices. Devices initiate outbound HTTPS connections.
- [ ] Protect the server's database, artifact object storage, message bus, configuration, TLS keys, and audit logs. Test backup restoration, not only backup creation.
- [ ] Monitor deployment failure, rollback, device check-in age, storage health, watchdog resets, authentication failures, and unusual administrator actions.
- [ ] Record source commit, reproducible build inputs, SBOM, vulnerability decision, artifact digest, signer, approvers, target ring, and result for every release.
- [ ] Keep Mender server and client versions inside the documented [compatibility policy](https://docs.mender.io/overview/compatibility-policy). Upgrade the server before clients when required.
- [ ] Test artifact-key rotation, server-certificate rotation, device-key replacement, backend outage, and factory recovery at least annually.
- [ ] Keep stable deployment manual. Never turn a successful build into an automatic fleet-wide release.
- [ ] Review Mender's [security model](https://docs.mender.io/overview/security) and the chosen server edition's production installation guidance before launch.

## Primary references

- [Mender introduction and A/B update model](https://docs.mender.io/overview/introduction)
- [Mender Client source and architecture](https://github.com/mendersoftware/mender)
- [Raspberry Pi Yocto integration](https://github.com/mendersoftware/meta-mender-community/tree/scarthgap/meta-mender-raspberrypi)
- [Partition configuration](https://docs.mender.io/operating-system-updates-yocto-project/board-integration/partition-configuration)
- [U-Boot integration](https://docs.mender.io/operating-system-updates-yocto-project/board-integration/bootloader-support/u-boot)
- [Artifact signing and verification](https://docs.mender.io/artifact-creation/sign-and-verify)
- [Mender state scripts](https://docs.mender.io/artifact-creation/state-scripts)
- [Mender deployment model](https://docs.mender.io/overview/deployment)
- [Mender security](https://docs.mender.io/overview/security)
- [Raspberry Pi EEPROM bootloader](https://github.com/raspberrypi/rpi-eeprom)
- [Raspberry Pi Device Tree overlays](https://github.com/raspberrypi/firmware/blob/master/boot/overlays/README)
