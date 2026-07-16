# Flash and first boot

## Choose correct image

- Raspberry Pi 4: `...-pi4.img.xz`
- Raspberry Pi 5: `...-pi5.img.xz`

Use an 8 GB or larger SD card or supported USB storage. A normal `.iso` is not
bootable by Raspberry Pi firmware; use the partitioned `.img.xz` release.

## Verify release

From Linux/WSL in the release directory:

```bash
sha256sum --check SHA256SUMS
```

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

MENDER_SERVER_URL=https://kys.dpdns.org
MENDER_TENANT_TOKEN=
ALLOW_INSECURE_MENDER=false
```

Generate a client SSH key if needed:

```powershell
ssh-keygen -t ed25519 -a 64 -f $HOME\.ssh\cosmopod
Get-Content $HOME\.ssh\cosmopod.pub
```

Parser accepts only documented keys and never evaluates shell expressions.
HTTPS is mandatory for Mender unless `ALLOW_INSECURE_MENDER=true` is explicitly
set for an isolated lab.

The first-boot service:

- moves hostname, home, network settings, SSH host keys, and Mender config to
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
systemctl status weston sshd mender-authd mender-updated
nmcli device status
journalctl -b
mender-update show-artifact
```

Cosmopod OS is Yocto-based; it does not use `apt upgrade`. Build and deploy a
new signed `.mender` artifact for operating-system changes.

## Connect to backend

After a reachable Mender backend has been deployed at the configured URL, the
Pi appears under pending devices in the Mender UI. Check its identity, then
accept it. Put the first device in a `dev` or `canary` group before deploying
any update.
