# Backport the upstream OpenEmbedded-Core curl 8.22.0 security release to the
# otherwise frozen wrynose layer set.  The source checksum and the retired
# patches were retired by OE-Core commit 6ec500cd5a (8.21.0).
# The 8.22.0 checksum is from 4f88e807de169e2b5c67ab2fb219d7011a19d69a.
#
# Keep the existing package configuration for this release: changing feature
# selection at the same time as a security update would make the CVE evidence
# harder to compare and could silently alter the product surface.
PV = "8.22.0"
SRC_URI:remove = " \
    file://no-test-timeout.patch \
    file://CVE-2026-6276.patch \
    file://CVE-2026-5773.patch \
    file://mbedtls.patch \
    file://CVE-2026-5545.patch \
    file://CVE-2026-6253.patch \
    file://CVE-2026-6429-dependent.patch \
    file://CVE-2026-6429.patch \
    file://CVE-2026-7168.patch \
"
SRC_URI[sha256sum] = "f7ef3ae8a22e521f289803fe93543eb64c329b58aa73a9e224dfd915a2a5f4f7"

# curl 8.21 removed librtmp support and its configure switch.  Retain the
# previous product feature set by removing the now-invalid disabled switch.
EXTRA_OECONF:remove = "--without-librtmp"
