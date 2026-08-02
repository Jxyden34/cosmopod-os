#!/usr/bin/env bash
set -Eeuo pipefail

KAS_VERSION=5.4
KAS_CONTAINER_IMAGE="ghcr.io/siemens/kas/kas:5.4@sha256:11f076b79b84f57cb7d933941ff619f09a7c17e562e1643d13836d5f8d0a92f3"
KAS_CONTAINER_SCRIPT_SHA256=9707355d1eba19e334e663ab9fcf6881ac323aed16ff7f4fd7e217f879a3894c
YOCTO_VERSION=6.0
CVE_DATABASE_MAX_AGE_SECONDS=172800
GNU_COREUTILS_VERSION=9.7-3ubuntu2
GNU_COREUTILS_SHA256=6b5b60a5c372b6e9d1dcfa1507317aae59bf809d4f4d6d363d3ef0a58a189137
GNU_COREUTILS_URL="https://archive.ubuntu.com/ubuntu/pool/main/c/coreutils/gnu-coreutils_${GNU_COREUTILS_VERSION}_amd64.deb"
board=pi4
version=
action=build
engine=auto
requested_channel=auto
allow_dirty=false
replace_output=false
allow_unconfined_task_network=false
mender_server_url=https://kys.dpdns.org
bb_threads=${COSMOPOD_BB_NUMBER_THREADS:-6}
make_jobs=${COSMOPOD_PARALLEL_MAKE_JOBS:-6}
build_started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

