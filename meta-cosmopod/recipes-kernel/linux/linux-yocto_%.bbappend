FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# The generic x86 Yocto baseline disables all hypervisor-guest support. Keep
# the exact Hyper-V and common virtual-display drivers built in so live ISO
# media has graphics, keyboard, mouse, storage, and network before any module
# filesystem is available.
SRC_URI:append:genericx86-64 = " file://cosmopod-hyperv.cfg"

# Follow the kernel revision selected by the pinned Yocto 6.0 LTS metadata.
# The local fragment adds only the VM guest drivers Cosmopod needs.
