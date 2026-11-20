# OpenEmbedded-Core 11ae01ba0d705f5b7e450eef0e25ecccb71723f0.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://CVE-2026-82474-dependent_p1.patch \
    file://CVE-2026-82474-dependent_p2.patch \
    file://CVE-2026-82474.patch \
    file://CVE-2026-82474-regression_p1.patch \
    file://CVE-2026-82474-regression_p2.patch \
"
