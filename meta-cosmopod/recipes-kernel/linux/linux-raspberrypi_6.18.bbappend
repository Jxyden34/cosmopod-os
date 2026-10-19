# Pin the Raspberry Pi 6.18.y security update. Keep the metadata branch
# aligned with the 6.18 kernel series used by meta-raspberrypi.
SRCREV_machine = "5d64d1ea73716526ed9c0ed184a9cb5f6042e32c"
SRCREV_meta = "5978c5f530b91cfb62213506ee6f157897432ba3"
LINUX_VERSION = "6.18.57"

# linux-raspberrypi loads linux-yocto.inc, but not the 6.18 recipe's
# reviewed upstream kernel CVE dispositions. All fixed-version entries in
# the pinned OE-Core file are at or below our 6.18 kernel version.
require recipes-kernel/linux/cve-exclusion.inc
