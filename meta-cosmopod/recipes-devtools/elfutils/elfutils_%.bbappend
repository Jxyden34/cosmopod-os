FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " \
    file://0001-riscv-disasm-keep-bsearch-result-const.patch \
    file://0002-libdw-keep-memchr-result-const.patch \
    file://0003-debuginfod-keep-strchr-result-const.patch \
    file://0004-readelf-keep-search-results-const.patch \
"
