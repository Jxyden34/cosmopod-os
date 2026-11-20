# Backport OE-Core bcc4b3f473fdd944ccb9c57bbdd104f71d04f7d7 to Wrynose.
require recipes-core/zlib/zlib_1.3.2.bb

FILESEXTRAPATHS:prepend := "${COREBASE}/meta/recipes-core/zlib/zlib:"
SRC_URI[sha256sum] = "02dd159783677a749c04adbdd02b55b8a2bcc7e054f51b76b549199a916ad584"
LDFLAGS:remove = "-fuse-ld=bfd"
