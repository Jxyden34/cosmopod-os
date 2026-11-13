# Upstream rsync 3.5.2 security release; retain the existing product features.
PV = "3.5.2"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:remove = " \
    file://CVE-2025-10158.patch \
    file://0001-Add-missing-prototypes-to-function-declarations.patch \
"
SRC_URI:append = " file://0001-Add-missing-prototypes-to-function-declarations.patch"
SRC_URI[sha256sum] = "a10d591825251e070f74c98df3daad195def4ed81b4a2de16169026aea33f6c8"
