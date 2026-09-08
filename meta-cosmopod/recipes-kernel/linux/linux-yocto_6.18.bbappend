# Use the matched stable kernel/cache pair from OE-Core
# 714654a1625f4f39a5c44c5ded9602d75b6cb6c8 until the pinned baseline catches up.
# Preserve the shared Hyper-V fragment in linux-yocto_%.bbappend.
SRCREV_machine:genericx86-64 = "5b95344d2d0cfbe5889e3eb5a2ea3939dc3412f0"
SRCREV_meta:genericx86-64 = "185549fc38a492dc3e431b32ac6774620ae6b468"
LINUX_VERSION:genericx86-64 = "6.18.48"
