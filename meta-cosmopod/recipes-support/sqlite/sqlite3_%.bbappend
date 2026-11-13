# Update SQLite while retaining the existing recipe's feature configuration.
PV = "3.54.1"
SRC_URI:remove = "file://CVE-2026-11822_CVE-2026-11824.patch"
SRC_URI[sha256sum] = "926ef8d3eab93fbf6e06011901273eec076b25594a4e1cdadd50c987f4f6d64e"
