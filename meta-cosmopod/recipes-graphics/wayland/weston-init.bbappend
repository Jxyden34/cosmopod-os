FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://weston.ini"
PACKAGECONFIG:append = " headless"

# Upstream creates a normal Weston user, which can consume UID 1000 before the
# image creates the interactive Cosmopod account. Weston itself runs as
# `cosmopod`; retain this package account only as a locked system user.
USERADD_PARAM:${PN} = "--system --home /home/weston --shell /sbin/nologin --user-group -G video,input,render,seat,wayland weston"

do_install:append() {
    install -m 0644 ${UNPACKDIR}/weston.ini ${D}${sysconfdir}/xdg/weston/weston.ini
}
