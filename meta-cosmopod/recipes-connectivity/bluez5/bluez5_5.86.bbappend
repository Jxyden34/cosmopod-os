# The accepted Wrynose fix needs both parts, in this order.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://CVE-2026-19774_p1.patch \
    file://CVE-2026-19774_p2.patch \
"
