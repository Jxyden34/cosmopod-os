# Upstream rsync 3.5.0 security release; retain the existing product features.
PV = "3.5.0"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:remove = " \
    file://CVE-2025-10158.patch \
    file://0001-Add-missing-prototypes-to-function-declarations.patch \
"
SRC_URI:append = " file://0001-Add-missing-prototypes-to-function-declarations.patch"
SRC_URI[sha256sum] = "c7ffd1ef653e99540f661e47cb00b7f9cad1ee6b972399b16f93d672656e0d33"
