SUMMARY = "Cosmopod OS VM data-volume setup"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://cosmopod-vm-data \
    file://cosmopod-vm-data.service \
    file://cosmopod-persist-vm.conf \
    file://cosmopod-vm-remount-condition \
    file://cosmopod-remount-vm.conf \
    file://cosmopod-weston-vm.conf \
    file://cosmopod-vm-smoke-condition \
    file://cosmopod-vm-smoke \
    file://cosmopod-vm-smoke.service \
"

inherit systemd

SYSTEMD_SERVICE:${PN} = "cosmopod-vm-data.service cosmopod-vm-smoke.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} += "util-linux util-linux-blkid util-linux-mount"

do_install() {
    # Live ISO root is read-only, so its tmpfs mount point must exist in the
    # built root filesystem before cosmopod-vm-data.service starts.
    install -d -m 0755 ${D}/data
    install -d ${D}${libexecdir}
    install -m 0755 ${WORKDIR}/cosmopod-vm-data ${D}${libexecdir}/
    install -m 0755 ${WORKDIR}/cosmopod-vm-remount-condition ${D}${libexecdir}/
    install -m 0755 ${WORKDIR}/cosmopod-vm-smoke-condition ${D}${libexecdir}/
    install -m 0755 ${WORKDIR}/cosmopod-vm-smoke ${D}${libexecdir}/

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/cosmopod-vm-data.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/cosmopod-vm-smoke.service ${D}${systemd_system_unitdir}/

    install -d ${D}${sysconfdir}/systemd/system/cosmopod-persist.service.d
    install -m 0644 ${WORKDIR}/cosmopod-persist-vm.conf \
        ${D}${sysconfdir}/systemd/system/cosmopod-persist.service.d/vm.conf

    install -d ${D}${sysconfdir}/systemd/system/systemd-remount-fs.service.d
    install -m 0644 ${WORKDIR}/cosmopod-remount-vm.conf \
        ${D}${sysconfdir}/systemd/system/systemd-remount-fs.service.d/cosmopod-vm.conf

    install -d ${D}${sysconfdir}/systemd/system/weston.service.d
    install -m 0644 ${WORKDIR}/cosmopod-weston-vm.conf \
        ${D}${sysconfdir}/systemd/system/weston.service.d/vm.conf
}

FILES:${PN} += " \
    /data \
    ${sysconfdir}/systemd/system/cosmopod-persist.service.d \
    ${sysconfdir}/systemd/system/systemd-remount-fs.service.d \
    ${sysconfdir}/systemd/system/weston.service.d \
"
