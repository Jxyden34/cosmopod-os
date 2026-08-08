# Backport the upstream OpenEmbedded-Core curl 8.21.0 security release to the
# otherwise frozen wrynose layer set.  The source checksum and the retired
# patches are from OE-Core commit 6ec500cd5a (curl: update 8.20.0 -> 8.21.0),
# as included by the reviewed upstream snapshot 20f678d825d1b8a1e8bfa88dedd51eb628c96d51.
#
# Keep the existing package configuration for this release: changing feature
# selection at the same time as a security update would make the CVE evidence
# harder to compare and could silently alter the product surface.
PV = "8.21.0"
SRC_URI:remove = " \
    file://CVE-2026-6276.patch \
    file://CVE-2026-5773.patch \
    file://mbedtls.patch \
    file://CVE-2026-5545.patch \
    file://CVE-2026-6253.patch \
    file://CVE-2026-6429-dependent.patch \
    file://CVE-2026-6429.patch \
    file://CVE-2026-7168.patch \
"
SRC_URI[sha256sum] = "aa1b66a70eace83dc624508745646c08ae561de512ab403adffb93ac87fc72e6"
