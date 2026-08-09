SUMMARY = "Cosmopod OS desktop branding"
DESCRIPTION = "Official Cosmopod logo for the Weston desktop background"
LICENSE = "CLOSED"

SRC_URI = "file://cosmopod-logo.png"

do_install() {
    install -d ${D}${datadir}/backgrounds
    install -m 0644 ${UNPACKDIR}/cosmopod-logo.png \
        ${D}${datadir}/backgrounds/cosmopod-logo.png
}

FILES:${PN} = "${datadir}/backgrounds/cosmopod-logo.png"
