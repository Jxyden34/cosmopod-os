# The upstream install target launches multiple `install -D` processes for
# files in the same new directory. Under pseudo these can race: one process
# creates ${D}${sbindir} while the other reports that it cannot create it.
PARALLEL_MAKEINST = ""
