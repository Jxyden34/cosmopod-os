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
    acl \
    at \
    attr \
    avahi-daemon \
    avahi-utils \
    bc \
    bluez5 \
    bzip2 \
    cmake \
    cpio \
    cronie \
    diffutils \
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
    gzip \
    htop \
    i2c-tools \
    iw \
    kmod \
    less \
    libgpiod-tools \
    logrotate \
    lsof \
    m4 \
    make \
    nano \
    net-tools \
    nfs-utils \
    nmap \
    patch \
    parted \
    pciutils \
    pkgconfig \
    psmisc \
    python3 \
    python3-modules \
    python3-pip \
    rfkill \
    rpcbind \
    rsync \
    sed \
    shadow \
    strace \
    tar \
    tcpdump \
    time \
    tmux \
    tree \
    usbutils \
    vim \
"
