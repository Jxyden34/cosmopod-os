FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Backport the upstream fix needed when native tools build on glibc 2.43+.
SRC_URI:append:class-native = " file://0001-c11-threads-fix-build-on-c23.patch"
