FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://0001-libfdt-keep-memchr-results-const.patch \
    file://0002-fdtput-mark-create-node-input-mutable.patch \
"
