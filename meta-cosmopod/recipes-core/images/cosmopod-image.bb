SUMMARY = "Cosmopod OS image for Raspberry Pi"
DESCRIPTION = "Wayland-first Raspberry Pi Linux image with SSH and robust A/B OTA updates"
LICENSE = "MIT"

inherit core-image extrausers

IMAGE_FEATURES += "ssh-server-openssh"

IMAGE_INSTALL += " \
    packagegroup-core-boot \
    packagegroup-cosmopod-base \
    packagegroup-cosmopod-wayland \
    packagegroup-cosmopod-tools \
    cosmopod-config \
"

IMAGE_LINGUAS = "en-gb"

# Account has no password. SSH accepts public keys only. Physical Wayland
# session starts as this user. Sudo policy is installed by cosmopod-config.
EXTRA_USERS_PARAMS = " \
    groupadd -f wheel; \
    useradd -u 1000 -m -d /home/cosmopod -s /bin/bash -G wheel,audio,video,input,render,wayland,dialout cosmopod; \
    usermod -L root; \
    usermod -L cosmopod; \
"

# Put provisioning template on FAT boot partition visible after flashing.
IMAGE_BOOT_FILES:append = " cosmopod.conf.example"
do_image_bootimg[depends] += "cosmopod-config:do_deploy"
