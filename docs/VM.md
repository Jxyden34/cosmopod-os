# Virtual machines

The `vm` target builds the same Cosmopod Wayland userspace for x86-64:

```powershell
.\scripts\build.ps1 -Board vm -Version 0.1.0
```

Outputs:

- `Cosmopod-OS-0.1.0-vm-x86_64.iso`: hybrid BIOS/UEFI live media.
- `Cosmopod-OS-0.1.0-vm-x86_64.iso.xz`: compressed GitHub Release download;
  decompress it to recover the byte-identical ISO.
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

## Automated smoke test

After building fresh VM media, run both isolated QEMU checks from Windows:

```powershell
.\scripts\smoke-vm.ps1 -Media all -Channel development -Version 0.23.0
```

Use `-Channel release` for release output. `-Channel auto` works only when
exactly one channel directory exists, preventing accidental testing of stale
media when both builds are present.

The test uses TCG with `-cpu max`, a loopback-only VNC display, restricted
user-mode networking, one temporary loopback-only SSH forward, and a temporary
QCOW2 overlay. The QCOW2 check boots that same disposable overlay twice. The
guest cannot use this network for external traffic. The test never modifies the
release disk or OVMF variables template. A fixed guest
reporter activates only when QEMU supplies one of two exact SMBIOS test
markers; it accepts no host commands or interactive login.

The reporter checks OS identity, root/data mount policy, persistent bind
mounts, swap layout, NetworkManager, key-only `sshd`, port 22, systemd health,
DRM connector/mode state, the UID 1000 Weston process, and a real
`wayland-info` client connection. It rechecks Weston after a stability window
and captures Weston's service state and journal before powering off. Host-side
`ssh-keyscan` proves loopback reachability and matches server fingerprints to
the guest's persistent host keys; it does not claim user authentication. The
second QCOW2 boot must recover both a `/data` sentinel and the exact same two
SSH host-key fingerprints. QMP also records a dimension-checked, non-uniform
PPM screen image. Raw/normalized serial, QEMU, Weston, SSH, screen, TAP, and
checksum evidence is written below
`out/<version>/vm-<channel>/smoke/`.

Current 0.1.0 artifacts predate this reporter. Rebuild them before running this
command; a timeout against the older media is expected and is not a pass.

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
Weston failed under the last tested virtio-vga run. Current source selects
Weston's Pixman software renderer and builds Hyper-V DRM/input/network/storage
drivers plus common virtual-display drivers into the VM kernel. The media exposes
its fatal log on the console. Source now also contains a non-interactive smoke
reporter and host runner, but the media must be rebuilt and pass that runner
before claiming a working VM desktop.
