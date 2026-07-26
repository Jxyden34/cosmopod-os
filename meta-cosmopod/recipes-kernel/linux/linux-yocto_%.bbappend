FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# The generic x86 Yocto baseline disables all hypervisor-guest support. Keep
# the exact Hyper-V and common virtual-display drivers built in so live ISO
# media has graphics, keyboard, mouse, storage, and network before any module
# filesystem is available.
SRC_URI:append:genericx86-64 = " file://cosmopod-hyperv.cfg"

# meta-yocto-bsp pins genericx86-64 to the original 6.6.21 revision even
# though the Scarthgap core recipe tracks the maintained 6.6.127 revision.
# Keep the generic VM BSP configuration while selecting that official current
# source revision and its matching version metadata.
SRCREV_machine:genericx86-64 = "70af2998be31b72a111de67966b7816b3d54d472"
LINUX_VERSION:genericx86-64 = "6.6.127"
