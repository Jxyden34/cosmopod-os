#!/usr/bin/env bash
set -Eeuo pipefail

KAS_VERSION=4.8.1
YOCTO_VERSION=5.0.15
GNU_COREUTILS_VERSION=9.7-3ubuntu2
GNU_COREUTILS_SHA256=6b5b60a5c372b6e9d1dcfa1507317aae59bf809d4f4d6d363d3ef0a58a189137
GNU_COREUTILS_URL="https://archive.ubuntu.com/ubuntu/pool/main/c/coreutils/gnu-coreutils_${GNU_COREUTILS_VERSION}_amd64.deb"
board=pi4
version=
action=build
engine=auto
bb_threads=${COSMOPOD_BB_NUMBER_THREADS:-6}
make_jobs=${COSMOPOD_PARALLEL_MAKE_JOBS:-6}

usage() {
    cat <<'EOF'
Usage: scripts/build.sh [--build|--checkout-only] [--engine auto|native|container]
                        --board pi4|pi5|vm --version VERSION

Auto uses the kas container when Docker is available, otherwise it installs the
official Yocto buildtools in the user cache and builds without root privileges.
Source under /mnt is synced to native WSL storage first.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build) action=build ;;
        --checkout-only) action=checkout ;;
        --engine) engine=${2:?missing engine}; shift ;;
        --board) board=${2:?missing board}; shift ;;
        --version) version=${2:?missing version}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[[ "$board" =~ ^(pi4|pi5|vm)$ ]] || { echo "Board must be pi4, pi5, or vm" >&2; exit 2; }
