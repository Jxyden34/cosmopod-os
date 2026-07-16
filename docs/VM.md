# Virtual machines

The `vm` target builds the same Cosmopod Wayland userspace for x86-64:

```powershell
.\scripts\build.ps1 -Board vm -Version 0.1.0
```

Outputs:

- `Cosmopod-OS-0.1.0-vm-x86_64.iso`: hybrid BIOS/UEFI live media.
- `Cosmopod-OS-0.1.0-vm-x86_64.qcow2`: persistent EFI disk for QEMU,
  libvirt, UTM, or conversion to another hypervisor format.

Use at least 4 GB RAM, two virtual CPUs, a compatible virtual GPU, and one
network adapter. Secure Boot must be disabled because version 0.1.0 does not
ship a Microsoft-signed EFI chain.

The generic x86-64 build targets the Core 2 instruction baseline. QEMU's old
default `qemu64` model is too small and caused invalid-opcode failures during
testing. Use `-cpu host` with hardware acceleration or `-cpu max` with TCG.
The tested QCOW2 UEFI path used EDK2 code and variable images as pflash drives;
passing the code image through QEMU's simple `-bios` option did not boot this
disk.

The ISO is ephemeral: `/data` uses tmpfs and changes disappear after shutdown.
The QCOW2 disk has a persistent `cosmopod-data` partition. Neither VM format
uses Raspberry Pi Mender A/B OTA; backend updates are Pi-only.

## First VM login and SSH

Weston starts the locked `cosmopod` account directly on the virtual console.
There is no password. Open a local terminal and add an SSH key:

```sh
install -d -m 0700 ~/.ssh
printf '%s\n' 'ssh-ed25519 AAAA... replace-with-your-real-key' > ~/.ssh/authorized_keys
chmod 0600 ~/.ssh/authorized_keys
```

Do this on QCOW2 for persistence. The live ISO cannot consume a mutable
`cosmopod.conf` file from its read-only ISO filesystem and deliberately leaves
remote SSH unavailable until a valid key is added locally.

To use Hyper-V, convert a copy with a trusted `qemu-img` installation:

```sh
qemu-img convert -p -f qcow2 -O vhdx Cosmopod-OS-0.1.0-vm-x86_64.qcow2 Cosmopod-OS-0.1.0-vm-x86_64.vhdx
```

Keep the original checksum and verify the converted disk in an isolated VM
before using it for important data.

## Version 0.1.0 VM evidence

Snapshot-mode QEMU testing reached serial login from both media types. QCOW2
mounted its ext4 root and `cosmopod-data` partitions read-write and activated
swap. The live ISO reached multi-user and graphical targets with tmpfs `/data`,
NetworkManager, provisioning, and OpenSSH active. Remaining qualification item:
Weston failed under the last tested virtio-vga run. The current rebuild exposes
its fatal log on the console and must be booted again before claiming a working
VM desktop.
