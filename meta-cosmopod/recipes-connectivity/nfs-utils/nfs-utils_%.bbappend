# nfs-utils installs this mount into sysinit.target even when its server is
# disabled. Keep unit available for deliberate nfs-server use, but do not
# mount NFSD on every Cosmopod boot.
do_install:append() {
    rm -f ${D}${systemd_system_unitdir}/sysinit.target.wants/proc-fs-nfsd.mount
}
