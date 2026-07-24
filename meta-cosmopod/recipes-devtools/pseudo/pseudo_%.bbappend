# Yocto 5.0.17 pins pseudo before its openat2 support. Pseudo 1.9.8 provides
# the stable symlink and permission fixes, but the later full openat2 wrapper
# loses pipeline file descriptors on empty-path probes from glibc 2.43 tools.
# Route failed canonicalization through the wrapper, then return ENOSYS only
# for empty paths; normal file paths still use the complete wrapper.
PV = "1.9.8"
SRCREV = "823895ba708c63f6ae4dcbfc266210f26c02c698"

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://0001-openat2-fallback-to-enosys.patch"
