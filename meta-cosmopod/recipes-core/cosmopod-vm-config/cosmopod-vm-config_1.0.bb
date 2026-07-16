SUMMARY = "Cosmopod OS VM data-volume setup"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://cosmopod-vm-data \
    file://cosmopod-vm-data.service \
    file://cosmopod-persist-vm.conf \
"

inherit systemd

SYSTEMD_SERVICE:${PN} = "cosmopod-vm-data.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} += "util-linux util-linux-blkid util-linux-mount"

do_install() {
    install -d ${D}${libexecdir}
    install -m 0755 ${WORKDIR}/cosmopod-vm-data ${D}${libexecdir}/

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/cosmopod-vm-data.service ${D}${systemd_system_unitdir}/

    install -d ${D}${sysconfdir}/systemd/system/cosmopod-persist.service.d
    install -m 0644 ${WORKDIR}/cosmopod-persist-vm.conf \
        ${D}${sysconfdir}/systemd/system/cosmopod-persist.service.d/vm.conf
}

FILES:${PN} += "${sysconfdir}/systemd/system/cosmopod-persist.service.d"
