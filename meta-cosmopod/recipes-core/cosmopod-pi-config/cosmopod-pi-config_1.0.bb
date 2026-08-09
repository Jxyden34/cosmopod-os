SUMMARY = "Cosmopod OS Raspberry Pi hardware policy"
DESCRIPTION = "Raspberry Pi watchdog activation and hardware identity marker"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://60-cosmopod-watchdog.conf"

do_install() {
    install -d ${D}${sysconfdir}/systemd/system.conf.d
    install -m 0644 ${UNPACKDIR}/60-cosmopod-watchdog.conf \
        ${D}${sysconfdir}/systemd/system.conf.d/60-cosmopod-watchdog.conf

    install -d ${D}${datadir}/cosmopod
    printf 'raspberry-pi\n' > ${D}${datadir}/cosmopod/pi-hardware
}

FILES:${PN} += " \
    ${sysconfdir}/systemd/system.conf.d/60-cosmopod-watchdog.conf \
    ${datadir}/cosmopod/pi-hardware \
"

CONFFILES:${PN} += "${sysconfdir}/systemd/system.conf.d/60-cosmopod-watchdog.conf"
