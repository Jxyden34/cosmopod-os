SUMMARY = "Cosmopod OS runtime configuration and first-boot provisioning"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://cosmopod-firstboot.py \
    file://cosmopod-firstboot.service \
    file://cosmopod-persist.sh \
    file://cosmopod-persist.service \
    file://cosmopod.conf.example \
    file://50-cosmopod-sshd.conf \
    file://cosmopod-sudoers \
    file://cosmopod-profile \
    file://cosmopod-readme.txt \
    file://ArtifactCommit_Enter_50_cosmopod-health \
"

inherit systemd mender-state-scripts

SYSTEMD_SERVICE:${PN} = "cosmopod-persist.service cosmopod-firstboot.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} += " \
    bash \
    coreutils \
    networkmanager-nmcli \
    openssh-keygen \
    python3-core \
    util-linux \
"

do_install() {
    install -d ${D}${libexecdir}
    install -m 0755 ${WORKDIR}/cosmopod-firstboot.py ${D}${libexecdir}/cosmopod-firstboot
    install -m 0755 ${WORKDIR}/cosmopod-persist.sh ${D}${libexecdir}/cosmopod-persist

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/cosmopod-firstboot.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/cosmopod-persist.service ${D}${systemd_system_unitdir}/

    install -d ${D}${sysconfdir}/ssh/sshd_config.d
    install -m 0600 ${WORKDIR}/50-cosmopod-sshd.conf ${D}${sysconfdir}/ssh/sshd_config.d/

    install -d ${D}${sysconfdir}/sudoers.d
    install -m 0440 ${WORKDIR}/cosmopod-sudoers ${D}${sysconfdir}/sudoers.d/cosmopod

    install -d ${D}${sysconfdir}/systemd/system/NetworkManager.service.d
    cat > ${D}${sysconfdir}/systemd/system/NetworkManager.service.d/cosmopod.conf <<'EOF'
[Unit]
Requires=cosmopod-persist.service
After=cosmopod-persist.service
EOF

    install -d ${D}${sysconfdir}/systemd/system/sshd.service.d
    cat > ${D}${sysconfdir}/systemd/system/sshd.service.d/cosmopod.conf <<'EOF'
[Unit]
Requires=cosmopod-persist.service
After=cosmopod-persist.service
EOF

    install -d ${D}${sysconfdir}/systemd/system/weston.service.d
    cat > ${D}${sysconfdir}/systemd/system/weston.service.d/cosmopod.conf <<'EOF'
[Unit]
Requires=cosmopod-persist.service
After=cosmopod-persist.service

[Service]
User=cosmopod
Group=cosmopod
WorkingDirectory=/home/cosmopod
EOF

    for unit in mender-authd.service mender-updated.service; do
        install -d ${D}${sysconfdir}/systemd/system/$unit.d
        cat > ${D}${sysconfdir}/systemd/system/$unit.d/cosmopod.conf <<'EOF'
[Unit]
Wants=cosmopod-firstboot.service
After=cosmopod-firstboot.service
EOF
    done

    install -d ${D}${datadir}/cosmopod/home-seed
    install -m 0644 ${WORKDIR}/cosmopod-profile ${D}${datadir}/cosmopod/home-seed/.profile
    install -m 0644 ${WORKDIR}/cosmopod-readme.txt ${D}${datadir}/cosmopod/home-seed/README.txt

}

do_compile() {
    install -m 0755 ${WORKDIR}/ArtifactCommit_Enter_50_cosmopod-health \
        ${MENDER_STATE_SCRIPTS_DIR}/ArtifactCommit_Enter_50_cosmopod-health
}

do_deploy() {
    install -d ${DEPLOYDIR}
    install -m 0644 ${WORKDIR}/cosmopod.conf.example ${DEPLOYDIR}/cosmopod.conf.example
}
addtask deploy after do_compile before do_build

FILES:${PN} += " \
    ${libexecdir}/cosmopod-firstboot \
    ${libexecdir}/cosmopod-persist \
    ${sysconfdir}/systemd/system \
    ${datadir}/cosmopod \
"

CONFFILES:${PN} += " \
    ${sysconfdir}/ssh/sshd_config.d/50-cosmopod-sshd.conf \
    ${sysconfdir}/sudoers.d/cosmopod \
"
