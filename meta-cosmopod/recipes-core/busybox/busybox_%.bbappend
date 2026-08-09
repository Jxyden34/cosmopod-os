FILESEXTRAPATHS:prepend := "${THISDIR}/busybox:"

# Align BusyBox with the current upstream security maintenance release.
PV = "1.38.0"
SRC_URI[tarball.sha256sum] = "34f9ea6ff8636f2c9241153b9114eefa9e65674a45318ae1ef95bb5f31c53bb2"

# These patches are incorporated by the 1.38.0 source release or superseded
# by the retained upstream backport below.
SRC_URI:remove = " \
    file://0001-cut-Fix-s-flag-to-omit-blank-lines.patch \
    file://0001-archival-disallow-path-traversals-CVE-2023-39810.patch \
    file://CVE-2025-46394-01.patch \
    file://CVE-2025-46394-02.patch \
    file://0001-tar-strip-unsafe-hardlink-components-GNU-tar-does-th.patch \
    file://0002-tar-only-strip-unsafe-components-from-hardlinks-not-.patch \
    file://CVE-2026-29004-01.patch \
    file://CVE-2026-29004-02.patch \
    "

SRC_URI:append = " file://CVE-2026-38754.patch"
