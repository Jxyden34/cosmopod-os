FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# virglrenderer carries an older Mesa C11 shim; patch only the host build.
SRC_URI:append:class-native = " file://0001-c11-use-glibc-once-flag.patch"