[[ "$engine" =~ ^(auto|native|container)$ ]] || {
    echo "Engine must be auto, native, or container" >&2
    exit 2
}
[[ "$bb_threads" =~ ^[1-9][0-9]?$ ]] || {
    echo "COSMOPOD_BB_NUMBER_THREADS must be 1-99" >&2
    exit 2
}
[[ "$make_jobs" =~ ^[1-9][0-9]?$ ]] || {
    echo "COSMOPOD_PARALLEL_MAKE_JOBS must be 1-99" >&2
    exit 2
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
original_root=$(cd -- "$script_dir/.." && pwd)
if [[ -z "$version" ]]; then
    version=$(tr -d '[:space:]' < "$original_root/VERSION")
fi
[[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$ ]] || {
    echo "Invalid version: $version" >&2
    exit 2
}

cache_root=${COSMOPOD_BUILD_ROOT:-"$HOME/.cache/cosmopod-os"}
case "$cache_root" in
    "$HOME"/.cache/cosmopod-os|"$HOME"/.cache/cosmopod-os/*) ;;
    *) echo "COSMOPOD_BUILD_ROOT must stay under $HOME/.cache/cosmopod-os" >&2; exit 2 ;;
esac

mkdir -p "$cache_root"
if [[ "$original_root" == /mnt/* ]]; then
    command -v rsync >/dev/null || { echo "rsync is required" >&2; exit 1; }
    source_root="$cache_root/source"
    mkdir -p "$source_root"
    rsync -a --delete --delete-excluded \
        --exclude build --exclude 'build-*' --exclude out \
        --exclude secrets/ --exclude backend/.state/ --exclude backend/.runtime/ \
        "$original_root/" "$source_root/"
else
    source_root=$original_root
fi

git -C "$source_root" rev-parse --show-toplevel >/dev/null 2>&1 || {
    echo "Cosmopod source must be a Git repository before kas runs" >&2
    exit 1
}

if [[ "$engine" == auto ]]; then
    if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
        engine=container
    else
        engine=native
    fi
fi

tools_dir="$cache_root/tools"
work_dir="$cache_root/work-$board"
mkdir -p "$tools_dir" "$work_dir" "$cache_root/downloads" "$cache_root/sstate"

# Ubuntu 26.04 may provide `install` through uutils coreutils. Yocto 5.0's
# native recipes require GNU install semantics. Extract the signed Ubuntu
# archive package into the user cache rather than replacing essential host
# packages. The exact package payload is checksum pinned.
gnu_coreutils_bin=
host_install_version=$(install --version 2>&1 || true)
if [[ "$engine" == native && "$host_install_version" == *"uutils coreutils"* ]]; then
    [[ "$(uname -m)" == x86_64 ]] || {
        echo "uutils coreutils workaround currently supports x86_64 hosts only" >&2
        exit 1
    }
    command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
    command -v dpkg-deb >/dev/null || { echo "dpkg-deb is required" >&2; exit 1; }
    gnu_coreutils_root="$tools_dir/gnu-coreutils-$GNU_COREUTILS_VERSION"
    gnu_coreutils_deb="$tools_dir/gnu-coreutils-$GNU_COREUTILS_VERSION.deb"
    if [[ ! -f "$gnu_coreutils_deb" ]] || \
       ! printf '%s  %s\n' "$GNU_COREUTILS_SHA256" "$gnu_coreutils_deb" | sha256sum --check --status; then
        download_tmp="$gnu_coreutils_deb.tmp.$$"
        trap 'rm -f -- "$download_tmp"' EXIT
        curl --fail --show-error --silent --location \
            "$GNU_COREUTILS_URL" --output "$download_tmp"
        printf '%s  %s\n' "$GNU_COREUTILS_SHA256" "$download_tmp" | sha256sum --check --status || {
            echo "GNU coreutils package checksum mismatch" >&2
            exit 1
        }
        mv -- "$download_tmp" "$gnu_coreutils_deb"
        trap - EXIT
    fi
    if [[ ! -x "$gnu_coreutils_root/usr/bin/gnuinstall" ]]; then
        rm -rf -- "$gnu_coreutils_root"
        mkdir -p "$gnu_coreutils_root"
        dpkg-deb --extract "$gnu_coreutils_deb" "$gnu_coreutils_root"
    fi
    gnu_coreutils_bin="$gnu_coreutils_root/shims"
    if [[ ! -x "$gnu_coreutils_bin/install" ]]; then
        rm -rf -- "$gnu_coreutils_bin"
        mkdir -p "$gnu_coreutils_bin"
        for tool in "$gnu_coreutils_root"/usr/bin/gnu* "$gnu_coreutils_root"/usr/sbin/gnu*; do
            [[ -e "$tool" ]] || continue
            tool_name=${tool##*/gnu}
            ln -s -- "$tool" "$gnu_coreutils_bin/$tool_name"
        done
    fi
fi

case "$board" in
    pi4)
        kas_file="$source_root/kas/raspberrypi4.yml"
        machine=raspberrypi4-64
        device_type=cosmopod-rpi4-64
        ;;
    pi5)
        kas_file="$source_root/kas/raspberrypi5.yml"
        machine=raspberrypi5
        device_type=cosmopod-rpi5
        ;;
    vm)
        kas_file="$source_root/kas/vm-x86_64.yml"
        machine=genericx86-64
        device_type=cosmopod-vm-x86-64
        ;;
esac

overlay="$source_root/.cosmopod-release.yml"
cat > "$overlay" <<EOF
header:
  version: 14

local_conf_header:
  cosmopod-release: |
    COSMOPOD_VERSION = "$version"
    MENDER_ARTIFACT_NAME = "cosmopod-os-$version-$board"
    MENDER_DEVICE_TYPE = "$device_type"
    DL_DIR = "$cache_root/downloads"
    SSTATE_DIR = "$cache_root/sstate"
    BB_NUMBER_THREADS = "$bb_threads"
    PARALLEL_MAKE = "-j $make_jobs"
EOF

