# Kept in sync with OE-Core's 2.9.0 recipe until Wrynose carries it.
SUMMARY = "A stream-oriented XML parser library"
DESCRIPTION = "Expat is an XML parser library written in C. It is a stream-oriented parser in which an application registers handlers with the XML parser"
HOMEPAGE = "https://github.com/libexpat/libexpat"
SECTION = "libs"
LICENSE = "MIT"

LIC_FILES_CHKSUM = "file://COPYING;md5=f4fedd6116da0e171f7cb4d2923d7ac2"

VERSION_TAG = "${@d.getVar('PV').replace('.', '_')}"
GITHUB_BASE_URI = "https://github.com/libexpat/libexpat/releases/"
SRC_URI = "${GITHUB_BASE_URI}/download/R_${VERSION_TAG}/expat-${PV}.tar.bz2 \
           file://run-ptest \
           file://CVE-2026-115506.patch;striplevel=2 \
           file://CVE-2026-113351.patch;striplevel=2 \
           "
SRC_URI[sha256sum] = "775e8a68f81a748a401dc3168318d4a39484eb4f954726f21517c8f42c0ba984"
UPSTREAM_CHECK_REGEX = "releases/tag/R_(?P<pver>.+)"

EXTRA_OECMAKE:class-native += "-DEXPAT_BUILD_DOCS=OFF"
RDEPENDS:${PN}-ptest += "bash"

inherit cmake lib_package ptest github-releases

do_install_ptest:class-target() {
    install -m 755 ${B}/tests/runtests* ${D}${PTEST_PATH}
    install -m 755 ${B}/tests/benchmark/benchmark ${D}${PTEST_PATH}
}

BBCLASSEXTEND += "native nativesdk"
CVE_PRODUCT = "expat libexpat"
