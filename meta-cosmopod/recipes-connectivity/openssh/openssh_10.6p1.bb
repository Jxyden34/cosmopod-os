# Backport the upstream security release while Wrynose still ships 10.3p1.
# Reuse Wrynose packaging and configuration until its recipe catches up.
require recipes-connectivity/openssh/openssh_10.3p1.bb

FILESEXTRAPATHS:prepend := "${COREBASE}/meta/recipes-connectivity/openssh/openssh:"

# These fixes were incorporated into OpenSSH before 10.6p1.
SRC_URI:remove = "file://CVE-2026-59999.patch file://CVE-2026-59997.patch file://CVE-2026-59996.patch file://CVE-2026-59995.patch file://CVE-2026-60001.patch file://CVE-2026-60002.patch file://CVE-2026-60000.patch file://CVE-2026-73283.patch file://CVE-2026-73282.patch file://CVE-2026-73281.patch"
SRC_URI[sha256sum] = "a9dc9565dffe8640f64d863cd29a32bc4a3dbdec0566a7fc44c5d6ee767d5f39"
