FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# The generic x86 Yocto baseline disables all hypervisor-guest support. Keep
# the exact Hyper-V and common virtual-display drivers built in so live ISO
# media has graphics, keyboard, mouse, storage, and network before any module
# filesystem is available.
SRC_URI:append:genericx86-64 = " file://cosmopod-hyperv.cfg"

# meta-yocto-bsp pins genericx86-64 to the original 6.6.21 revision even
# though the Scarthgap core recipe tracks the maintained 6.6.142 revision.
# Keep the generic VM BSP configuration while selecting that official current
# source revision and its matching version metadata.
SRCREV_machine:genericx86-64 = "a8a7d078f151a24e01d4501853c88c6b08c9cad9"
LINUX_VERSION:genericx86-64 = "6.6.142"