export KAS_CONTAINER_IMAGE="ghcr.io/siemens/kas/kas:$KAS_VERSION"
export KAS_WORK_DIR="$work_dir"
export KAS_BUILD_DIR="$work_dir/build"
export KAS_DL_DIR="$cache_root/downloads"
export KAS_SSTATE_DIR="$cache_root/sstate"

cd "$source_root"
if [[ "$engine" == container ]]; then
    docker info >/dev/null 2>&1 || {
        echo "Container engine selected, but Docker is unavailable" >&2
        exit 1
    }
    kas_executable="$tools_dir/kas-container-$KAS_VERSION"
    if [[ ! -x "$kas_executable" ]]; then
        curl --fail --show-error --silent --location \
            "https://raw.githubusercontent.com/siemens/kas/$KAS_VERSION/kas-container" \
            --output "$kas_executable"
        chmod 0755 "$kas_executable"
    fi
    kas_runner=("$kas_executable")
else
    host_python=$(command -v python3)
    kas_pythonpath="$tools_dir/kas-python-$KAS_VERSION"
    if [[ ! -f "$kas_pythonpath/kas/__main__.py" ]]; then
        rm -rf -- "$kas_pythonpath"
        "$host_python" -m pip install --disable-pip-version-check \
            --target "$kas_pythonpath" "kas==$KAS_VERSION"
    fi
    export PYTHONPATH="$kas_pythonpath${PYTHONPATH:+:$PYTHONPATH}"
    kas_runner=("$host_python" -m kas)

    # Checkout only needs Git/Python. The pinned Yocto installer then supplies
    # the complete supported host toolchain without sudo or Docker privileges.
    "${kas_runner[@]}" checkout "$kas_file:$overlay"
    buildtools_env="$work_dir/openembedded-core/buildtools/environment-setup-x86_64-pokysdk-linux"
    if [[ ! -f "$buildtools_env" ]]; then
        (
            cd "$work_dir/openembedded-core"
            scripts/install-buildtools \
                --base-url https://downloads.yoctoproject.org/releases/yocto \
                --release "yocto-$YOCTO_VERSION" \
                --installer-version "$YOCTO_VERSION"
        )
    fi
    # Source as a conditional: some SDK setup revisions probe optional host
    # tools with commands that may return non-zero, which must not trip `set -e`.
    # shellcheck disable=SC1090
    if ! source "$buildtools_env"; then
        echo "Yocto buildtools environment setup failed" >&2
        exit 1
    fi
    hosttools_dir="$work_dir/build/tmp/hosttools"
    if [[ -n "$gnu_coreutils_bin" ]]; then
        export PATH="$gnu_coreutils_bin:$PATH"
        hash -r
        active_install_version=$(install --version 2>&1 || true)
        [[ "$active_install_version" == *"GNU coreutils"* ]] || {
            echo "Failed to activate user-local GNU coreutils" >&2
            exit 1
        }
        # BitBake caches absolute host-tool symlinks; rebuild them after the
        # provider changes so a prior uutils path cannot survive a retry. KAS
        # sanitizes BB_ORIGENV, so pre-seed GNU links before BitBake fills the
        # remaining host tools from its original environment.
        rm -rf -- "$hosttools_dir"
        mkdir -p "$hosttools_dir"
        for tool in "$gnu_coreutils_bin"/*; do
            ln -s -- "$tool" "$hosttools_dir/${tool##*/}"
        done
    fi

    # Ubuntu 26.04's patched tar uses openat2 for extraction. Pseudo 1.9 from
    # Yocto 5.0 cannot track the resulting directory fd (Yocto bug 16316).
    # Always use the compatible tar already supplied by pinned buildtools.
    mkdir -p "$hosttools_dir"
    buildtools_tar="$work_dir/openembedded-core/buildtools/sysroots/x86_64-pokysdk-linux/usr/bin/tar"
    [[ -x "$buildtools_tar" ]] || {
        echo "Compatible tar missing from Yocto buildtools" >&2
        exit 1
    }
    ln -sfn -- "$buildtools_tar" "$hosttools_dir/tar"

    if ! locale -a | grep -Eiq '^en_US\.utf-?8$'; then
        cat >&2 <<'EOF'
