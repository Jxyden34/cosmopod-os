# OpenSSL 3.5 stable fixes published in the November 10 and 17 advisories.
# Drop after moving to the signed 3.5.10 release or later.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://CVE-2026-88823.patch \
    file://CVE-2026-88822.patch \
    file://CVE-2026-107496.patch \
    file://CVE-2026-95692.patch \
    file://CVE-2026-95691.patch \
    file://CVE-2026-107493.patch \
    file://CVE-2026-35190.patch \
    file://CVE-2026-124709.patch \
"
