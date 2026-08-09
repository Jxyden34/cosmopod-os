PV = "3.4.4"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:remove = " \
    file://CVE-2025-10158.patch \
    file://0001-Add-missing-prototypes-to-function-declarations.patch \
"
SRC_URI:append = " file://0001-Add-missing-prototypes-to-function-declarations.patch"
SRC_URI[sha256sum] = "bd88cf82fa653da32314fb229136407c5c90f80d1758d8f4b091767877d8fa96"