BitBake requires en_US.UTF-8. Generate it once in this WSL distro:
  wsl.exe -d Ubuntu -u root -- localedef -i en_US -f UTF-8 en_US.UTF-8
EOF
        exit 1
    fi
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
fi

echo "Build engine: $engine"
if [[ "$action" == checkout ]]; then
    "${kas_runner[@]}" checkout "$kas_file:$overlay"
    echo "Checkout and host tools ready: $work_dir"
    exit 0
fi

"${kas_runner[@]}" build "$kas_file:$overlay"

deploy_dir="$work_dir/build/tmp/deploy/images/$machine"
export_parent="$original_root/out/$version"
export_dir="$export_parent/$board"
staging_dir="$export_parent/.${board}.tmp.$$"
rm -rf -- "$staging_dir"
mkdir -p "$staging_dir"
trap 'rm -rf -- "$staging_dir"' EXIT

if [[ "$board" == vm ]]; then
    iso_image="$deploy_dir/cosmopod-image-$machine.rootfs.iso"
    qcow_image="$deploy_dir/cosmopod-image-$machine.rootfs.wic.qcow2"
    [[ -n "$iso_image" && -e "$iso_image" ]] || { echo "VM .iso missing" >&2; exit 1; }
    [[ -n "$qcow_image" && -e "$qcow_image" ]] || { echo "VM .wic.qcow2 missing" >&2; exit 1; }
    cp -L "$iso_image" "$staging_dir/Cosmopod-OS-$version-vm-x86_64.iso"
    cp -L "$qcow_image" "$staging_dir/Cosmopod-OS-$version-vm-x86_64.qcow2"
else
    factory_image=$(find "$deploy_dir" -maxdepth 1 -type l -name "cosmopod-image-$device_type.sdimg" -print -quit)
    update_artifact=$(find "$deploy_dir" -maxdepth 1 -type l -name "cosmopod-image-$device_type.mender" -print -quit)
    [[ -n "$factory_image" && -e "$factory_image" ]] || { echo "Factory .sdimg missing" >&2; exit 1; }
    [[ -n "$update_artifact" && -e "$update_artifact" ]] || { echo "Update .mender missing" >&2; exit 1; }
    cp -L "$factory_image" "$staging_dir/Cosmopod-OS-$version-$board.img"
    cp -L "$update_artifact" "$staging_dir/Cosmopod-OS-$version-$board-unsigned.mender"
    xz -T0 -6 --force "$staging_dir/Cosmopod-OS-$version-$board.img"
fi

spdx_root="$work_dir/build/tmp/deploy/spdx"
if [[ -d "$spdx_root" ]]; then
    tar -C "$spdx_root" -cJf "$staging_dir/Cosmopod-OS-$version-$board-spdx.tar.xz" .
fi

license_root="$work_dir/build/tmp/deploy/licenses"
if [[ -d "$license_root" ]]; then
    tar -C "$license_root" -cJf "$staging_dir/Cosmopod-OS-$version-$board-licenses.tar.xz" .
fi

(
    cd "$staging_dir"
    sha256sum -- Cosmopod-OS-* > SHA256SUMS
)

rm -rf -- "$export_dir"
mv -- "$staging_dir" "$export_dir"
trap - EXIT

if [[ "$board" == vm ]]; then
    echo "VM ISO:   $export_dir/Cosmopod-OS-$version-vm-x86_64.iso"
    echo "VM disk:  $export_dir/Cosmopod-OS-$version-vm-x86_64.qcow2"
else
    echo "Factory image: $export_dir/Cosmopod-OS-$version-$board.img.xz"
    echo "Unsigned OTA:  $export_dir/Cosmopod-OS-$version-$board-unsigned.mender"
fi
