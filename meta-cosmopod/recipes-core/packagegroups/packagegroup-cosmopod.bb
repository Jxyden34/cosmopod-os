SUMMARY = "Cosmopod OS package groups"
LICENSE = "MIT"

inherit packagegroup

PACKAGES = " \
    packagegroup-cosmopod-base \
    packagegroup-cosmopod-wayland \
    packagegroup-cosmopod-tools \
"

RDEPENDS:packagegroup-cosmopod-base = " \
    bash \
    bash-completion \
    ca-certificates \
    chrony \
    coreutils \
    curl \
    ethtool \
    iproute2 \
    iputils \
    jq \
    networkmanager \
    networkmanager-nmcli \
    nftables \
    openssh \
    openssh-sftp-server \
    openssl \
    procps \
    sudo \
    tzdata \
    util-linux \
    wget \
    wireless-regdb-static \
    wpa-supplicant \
"

RDEPENDS:packagegroup-cosmopod-wayland = " \
    alsa-utils \
    packagegroup-core-weston \
    wayland-utils \
    weston \
    weston-examples \
    weston-init \
"

RDEPENDS:packagegroup-cosmopod-tools = " \
    avahi-daemon \
    avahi-utils \
    bluez5 \
    cmake \
    dosfstools \
    e2fsprogs \
    e2fsprogs-resize2fs \
    file \
    findutils \
    g++ \
    gawk \
    gcc \
    git \
    grep \
    htop \
    i2c-tools \
    iw \
    less \
    libgpiod-tools \
    lsof \
    make \
    nano \
    nmap \
    packagegroup-core-full-cmdline \
    parted \
    pciutils \
    pkgconfig \
    python3 \
    python3-modules \
    python3-pip \
    rfkill \
    rsync \
    sed \
    strace \
    tcpdump \
    tmux \
    tree \
    usbutils \
    vim \
"
