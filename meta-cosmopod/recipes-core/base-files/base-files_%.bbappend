FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

do_install:append() {
    install -m 0644 ${WORKDIR}/issue ${D}${sysconfdir}/issue
    install -m 0644 ${WORKDIR}/motd ${D}${sysconfdir}/motd
}
