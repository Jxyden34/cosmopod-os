FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Yocto's native update-alternatives helper runs while pseudo tracks rootfs
# writes. Avoid its tail pipeline, which loses standard input on newer hosts.
SRC_URI:append:class-native = " file://0001-update-alternatives-avoid-tail-pipeline.patch"
