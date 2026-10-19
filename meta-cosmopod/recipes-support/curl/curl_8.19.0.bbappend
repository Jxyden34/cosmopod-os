# Backport curl 8.23.0 while Wrynose still carries the 8.19.0 recipe.
# The base recipe's CVE patches are included in this upstream release.
PV = "8.23.0"
SRC_URI = "https://curl.se/download/${BP}.tar.xz \
           file://run-ptest \
           file://disable-tests \
           "
SRC_URI[sha256sum] = "8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5"

# curl removed librtmp in 8.21 and SMB in 8.23.
EXTRA_OECONF:remove = "--without-librtmp"
PACKAGECONFIG[rtmpdump] = ",,,"
PACKAGECONFIG[smb] = ",,,"
