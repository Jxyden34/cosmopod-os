# Security model

Cosmopod OS is secure-by-default for network access and update authenticity,
but it is not a complete Raspberry Pi secure-boot product.

## Implemented controls

- SSH password, keyboard-interactive, empty-password and root login disabled.
- SSH restricted to user `cosmopod` and public-key authentication.
- Stable SSH host keys stored on persistent data partition.
- Mender artifacts rejected unless signed by compiled-in verification key.
- A/B full-rootfs updates and U-Boot rollback.
- Local service/Wayland health gate before update commit.
- Mender URL requires HTTPS unless lab-only insecure override is explicit.
- Provisioning parser uses an allowlist and no shell evaluation.
- Upstream Yocto layers and CI actions pinned to full commits.
- SPDX archive, license manifests, and checksums generated with release builds.
- Private signing key and backend secrets ignored by Git.

## Private signing key

`~/.config/cosmopod-os/keys/artifact-signing-private.pem` is the most sensitive local file. Anyone who
gets it can sign an OS accepted by all devices built with matching public key.

Production rules:

1. Generate and keep key offline, or use supported HSM/KMS signing.
2. Never place key on Mender Server or a Pi.
3. Keep encrypted, tested backups with documented recovery ownership.
4. Use separate dev and production signing roots.
5. Test key rotation with overlapping verification keys before removing old
   key from devices.

The repository public key is not secret.

## Backend

- Terminate only trusted public TLS certificates in production.
- Restrict management UI/API by VPN or identity-aware proxy.
- Enable MFA/RBAC where available.
- Use separate upload and rollout identities.
- Back up MongoDB and object storage together.
- Log device acceptance, release upload, deployment, failure and rollback.
- Promote identical artifact digest from canary to stable; never rebuild during
  promotion.
- Never upload an unsigned artifact.

## Residual risks

- Default Raspberry Pi firmware/U-Boot chain does not provide full verified
  boot. Physical attacker can alter boot media.
- Shared FAT boot firmware and some DTBs are not safely covered by ordinary
  rootfs A/B updates. Update them only through a separately tested recovery
  process.
- Persistent `/data` is not encrypted by default. Lost media exposes Wi-Fi
  profiles, user files, Mender identity and SSH public authorization data.
- `cosmopod` has passwordless sudo. Compromise of its SSH key becomes root
  compromise. This prioritizes owner usability; high-assurance deployments
  should replace policy with command-scoped sudo or no sudo.
- Mender backend compromise can choose when/where to deploy previously signed
  releases. Artifact signatures stop forged releases, not every replay/freeze
  scenario.
- Flash wear-leveling makes secure deletion of provisioning secrets unreliable.
- The KAS container tag and transitive PyPI packages are version-pinned but not
  yet digest/hash locked; production CI must close this supply-chain gap.

## Production hardening backlog

- Raspberry Pi signed boot/TPM-backed measured boot design
- LUKS2 data partition with TPM or operator recovery key
- hardware watchdog wired into failed health recovery
- read-only rootfs and explicit writable overlays
- device identity key in TPM/secure element
- per-device mTLS and automated certificate rotation
- reproducible-build comparison across independent workers
- centralized append-only logs and alerting

Report suspected security issues through the private process in
[`SECURITY.md`](../SECURITY.md). Do not publish live credentials, signing keys,
device tokens, or exploitable fleet details in a public issue.
