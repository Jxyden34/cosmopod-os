# Yocto 5.0.19 provides Pseudo 1.9.8 with stable symlink and permission fixes,
# but its later full openat2 wrapper
# loses pipeline file descriptors on empty-path probes from glibc 2.43 tools.
# Route failed canonicalization through the wrapper, then return ENOSYS only
# for empty paths; normal file paths still use the complete wrapper.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://0001-openat2-fallback-to-enosys.patch"