usage() {
    cat <<'EOF'
Usage: scripts/build.sh [--build|--checkout-only] [--engine auto|native|container]
                        [--channel auto|development|release]
                        [--allow-dirty] [--replace-output]
                        [--allow-unconfined-task-network]
                        [--mender-server-url https://HOST]
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
        --channel) requested_channel=${2:?missing channel}; shift ;;
        --board) board=${2:?missing board}; shift ;;
        --version) version=${2:?missing version}; shift ;;
        --allow-dirty) allow_dirty=true ;;
        --replace-output) replace_output=true ;;
        --allow-unconfined-task-network) allow_unconfined_task_network=true ;;
        --mender-server-url) mender_server_url=${2:?missing Mender server URL}; shift ;;
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
[[ "$requested_channel" =~ ^(auto|development|release)$ ]] || {
    echo "Channel must be auto, development, or release" >&2
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
original_root=$(cd -- "$script_dir/.." && pwd -P)
# shellcheck source=release-common.sh
source "$script_dir/release-common.sh"
if [[ -z "$version" ]]; then
    version=$(tr -d '[:space:]' < "$original_root/VERSION")
fi
[[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$ ]] || {
    echo "Invalid version: $version" >&2
    exit 2
}
validate_https_origin "$mender_server_url" || {
    echo "Mender server URL must be an HTTPS origin without path, credentials, query, or fragment" >&2
    exit 2
}

for tool in date find flock git grep python3 realpath sed sha256sum sort stat tar xargs xz zstd; do
    command -v "$tool" >/dev/null || { echo "Missing release tool: $tool" >&2; exit 1; }
done

validate_archive_paths() {
    local list_file=$1 label=$2 entry
    [[ -s "$list_file" ]] || {
        echo "$label archive has no entries" >&2
        return 1
    }
    while IFS= read -r entry; do
        case "$entry" in
            ""|/*|..|../*|*/..|*/../*)
                echo "$label archive contains an unsafe path: $entry" >&2
                return 1
                ;;
        esac
    done < "$list_file"
}
source_toplevel=$(git -C "$original_root" rev-parse --show-toplevel 2>/dev/null) || {
    echo "Cosmopod source must be a Git repository before kas runs" >&2
    exit 1
}
source_toplevel=$(cd -- "$source_toplevel" && pwd -P)
[[ "$source_toplevel" == "$original_root" ]] || {
    echo "Cosmopod source must be the root of its Git repository" >&2
    exit 1
}
source_commit=$(git -C "$original_root" rev-parse HEAD)
source_tree=$(git -C "$original_root" rev-parse 'HEAD^{tree}')
source_content_sha256=$(git_source_fingerprint "$original_root")
source_dirty=false
if [[ -n "$(git -C "$original_root" status --porcelain --untracked-files=normal)" ]]; then
    source_dirty=true
fi
if [[ "$source_dirty" == true && "$allow_dirty" != true ]]; then
    echo "Release build refused: source tree is dirty. Commit changes or pass --allow-dirty for a non-publishable development build." >&2
    exit 1
fi

cache_base_requested="$HOME/.cache/cosmopod-os"
mkdir -p -- "$cache_base_requested"
cache_base=$(realpath -e -- "$cache_base_requested")
cache_root=$(realpath -m -- "${COSMOPOD_BUILD_ROOT:-"$cache_base"}")
case "$cache_root" in
    "$cache_base"|"$cache_base"/*) ;;
    *) echo "COSMOPOD_BUILD_ROOT must resolve under $cache_base" >&2; exit 2 ;;
esac
mkdir -p -- "$cache_root"
cache_root=$(realpath -e -- "$cache_root")
case "$cache_root" in
    "$cache_base"|"$cache_base"/*) ;;
    *) echo "COSMOPOD_BUILD_ROOT escaped its trusted cache root" >&2; exit 2 ;;
esac

ensure_cache_dir() {
    local requested=$1 resolved
    [[ "$requested" == "$cache_root"/* && ! -L "$requested" ]] || {
        echo "Unsafe or symlinked cache directory: $requested" >&2
        return 1
    }
    mkdir -p -- "$requested"
    resolved=$(realpath -e -- "$requested")
    case "$resolved" in
        "$cache_root"/*) ;;
        *) echo "Cache directory escaped trusted root: $requested" >&2; return 1 ;;
    esac
    printf '%s\n' "$resolved"
}

locks_dir=$(ensure_cache_dir "$cache_root/.locks")
global_lock_dir=$(ensure_cache_dir "$locks_dir/global-build")
exec {global_build_lock_fd}< "$global_lock_dir"
flock --exclusive --nonblock "$global_build_lock_fd" || {
    echo "Another Cosmopod build is using shared source, tools, or work directories" >&2
    exit 1
}
if [[ "$original_root" == /mnt/* ]]; then
    command -v rsync >/dev/null || { echo "rsync is required" >&2; exit 1; }
    source_root=$(ensure_cache_dir "$cache_root/source")
    # A fast builder may keep the checkout directly at the configured cache
    # source path. Never run --delete-excluded rsync onto that same directory:
    # it would erase ignored deliverables such as out/ before every board build.
    if [[ "$original_root" != "$source_root" ]]; then
        rsync -a --delete --delete-excluded \
            --exclude build --exclude 'build-*' --exclude out \
            --include '/secrets/' --include '/secrets/README.md' \
            --exclude '/secrets/***' --exclude '*/secrets/***' \
            --exclude backend/.state/ --exclude backend/.runtime/ \
            "$original_root/" "$source_root/"
    fi
else
    source_root=$original_root
fi

git -C "$source_root" rev-parse --show-toplevel >/dev/null 2>&1 || {
    echo "Cosmopod source must be a Git repository before kas runs" >&2
    exit 1
}
[[ "$(git -C "$source_root" rev-parse HEAD)" == "$source_commit" ]] || {
    echo "Synced source commit does not match the requested source commit" >&2
    exit 1
}
[[ "$(git_source_fingerprint "$source_root")" == "$source_content_sha256" ]] || {
    echo "Synced source content does not match the requested source tree" >&2
    exit 1
}

if [[ "$engine" == auto ]]; then
    if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
        engine=container
    else
        engine=native
    fi
fi

tools_dir=$(ensure_cache_dir "$cache_root/tools")
work_dir=$(ensure_cache_dir "$cache_root/work-$board")
downloads_dir=$(ensure_cache_dir "$cache_root/downloads")
sstate_dir=$(ensure_cache_dir "$cache_root/sstate")
tmp_dir=$(ensure_cache_dir "$cache_root/tmp")
build_override_vars=(
    BB_ENV_EXTRAWHITE BB_ENV_PASSTHROUGH_ADDITIONS BB_NUMBER_THREADS BBPATH
    BUILDDIR DISTRO KAS_ALLOW_ROOT KAS_BUILDTOOLS_DIR KAS_CLONE_DEPTH
    KAS_CONTAINER_ENGINE KAS_DISTRO KAS_DOCKER_ENGINE KAS_EXTRA_BITBAKE_ARGS
    KAS_EXTRA_RUNTIME_ARGS KAS_MACHINE KAS_PREMIRRORS KAS_REPO_REF_DIR
    KAS_RUNTIME_ARGS KAS_TARGET KAS_TASK MACHINE PARALLEL_MAKE
    SOURCE_DATE_EPOCH SSTATE_MIRRORS TEMPLATECONF TMPDIR
)
for override_var in "${build_override_vars[@]}"; do
    unset "$override_var"
done
export TMPDIR="$tmp_dir"
export PIP_CONFIG_FILE=/dev/null

# Ubuntu 26.04 may provide `install` through uutils coreutils. Yocto's
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

out_root="$original_root/out"
mkdir -p -- "$out_root"
[[ "$(realpath -e -- "$out_root")" == "$out_root" ]] || {
    echo "Release output root must not be a symlink: $out_root" >&2
    exit 1
}
export_parent="$out_root/$version"
case "$requested_channel" in
    auto)
        output_channel=release
        [[ "$source_dirty" != true ]] || output_channel=development
        ;;
    development)
        output_channel=development
        ;;
    release)
        [[ "$source_dirty" == false ]] || {
            echo "Release channel requires a clean source tree" >&2
            exit 1
        }
        output_channel=release
        ;;
esac
if [[ "$allow_unconfined_task_network" == true && "$output_channel" != development ]]; then
    echo "Unconfined task networking is allowed only for development output" >&2
    exit 1
fi
export_dir="$export_parent/$board-$output_channel"
[[ "$(realpath -m -- "$export_parent")" == "$export_parent" ]] && \
    [[ "$(realpath -m -- "$export_dir")" == "$export_dir" ]] || {
    echo "Unsafe or symlinked release output path: $export_dir" >&2
    exit 1
}
locks_root="$out_root/.locks"
[[ ! -L "$locks_root" ]] || {
    echo "Release lock root must not be a symlink: $locks_root" >&2
    exit 1
}
mkdir -p -- "$locks_root"
[[ "$(realpath -e -- "$locks_root")" == "$locks_root" ]] || {
    echo "Release lock root escaped the repository: $locks_root" >&2
    exit 1
}
output_lock_dir="$locks_root/$version-$board-$output_channel"
[[ "$(realpath -m -- "$output_lock_dir")" == "$output_lock_dir" ]] || {
    echo "Unsafe or symlinked release lock path: $output_lock_dir" >&2
    exit 1
}
mkdir -p -- "$export_parent" "$output_lock_dir"
[[ "$(realpath -e -- "$export_parent")" == "$export_parent" ]] && \
    [[ "$(realpath -e -- "$output_lock_dir")" == "$output_lock_dir" ]] || {
    echo "Release output parent or lock directory is symlinked" >&2
    exit 1
}
exec {output_lock_fd}< "$output_lock_dir"
flock --exclusive --nonblock "$output_lock_fd" || {
    echo "Another Cosmopod build owns output $version/$board" >&2
    exit 1
}
if [[ "$action" == build && ( -e "$export_dir" || -L "$export_dir" ) && "$replace_output" != true ]]; then
    echo "Release output already exists: $export_dir" >&2
    echo "Use a new version, or pass --replace-output for an explicit pre-release rebuild." >&2
    exit 1
fi

# kas-container always mounts the source tree containing its config chain.
# This generated file is excluded from the Git-source fingerprint, then copied
# byte-for-byte into release evidence and bound by BUILD-MANIFEST.txt.
overlay="$source_root/.cosmopod-release.yml"
overlay_tmp="$source_root/.cosmopod-release.tmp.$$"
[[ ! -e "$overlay_tmp" && ! -L "$overlay_tmp" && ! -d "$overlay" ]] || {
    echo "Unsafe generated KAS overlay path" >&2
    exit 1
}
rm -f -- "$overlay"
previous_umask=$(umask)
umask 077
cat > "$overlay_tmp" <<EOF
header:
  version: 14

local_conf_header:
  cosmopod-release: |
    COSMOPOD_VERSION = "$version"
    MENDER_ARTIFACT_NAME = "cosmopod-os-$version-$board"
    MENDER_DEVICE_TYPE = "$device_type"
    MENDER_SERVER_URL = "$mender_server_url"
    DL_DIR = "\${TOPDIR}/../../downloads"
    SSTATE_DIR = "\${TOPDIR}/../../sstate"
    BB_NUMBER_THREADS = "$bb_threads"
    PARALLEL_MAKE = "-j $make_jobs"
    COSMOPOD_ALLOW_UNCONFINED_TASK_NETWORK = "$allow_unconfined_task_network"
    python () {
        if d.getVar("COSMOPOD_ALLOW_UNCONFINED_TASK_NETWORK") == "true":
            for task in (d.getVar("__BBTASKS") or "").split():
                d.setVarFlag(task, "network", "1")
    }
EOF
umask "$previous_umask"
chmod 0400 "$overlay_tmp"
mv -T -- "$overlay_tmp" "$overlay"
overlay_sha256=$(sha256sum "$overlay" | awk '{print $1}')
verify_overlay() {
    [[ -f "$overlay" && ! -L "$overlay" &&
       "$(sha256sum "$overlay" | awk '{print $1}')" == "$overlay_sha256" ]] || {
        echo "Generated KAS overlay changed while build was running" >&2
        return 1
    }
}
verify_overlay

export KAS_CONTAINER_IMAGE
export KAS_WORK_DIR="$work_dir"
export KAS_BUILD_DIR="$work_dir/build"
export DL_DIR="$downloads_dir"
export SSTATE_DIR="$sstate_dir"

cd "$source_root"
if [[ "$engine" == container ]]; then
    docker info >/dev/null 2>&1 || {
        echo "Container engine selected, but Docker is unavailable" >&2
        exit 1
    }
    command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
    kas_executable="$tools_dir/kas-container-$KAS_VERSION"
    if [[ ! -x "$kas_executable" ]] || \
       ! printf '%s  %s\n' "$KAS_CONTAINER_SCRIPT_SHA256" "$kas_executable" | \
            sha256sum --check --status; then
        kas_download="$kas_executable.tmp.$$"
        rm -f -- "$kas_download"
        if ! curl --fail --show-error --silent --location \
            "https://raw.githubusercontent.com/siemens/kas/$KAS_VERSION/kas-container" \
            --output "$kas_download"; then
            rm -f -- "$kas_download"
            echo "Failed to download the pinned kas-container wrapper" >&2
            exit 1
        fi
        if ! printf '%s  %s\n' "$KAS_CONTAINER_SCRIPT_SHA256" "$kas_download" | \
            sha256sum --check --status; then
            rm -f -- "$kas_download"
            echo "kas-container wrapper checksum mismatch" >&2
            exit 1
        fi
        chmod 0755 "$kas_download"
        mv -f -- "$kas_download" "$kas_executable"
    fi
    kas_runner=("$kas_executable")
else
    host_python=$(command -v python3)
    [[ "$(uname -m)" == x86_64 ]] || {
        echo "Native kas dependency lock currently supports x86_64 Linux only" >&2
        exit 1
    }
    python_version=$("$host_python" -c \
        'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    [[ "$python_version" =~ ^3\.(9|10|11|12|13|14)$ ]] || {
        echo "Native kas requires CPython 3.9 through 3.14; found $python_version" >&2
        exit 1
    }
    kas_requirements="$source_root/scripts/requirements-kas-$KAS_VERSION-linux-x86_64.txt"
    [[ -f "$kas_requirements" ]] || {
        echo "Pinned kas dependency lock is missing: $kas_requirements" >&2
        exit 1
    }
    kas_requirements_sha256=$(sha256sum "$kas_requirements" | awk '{print $1}')
    kas_pythonpath="$tools_dir/kas-python-$KAS_VERSION-$kas_requirements_sha256"
    kas_wheelhouse=$(ensure_cache_dir "$tools_dir/kas-wheels-$kas_requirements_sha256")
    if ! "$host_python" -I -m pip download --disable-pip-version-check \
        --no-deps --only-binary=:all: --require-hashes \
        --index-url https://pypi.org/simple --dest "$kas_wheelhouse" \
        --requirement "$kas_requirements"; then
        echo "Failed to populate hash-locked kas wheelhouse" >&2
        exit 1
    fi

    # Never trust an installed-tree marker stored beside writable executable
    # code. Reinstall from hash-checked wheels for every invocation, verify the
    # complete distribution/import closure, then publish with directory-atomic
    # renames under the global build lock.
    kas_pythonpath_tmp=$(mktemp -d "$tools_dir/.kas-python-$KAS_VERSION.tmp.XXXXXX")
    kas_pythonpath_previous="$tools_dir/.kas-python-$KAS_VERSION.previous.$$"
    [[ ! -e "$kas_pythonpath_previous" && ! -L "$kas_pythonpath_previous" ]] || {
        rm -rf -- "$kas_pythonpath_tmp"
        echo "Refusing unsafe kas runtime backup path" >&2
        exit 1
    }
    if ! "$host_python" -I -m pip install --disable-pip-version-check \
        --no-index --find-links "$kas_wheelhouse" --no-compile --no-deps \
        --only-binary=:all: --require-hashes --target "$kas_pythonpath_tmp" \
        --requirement "$kas_requirements"; then
        rm -rf -- "$kas_pythonpath_tmp"
        echo "Failed to install hash-locked kas dependencies" >&2
        exit 1
    fi
    if ! PYTHONDONTWRITEBYTECODE=1 "$host_python" -I \
        "$source_root/scripts/verify-kas-install.py" \
        "$kas_pythonpath_tmp" "$KAS_VERSION"; then
        rm -rf -- "$kas_pythonpath_tmp"
        echo "Pinned kas installation failed its closure check" >&2
        exit 1
    fi
    if [[ -e "$kas_pythonpath" || -L "$kas_pythonpath" ]]; then
        mv -T -- "$kas_pythonpath" "$kas_pythonpath_previous"
    fi
    if ! mv -T -- "$kas_pythonpath_tmp" "$kas_pythonpath"; then
        [[ -e "$kas_pythonpath_previous" || -L "$kas_pythonpath_previous" ]] &&
            mv -T -- "$kas_pythonpath_previous" "$kas_pythonpath"
        echo "Failed to publish verified kas runtime" >&2
        exit 1
    fi
    if ! PYTHONDONTWRITEBYTECODE=1 "$host_python" -I \
        "$source_root/scripts/verify-kas-install.py" \
        "$kas_pythonpath" "$KAS_VERSION"; then
        rm -rf -- "$kas_pythonpath"
        [[ -e "$kas_pythonpath_previous" || -L "$kas_pythonpath_previous" ]] &&
            mv -T -- "$kas_pythonpath_previous" "$kas_pythonpath"
        echo "Published kas runtime failed its closure check" >&2
        exit 1
    fi
    rm -rf -- "$kas_pythonpath_previous"
    export PYTHONDONTWRITEBYTECODE=1
    export PYTHONPATH="$kas_pythonpath"
    kas_runner=("$host_python" -S -m kas)

    # Checkout only needs Git/Python. The pinned Yocto installer then supplies
    # the complete supported host toolchain without sudo or Docker privileges.
    verify_overlay
    "${kas_runner[@]}" checkout "$kas_file:$overlay"
    verify_overlay
    buildtools_root="$work_dir/openembedded-core/buildtools"
    buildtools_env="$buildtools_root/environment-setup-x86_64-pokysdk-linux"
    buildtools_version="$buildtools_root/version-x86_64-pokysdk-linux"
    if [[ ! -f "$buildtools_env" ]] ||
       [[ ! -f "$buildtools_version" ]] ||
       ! grep -Fqx "Distro Version: $YOCTO_VERSION" "$buildtools_version"; then
        rm -rf -- "$buildtools_root"
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
    # TMPDIR is shared deliberately across board workdirs, so BitBake creates
    # its cached host-tool links here rather than below work-$board/build.
    hosttools_dir="$tmp_dir/hosttools"
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

    # Some supported host tar implementations use openat2 in ways that Pseudo
    # cannot track (Yocto bug 16316).
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
    verify_overlay
    "${kas_runner[@]}" checkout "$kas_file:$overlay"
    verify_overlay
    echo "Checkout and host tools ready: $work_dir"
    exit 0
fi

verify_overlay
# Yocto's CVE handlers append one path per nostamp do_cve_check task. An
# interrupted BitBake process cannot emit BuildCompleted, so its accumulator
# files survive and the next build reports every repeated path as a duplicate
# package. The global build lock makes this cleanup safe for the shared TMPDIR.
for cve_accumulator in \
    "$tmp_dir/cve_check" \
    "$tmp_dir/log/cve/cve-summary-index.txt"; do
    if [[ -d "$cve_accumulator" && ! -L "$cve_accumulator" ]]; then
        echo "CVE accumulator path is unexpectedly a directory: $cve_accumulator" >&2
        exit 1
    fi
    rm -f -- "$cve_accumulator"
done
"${kas_runner[@]}" build "$kas_file:$overlay"
verify_overlay

deploy_dir="$tmp_dir/deploy/images/$machine"
staging_dir=$(mktemp -d "$export_parent/.${board}.tmp.XXXXXX")
previous_dir=
cleanup_export() {
    rm -rf -- "$staging_dir"
    if [[ -n "$previous_dir" && ( -e "$previous_dir" || -L "$previous_dir" ) && \
          ! -e "$export_dir" && ! -L "$export_dir" ]]; then
        mv -T -- "$previous_dir" "$export_dir" || true
    fi
}
trap cleanup_export EXIT
cp -- "$overlay" "$staging_dir/BUILD-KAS-OVERLAY.yml"
[[ "$(sha256sum "$staging_dir/BUILD-KAS-OVERLAY.yml" | awk '{print $1}')" == "$overlay_sha256" ]] || {
    echo "Exported KAS overlay does not match consumed configuration" >&2
    exit 1
}

if [[ "$board" == vm ]]; then
    iso_image="$deploy_dir/cosmopod-image-$machine.rootfs.iso"
    qcow_image="$deploy_dir/cosmopod-image-$machine.rootfs.wic.qcow2"
    [[ -n "$iso_image" && -e "$iso_image" ]] || { echo "VM .iso missing" >&2; exit 1; }
    [[ -n "$qcow_image" && -e "$qcow_image" ]] || { echo "VM .wic.qcow2 missing" >&2; exit 1; }
    cp -L "$iso_image" "$staging_dir/Cosmopod-OS-$version-vm-x86_64.iso"
    cp -L "$qcow_image" "$staging_dir/Cosmopod-OS-$version-vm-x86_64.qcow2"
    xz -T0 -6 --keep --force "$staging_dir/Cosmopod-OS-$version-vm-x86_64.iso"
    iso_archive="$staging_dir/Cosmopod-OS-$version-vm-x86_64.iso.xz"
    if (( $(stat -c '%s' "$iso_archive") >= 2147483648 )); then
        echo "Compressed VM ISO is not publishable: GitHub release assets must be under 2 GiB" >&2
        exit 1
    fi
else
    factory_image=$(find "$deploy_dir" -maxdepth 1 -type l -name "cosmopod-image-$device_type.sdimg" -print -quit)
    update_artifact=$(find "$deploy_dir" -maxdepth 1 -type l -name "cosmopod-image-$device_type.mender" -print -quit)
    [[ -n "$factory_image" && -e "$factory_image" ]] || { echo "Factory .sdimg missing" >&2; exit 1; }
    [[ -n "$update_artifact" && -e "$update_artifact" ]] || { echo "Update .mender missing" >&2; exit 1; }
    cp -L "$factory_image" "$staging_dir/Cosmopod-OS-$version-$board.img"
    cp -L "$update_artifact" "$staging_dir/Cosmopod-OS-$version-$board-unsigned.mender"
    xz -T0 -6 --force "$staging_dir/Cosmopod-OS-$version-$board.img"
fi

if [[ "$board" == vm ]]; then
    evidence_image_name="cosmopod-image-$machine.rootfs"
else
    evidence_image_name="cosmopod-image-$device_type"
fi

spdx_source="$deploy_dir/$evidence_image_name.spdx.json"
cve_source="$deploy_dir/$evidence_image_name.sbom-cve-check.yocto.json"
license_source="$tmp_dir/deploy/licenses/${machine//-/_}/$evidence_image_name"
spdx_export="Cosmopod-OS-$version-$board-spdx.tar.zst"
license_export="Cosmopod-OS-$version-$board-licenses.tar.xz"
cve_export="Cosmopod-OS-$version-$board-cve.json"
cve_gate_export="Cosmopod-OS-$version-$board-cve-gate.txt"
cve_database_export="Cosmopod-OS-$version-$board-cve-database.txt"

[[ -s "$spdx_source" ]] || {
    echo "Image SPDX bundle missing or empty: $spdx_source" >&2
    exit 1
}
[[ -d "$license_source" ]] || {
        echo "Image license evidence missing or empty: $license_source" >&2
        exit 1
    }
for license_manifest in image_license.manifest license.manifest package.manifest; do
    [[ -s "$license_source/$license_manifest" ]] || {
        echo "Image license manifest missing or empty: $license_source/$license_manifest" >&2
        exit 1
    }
done
[[ -s "$cve_source" ]] || {
    echo "Image CVE report missing or empty: $cve_source" >&2
    exit 1
}
cve_database="$tmp_dir/deploy/sbom-cve-check/databases"
[[ -d "$cve_database" && ! -L "$cve_database" ]] || {
    echo "Yocto SBOM CVE database directory missing or symlinked: $cve_database" >&2
    exit 1
}
cve_gate_checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

spdx_source_name=${spdx_source##*/}
tar -C "$deploy_dir" --sort=name --mtime=@0 --owner=0 --group=0 \
    --numeric-owner -cf - "$spdx_source_name" | \
    zstd --quiet --stdout > "$staging_dir/$spdx_export"
tar -C "$license_source" --sort=name --mtime=@0 --owner=0 --group=0 \
    --numeric-owner -cJf "$staging_dir/$license_export" .
spdx_entries="$staging_dir/.spdx.entries"
license_entries="$staging_dir/.license.entries"
normalized_license_entries="$staging_dir/.license.entries.normalized"
zstd --test --quiet "$staging_dir/$spdx_export"
zstd --decompress --stdout --quiet "$staging_dir/$spdx_export" |
    tar -tf - > "$spdx_entries"
validate_archive_paths "$spdx_entries" "SPDX"
grep -Eq '(^|/)[^/]+\.spdx\.json$' "$spdx_entries" || {
    echo "SPDX archive contains no SPDX JSON document" >&2
    exit 1
}
xz --test "$staging_dir/$license_export"
tar -tJf "$staging_dir/$license_export" > "$license_entries"
validate_archive_paths "$license_entries" "License"
sed 's|^\./||' "$license_entries" > "$normalized_license_entries"
for required_license_entry in \
    image_license.manifest license.manifest package.manifest; do
    [[ $(grep -Fxc "$required_license_entry" \
        "$normalized_license_entries") -eq 1 ]] || {
        echo "License archive must contain exactly one $required_license_entry" >&2
        exit 1
    }
done
rm -f -- "$spdx_entries" "$license_entries" "$normalized_license_entries"
cp -L -- "$cve_source" "$staging_dir/$cve_export"
python3 "$source_root/scripts/inspect-cve-database.py" \
    --database "$cve_database" \
    --build-started-at "$build_started_utc" \
    --checked-at "$cve_gate_checked_at" \
    --output "$staging_dir/$cve_database_export"
cve_database_sha256=$(sed -n 's/^database_sha256=//p' \
    "$staging_dir/$cve_database_export")
cve_database_mtime_utc=$(sed -n 's/^database_mtime_utc=//p' \
    "$staging_dir/$cve_database_export")
if python3 "$source_root/scripts/check-cve-report.py" \
        --report "$staging_dir/$cve_export" \
        --waivers "$source_root/security/cve-waivers.json" \
        --license-manifest "$license_source/license.manifest" \
        --database-evidence "$staging_dir/$cve_database_export" \
        --verification-at "$cve_gate_checked_at" \
        --output "$staging_dir/$cve_gate_export" >/dev/null; then
    cve_gate_exit=0
else
    cve_gate_exit=$?
fi
if (( cve_gate_exit > 1 )); then
    echo "CVE gate input validation failed" >&2
    exit "$cve_gate_exit"
fi
cve_gate_as_of=$(sed -n 's/^as_of=//p' "$staging_dir/$cve_gate_export")
cve_database_age_seconds=$(sed -n 's/^database_age_seconds=//p' \
    "$staging_dir/$cve_gate_export")
cve_gate_coverage_extra=$(sed -n 's/^coverage_extra=//p' \
    "$staging_dir/$cve_gate_export")
cve_gate_decision=$(sed -n 's/^decision=//p' "$staging_dir/$cve_gate_export")
cve_gate_denied=$(sed -n 's/^denied=//p' "$staging_dir/$cve_gate_export")
[[ $(grep -Fxc 'format=cosmopod-cve-gate-v4' "$staging_dir/$cve_gate_export") -eq 1 &&
   $(grep -c '^as_of=' "$staging_dir/$cve_gate_export") -eq 1 &&
   "$cve_gate_as_of" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ &&
   "$cve_database_age_seconds" =~ ^[0-9]+$ &&
   $(grep -Fxc "evaluated_at=$cve_gate_checked_at" "$staging_dir/$cve_gate_export") -eq 1 &&
   $(grep -Fxc "database_sha256=$cve_database_sha256" "$staging_dir/$cve_gate_export") -eq 1 &&
   $(grep -Fxc "database_mtime_utc=$cve_database_mtime_utc" "$staging_dir/$cve_gate_export") -eq 1 &&
   $(grep -Fxc "database_max_age_seconds=$CVE_DATABASE_MAX_AGE_SECONDS" "$staging_dir/$cve_gate_export") -eq 1 &&
   $(grep -Fxc 'database_fresh=true' "$staging_dir/$cve_gate_export") -eq 1 &&
   $(grep -Fxc 'coverage_complete=true' "$staging_dir/$cve_gate_export") -eq 1 &&
   "$cve_gate_coverage_extra" =~ ^[0-9]+$ &&
   $(grep -c '^decision=' "$staging_dir/$cve_gate_export") -eq 1 &&
   "$cve_gate_decision" =~ ^(PASS|FAIL)$ &&
   "$cve_gate_denied" =~ ^[0-9]+$ ]] || {
    echo "CVE gate evidence is structurally invalid" >&2
    exit 1
}
if [[ ( "$cve_gate_decision" == PASS && "$cve_gate_exit" -ne 0 ) ||
      ( "$cve_gate_decision" == FAIL && "$cve_gate_exit" -ne 1 ) ]]; then
    echo "CVE gate exit status does not match its recorded decision" >&2
    exit 1
fi
release_qualified=false
if [[ "$cve_gate_decision" == PASS && "$output_channel" == release ]]; then
    release_qualified=true
elif [[ "$cve_gate_decision" == FAIL && "$output_channel" == release ]]; then
    echo "Release build blocked by $cve_gate_denied denied CVE findings" >&2
    exit 1
elif [[ "$cve_gate_decision" == FAIL ]]; then
    echo "Development media is unqualified: CVE gate denied $cve_gate_denied findings" >&2
fi

verification_key="$source_root/meta-cosmopod/recipes-mender/mender/files/artifact-verify-key.pem"
[[ -s "$verification_key" ]] || {
    echo "Artifact verification key missing from source" >&2
    exit 1
}

verify_export_invariants() {
    [[ "$(git -C "$original_root" rev-parse HEAD)" == "$source_commit" && \
       "$(git -C "$original_root" rev-parse 'HEAD^{tree}')" == "$source_tree" && \
       "$(git_source_fingerprint "$original_root")" == "$source_content_sha256" ]] || {
        echo "Release source changed while the build was running; artifacts were not exported" >&2
        return 1
    }
    [[ "$(git -C "$source_root" rev-parse HEAD)" == "$source_commit" && \
       "$(git_source_fingerprint "$source_root")" == "$source_content_sha256" ]] || {
        echo "Synced build source changed while the build was running; artifacts were not exported" >&2
        return 1
    }
    [[ "$(realpath -e -- "$export_parent")" == "$export_parent" && \
       "$(realpath -e -- "$output_lock_dir")" == "$output_lock_dir" && \
       "$(realpath -m -- "$export_dir")" == "$export_dir" ]] || {
        echo "Release output path changed while the build was running; artifacts were not exported" >&2
        return 1
    }
}

verify_export_invariants
{
    printf 'format=cosmopod-build-manifest-v1\n'
    printf 'version=%s\n' "$version"
    printf 'board=%s\n' "$board"
    printf 'machine=%s\n' "$machine"
    printf 'device_type=%s\n' "$device_type"
    printf 'artifact_name=cosmopod-os-%s-%s\n' "$version" "$board"
    printf 'output_channel=%s\n' "$output_channel"
    printf 'requested_channel=%s\n' "$requested_channel"
    printf 'release_qualified=%s\n' "$release_qualified"
    printf 'mender_server_url=%s\n' "$mender_server_url"
    printf 'source_commit=%s\n' "$source_commit"
    printf 'source_tree=%s\n' "$source_tree"
    printf 'source_content_sha256=%s\n' "$source_content_sha256"
    printf 'source_dirty=%s\n' "$source_dirty"
    printf 'build_started_utc=%s\n' "$build_started_utc"
    printf 'build_finished_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'build_engine=%s\n' "$engine"
    printf 'environment_sanitized=true\n'
    printf 'task_network_isolation=%s\n' \
        "$([[ "$allow_unconfined_task_network" == true ]] && printf false || printf true)"
    printf 'kas_version=%s\n' "$KAS_VERSION"
    printf 'kas_container_image=%s\n' "$KAS_CONTAINER_IMAGE"
    printf 'kas_container_script_sha256=%s\n' "$KAS_CONTAINER_SCRIPT_SHA256"
    printf 'kas_python_lock_sha256=%s\n' \
        "$(sha256sum "$source_root/scripts/requirements-kas-$KAS_VERSION-linux-x86_64.txt" | awk '{print $1}')"
    printf 'kas_overlay=%s\n' BUILD-KAS-OVERLAY.yml
    printf 'kas_overlay_sha256=%s\n' "$overlay_sha256"
    printf 'bb_number_threads=%s\n' "$bb_threads"
    printf 'parallel_make_jobs=%s\n' "$make_jobs"
    printf 'yocto_version=%s\n' "$YOCTO_VERSION"
    printf 'git_version=%s\n' "$(git --version)"
    printf 'xz_version=%s\n' "$(xz --version 2>&1 | sed -n '1p')"
    printf 'verification_key_sha256=%s\n' "$(sha256sum "$verification_key" | awk '{print $1}')"
    printf 'spdx_bundle=%s\n' "$spdx_export"
    printf 'license_archive=%s\n' "$license_export"
    printf 'cve_report=%s\n' "$cve_export"
    printf 'cve_gate=%s\n' "$cve_gate_export"
    printf 'cve_database_evidence=%s\n' "$cve_database_export"
    printf 'cve_gate_as_of=%s\n' "$cve_gate_as_of"
    printf 'cve_gate_checked_at=%s\n' "$cve_gate_checked_at"
    printf 'cve_gate_decision=%s\n' "$cve_gate_decision"
    printf 'cve_gate_denied=%s\n' "$cve_gate_denied"
    printf 'cve_database_sha256=%s\n' "$cve_database_sha256"
    printf 'cve_database_mtime_utc=%s\n' "$cve_database_mtime_utc"
    printf 'cve_database_age_seconds=%s\n' "$cve_database_age_seconds"
    printf 'cve_database_max_age_seconds=%s\n' "$CVE_DATABASE_MAX_AGE_SECONDS"
    printf 'input_sha256_begin\n'
    mapfile -t release_inputs < <(
        release_input_paths "${kas_file#"$source_root"/}" "$KAS_VERSION"
    )
    ((${#release_inputs[@]} == 10)) || {
        echo "Shared release input policy returned an invalid file set" >&2
        exit 1
    }
    (
        cd -- "$source_root"
        sha256sum -- "${release_inputs[@]}"
    )
    printf 'input_sha256_end\n'
} > "$staging_dir/BUILD-MANIFEST.txt"

(
    cd "$staging_dir"
    find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 | \
        sort -z | xargs -0 sha256sum > SHA256SUMS
)

verify_export_invariants
if [[ -e "$export_dir" || -L "$export_dir" ]]; then
    [[ "$replace_output" == true ]] || {
        echo "Release output appeared while the build was running: $export_dir" >&2
        exit 1
    }
    [[ "$(realpath -m -- "$export_dir")" == "$export_dir" ]] || {
        echo "Refusing to replace a symlinked release output: $export_dir" >&2
        exit 1
    }
    previous_dir="$export_parent/.${board}.previous.$$"
    [[ ! -e "$previous_dir" && ! -L "$previous_dir" ]] || {
        echo "Refusing unsafe previous-output path: $previous_dir" >&2
        exit 1
    }
    mv -T -- "$export_dir" "$previous_dir"
fi
mv -T -- "$staging_dir" "$export_dir"
if [[ -n "$previous_dir" ]]; then
    rm -rf -- "$previous_dir"
    previous_dir=
fi
trap - EXIT

if [[ "$board" == vm ]]; then
    echo "VM ISO:          $export_dir/Cosmopod-OS-$version-vm-x86_64.iso"
    echo "VM ISO archive:  $export_dir/Cosmopod-OS-$version-vm-x86_64.iso.xz"
    echo "VM disk:         $export_dir/Cosmopod-OS-$version-vm-x86_64.qcow2"
else
    echo "Factory image: $export_dir/Cosmopod-OS-$version-$board.img.xz"
    echo "Unsigned OTA:  $export_dir/Cosmopod-OS-$version-$board-unsigned.mender"
fi
