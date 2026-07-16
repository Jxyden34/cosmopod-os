# Architecture

Cosmopod OS uses established embedded-Linux components rather than a custom
updater or package mutation protocol.

```text
kas configuration
  + pinned Yocto/OE layers
  + meta-raspberrypi
  + meta-mender-community
  + meta-cosmopod
             |
             +-- Pi 4 factory .sdimg + Pi 4 .mender update
             +-- Pi 5 factory .sdimg + Pi 5 .mender update
             +-- x86-64 live .iso + persistent .qcow2 VM disk

Mender Server --HTTPS/outbound polling--> Mender client
                                             |
                                      inactive rootfs write
                                             |
                                      U-Boot trial boot
                                     /                 \
                              health passes        health fails
                              commit slot          rollback slot
```

The VM ISO/QCOW2 target deliberately excludes Mender A/B. Backend OTA is a Pi
feature; live ISO media has no safe inactive slot or persistent device identity.

## Raspberry Pi storage layout

Every factory image contains:

1. FAT boot partition with Raspberry Pi firmware, U-Boot, kernel and DTB.
2. Root filesystem A.
3. Root filesystem B.
4. Persistent data partition mounted at `/data`.

Mender writes a new full root filesystem only to the inactive slot. U-Boot
trial-boots that slot. `ArtifactCommit_Enter_50_cosmopod-health` requires 120
continuous seconds of healthy services, writable data, valid SSH configuration,
and a Wayland socket. Success commits the new slot;
failure makes Mender roll back to the prior slot.

The ordinary rootfs update does not safely replace all shared Raspberry Pi boot
firmware or every DTB. Those components need a separately designed recovery
and qualification path. See [Update system](UPDATE-SYSTEM.md).

## Persistent state

Rootfs partitions are replaceable. Mutable identity and user state therefore
live under `/data/cosmopod`:

```text
/data/cosmopod/home       cosmopod user's home, bind-mounted at boot
/data/cosmopod/network    NetworkManager profiles, bind-mounted at boot
/data/cosmopod/ssh        stable SSH host keys
/data/cosmopod/hostname   configured hostname
/data/cosmopod/wifi-country  regulatory country reapplied at every boot
/data/mender              Mender identity, state and persistent config
```

`cosmopod-persist.service` runs after `data.mount` and before NetworkManager,
sshd, Weston, and provisioning. This prevents regenerated SSH identities and
lost network settings after an A/B update.

## Trust boundaries

- Factory image trusts the public artifact verification key compiled into it.
- Private artifact signing key stays outside Git and outside the backend.
- Mender Server selects devices/releases but cannot make a client accept an
  unsigned or incorrectly signed artifact.
- SSH accepts only public keys for non-root user `cosmopod`.
- Backend transport must use HTTPS in production.
- Raspberry Pi boot chain is not secure boot by default; physical media access
  remains a separate threat.

## Board support

Pi 4 and Pi 5 use separate KAS files and Mender device types:
`cosmopod-rpi4-64` and `cosmopod-rpi5`, respectively. Pi 5 includes the Yocto
LTS mixins and different U-Boot/kernel settings. Never deploy a Pi 4 artifact
to Pi 5 or vice versa.
