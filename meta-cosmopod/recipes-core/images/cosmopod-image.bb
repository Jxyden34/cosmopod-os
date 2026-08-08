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
    cosmopod-branding \
    cosmopod-config \
"

IMAGE_LINGUAS = "en-gb"

# Account has no password. SSH accepts public keys only. Physical Wayland
# session starts as this user. Sudo policy is installed by cosmopod-config.
EXTRA_USERS_PARAMS = " \
    groupadd -f wheel; \
    useradd -u 1000 -m -d /home/cosmopod -s /bin/bash -G wheel,audio,video,input,render,seat,wayland,dialout cosmopod; \
    usermod -L root; \
    usermod -L cosmopod; \
"

# Put provisioning template on FAT boot partition visible after flashing.
IMAGE_BOOT_FILES:append = " cosmopod.conf.example"
do_image_bootimg[depends] += "cosmopod-config:do_deploy"

# Yocto's live init copies the optical-media mount below /media after
# switching to the read-only rootfs. Package QA deliberately reserves
# /media, so create this mount point during x86 VM image assembly.
ROOTFS_POSTPROCESS_COMMAND:append:genericx86-64 = " cosmopod_vm_live_mountpoints;"
cosmopod_vm_live_mountpoints() {
    install -d -m 0755 ${IMAGE_ROOTFS}/media/boot-sr0
}

# The database updater can invalidate do_sbom_cve_check without invalidating
# do_create_image_sbom_spdx. Materialize the new timestamped input name from
# the stable deploy link before the inherited scanner task runs.
python do_sbom_cve_check:prepend() {
    import os

    deploy_dir = os.path.realpath(d.getVar("DEPLOY_DIR_IMAGE"))
    stable_path = d.expand("${DEPLOY_DIR_IMAGE}/${IMAGE_LINK_NAME}.spdx.json")
    timestamped_path = d.expand("${DEPLOY_DIR_IMAGE}/${IMAGE_NAME}.spdx.json")
    stable_target = os.path.realpath(stable_path)
    if not os.path.isfile(stable_target) or os.path.dirname(stable_target) != deploy_dir:
        bb.fatal("Stable SPDX input is missing or resolves outside DEPLOY_DIR_IMAGE")
    if os.path.lexists(timestamped_path):
        if os.path.realpath(timestamped_path) != stable_target:
            bb.fatal("Timestamped SPDX input does not match the stable deploy link")
    else:
        os.symlink(os.path.basename(stable_target), timestamped_path)
}
