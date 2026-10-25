# Flash and first boot

## Choose correct image

- Raspberry Pi 4: `...-pi4.img.xz`
- Raspberry Pi 5: `...-pi5.img.xz`

Use an 8 GB or larger SD card or supported USB storage. A normal `.iso` is not
bootable by Raspberry Pi firmware; use the partitioned `.img.xz` release.

## Verify release

From Linux/WSL in the release directory:

```bash
openssl dgst -sha256 -verify artifact-verify-key.pem \
  -signature SHA256SUMS.sig SHA256SUMS
sha256sum --check SHA256SUMS
```

Obtain `artifact-verify-key.pem` through the trusted project source or release
key channel, never from the same unauthenticated download alone. VM-only or
unsigned factory-test bundles do not contain `SHA256SUMS.sig`; their checksum
index needs an authenticated release-ledger digest instead.

From PowerShell, compare `Get-FileHash -Algorithm SHA256 <file>` with the entry
in `SHA256SUMS`.

## Flash

Use Raspberry Pi Imager or balenaEtcher and choose the compressed `.img.xz` as
a custom image. Confirm the destination drive twice; flashing overwrites it.

After flashing, remove and reconnect the media so the FAT boot partition is
visible.

## Provision

Rename `cosmopod.conf.example` to `cosmopod.conf`. At minimum, paste an SSH
public key:

```ini
COSMOPOD_HOSTNAME=cosmopod
SSH_PUBLIC_KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... laptop

WIFI_COUNTRY=GB
WIFI_SSID=My WiFi
WIFI_PASSWORD=correct horse battery staple

```

Generate a client SSH key if needed:

```powershell
ssh-keygen -t ed25519 -a 64 -f $HOME\.ssh\cosmopod
Get-Content $HOME\.ssh\cosmopod.pub
```

Parser accepts only documented keys and never evaluates shell expressions.
Standalone update downloads require HTTPS. No backend credentials are needed.

The first-boot service:

- moves hostname, home, network settings, and SSH host keys to
  persistent `/data` storage;
- deletes `cosmopod.conf` from the boot partition after applying it;
- writes `cosmopod-provisioned.txt` as a receipt.

Deleting a secret from flash is not guaranteed to erase all physical remnants
because flash controllers remap blocks. Treat physical access to the media as
trusted during provisioning.

## Connect

Wayland/Weston starts on the attached display. SSH starts only with key auth:

```bash
ssh -i ~/.ssh/cosmopod cosmopod@cosmopod.local
```

If mDNS is unavailable, find the address from router DHCP leases or the local
Weston terminal with `ip address`.

Useful checks:

```bash
systemctl --failed
systemctl status weston sshd
nmcli device status
journalctl -b
mender-update show-artifact
```

Cosmopod OS is Yocto-based; it does not use `apt upgrade`. Build and deploy a
new signed `.mender` artifact for operating-system changes.

## Install updates

No backend registration is needed. On standalone images, use
`cosmopod-update check`, then `sudo cosmopod-update install`. Reboot and inspect
the new system before `sudo cosmopod-update commit`. See
[standalone updates](UPDATE-SYSTEM.md) for signatures, recovery and release gates.
Old provisioning files must omit MENDER_SERVER_URL, MENDER_TENANT_TOKEN and
ALLOW_INSECURE_MENDER; these managed-mode fields are no longer accepted.
