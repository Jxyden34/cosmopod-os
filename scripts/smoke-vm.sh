#!/usr/bin/env bash
set -Eeuo pipefail

version=
media=all
channel=auto
timeout_seconds=240

usage() {
    cat <<'EOF'
Usage: scripts/smoke-vm.sh [--version VERSION] [--channel auto|development|release]
                           [--media all|iso|qcow2]
                           [--timeout SECONDS]

Boot rebuilt Cosmopod VM media in isolated QEMU/TCG instances. A fixed guest
reporter checks mounts, SSH policy, systemd, DRM, and Weston, prints evidence to
the serial log, then powers the VM off. It accepts no guest commands.

Optional overrides:
  COSMOPOD_QEMU       qemu-system-x86_64 path
  COSMOPOD_QEMU_IMG   qemu-img path
  COSMOPOD_QEMU_DATA  QEMU firmware/data directory
  COSMOPOD_QEMU_KEYMAP absolute en-us keymap path
  COSMOPOD_OVMF_CODE  EDK2/OVMF code pflash path
  COSMOPOD_OVMF_VARS  matching writable variables template
EOF
}

while (($#)); do
    case "$1" in
        --version) version=${2:?missing version}; shift ;;
        --channel) channel=${2:?missing channel}; shift ;;
        --media) media=${2:?missing media}; shift ;;
        --timeout) timeout_seconds=${2:?missing timeout}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[[ "$media" =~ ^(all|iso|qcow2)$ ]] || {
    echo "Media must be all, iso, or qcow2" >&2
    exit 2
}
[[ "$channel" =~ ^(auto|development|release)$ ]] || {
    echo "Channel must be auto, development, or release" >&2
    exit 2
}
[[ "$timeout_seconds" =~ ^[1-9][0-9]{1,3}$ ]] || {
    echo "Timeout must be 10-9999 seconds" >&2
    exit 2
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$script_dir/.." && pwd)
if [[ -z "$version" ]]; then
    version=$(tr -d '[:space:]' < "$root/VERSION")
fi
[[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$ ]] || {
    echo "Invalid version: $version" >&2
    exit 2
}

if [[ "$channel" == auto ]]; then
    development_dir="$root/out/$version/vm-development"
    release_dir="$root/out/$version/vm-release"
    development_exists=0
    release_exists=0
    [[ -d "$development_dir" ]] && development_exists=1
    [[ -d "$release_dir" ]] && release_exists=1
    if ((development_exists + release_exists != 1)); then
        echo "Auto channel requires exactly one of: $development_dir or $release_dir" >&2
        echo "Select --channel development or --channel release" >&2
        exit 1
    fi
    if ((development_exists)); then
        channel=development
    else
        channel=release
    fi
fi
artifact_dir="$root/out/$version/vm-$channel"
iso="$artifact_dir/Cosmopod-OS-$version-vm-x86_64.iso"
qcow="$artifact_dir/Cosmopod-OS-$version-vm-x86_64.qcow2"
smoke_dir="$artifact_dir/smoke"
cache_root=${COSMOPOD_BUILD_ROOT:-"$HOME/.cache/cosmopod-os"}

if [[ "$media" == all || "$media" == iso ]]; then
    [[ -f "$iso" ]] || { echo "Missing ISO: $iso" >&2; exit 1; }
fi
if [[ "$media" == all || "$media" == qcow2 ]]; then
    [[ -f "$qcow" ]] || { echo "Missing QCOW2: $qcow" >&2; exit 1; }
fi
mkdir -p "$smoke_dir"
for command_name in awk date find git grep head python3 sed sha256sum socat sort ssh-keygen ssh-keyscan tail tr wc; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Required host command missing: $command_name" >&2
        exit 1
    }
done

find_tool() {
    local override=$1 name=$2 candidate
    if [[ -n "$override" ]]; then
        [[ -x "$override" ]] || { echo "Not executable: $override" >&2; return 1; }
        printf '%s\n' "$override"
        return
    fi
    candidate="$cache_root/work-vm/build/tmp/sysroots-components/x86_64/qemu-system-native/usr/bin/$name"
    if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return
    fi
    if candidate=$(command -v "$name" 2>/dev/null); then
        printf '%s\n' "$candidate"
        return
    fi
    candidate=$(find "$cache_root/work-vm/build/tmp" -type f -path "*/qemu-system-native/usr/bin/$name" -print -quit 2>/dev/null || true)
    [[ -n "$candidate" && -x "$candidate" ]] || {
        echo "Cannot find $name; set its COSMOPOD_* override" >&2
        return 1
    }
    printf '%s\n' "$candidate"
}

qemu=$(find_tool "${COSMOPOD_QEMU:-}" qemu-system-x86_64)
qemu_img=
if [[ "$media" == all || "$media" == qcow2 ]]; then
    qemu_img=$(find_tool "${COSMOPOD_QEMU_IMG:-}" qemu-img)
fi
qemu_prefix=$(cd -- "$(dirname -- "$qemu")/.." && pwd)
native_sysroot=
library_path="$qemu_prefix/lib:$qemu_prefix/lib64"
case "$qemu" in
"$cache_root"/work-vm/*)
    native_sysroot="$cache_root/work-vm/build/tmp/work/genericx86_64-poky-linux/core-image-minimal-initramfs/1.0/recipe-sysroot-native"
    if [[ ! -d "$native_sysroot" ]]; then
        native_sysroot=$(find "$cache_root/work-vm/build/tmp/work/genericx86_64-poky-linux/core-image-minimal-initramfs" \
            -type d -path '*/recipe-sysroot-native' -print 2>/dev/null | sort -V | tail -n 1 || true)
    fi
    [[ -d "$native_sysroot" ]] || {
        echo "Matching Yocto QEMU recipe sysroot missing" >&2
        exit 1
    }
    for library in libvirglrenderer.so.1 libfdt.so.1 libslirp.so.0; do
        [[ -e "$native_sysroot/usr/lib/$library" || -e "$native_sysroot/lib/$library" ]] || {
            echo "Matching Yocto QEMU library missing: $library" >&2
            exit 1
        }
    done
    library_path="$native_sysroot/usr/lib:$native_sysroot/lib:$library_path"
    ;;
esac
export LD_LIBRARY_PATH="$library_path${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

qemu_data=${COSMOPOD_QEMU_DATA:-"$qemu_prefix/share/qemu"}
[[ -d "$qemu_data" ]] || {
    echo "QEMU data directory missing: $qemu_data" >&2
    exit 1
}
qemu_keymap=${COSMOPOD_QEMU_KEYMAP:-}
if [[ -z "$qemu_keymap" ]]; then
    case "$qemu" in
    "$cache_root"/work-vm/*)
        qemu_keymap=$(find "$cache_root/work-vm/build/tmp/work" \
            -type f -path '*/pango/*/recipe-sysroot-native/usr/share/qemu/keymaps/en-us' \
            -print 2>/dev/null | sort -V | tail -n 1 || true)
        ;;
    *)
        [[ ! -f "$qemu_data/keymaps/en-us" ]] || qemu_keymap="$qemu_data/keymaps/en-us"
        ;;
    esac
fi
[[ -f "$qemu_keymap" ]] || {
    echo "QEMU en-us keymap missing; set COSMOPOD_QEMU_KEYMAP" >&2
    exit 1
}
"$qemu" --version >/dev/null
[[ -z "$qemu_img" ]] || "$qemu_img" --version >/dev/null

find_ovmf() {
    local pair code vars
    if [[ -n "${COSMOPOD_OVMF_CODE:-}" || -n "${COSMOPOD_OVMF_VARS:-}" ]]; then
        [[ -f "${COSMOPOD_OVMF_CODE:-}" && -f "${COSMOPOD_OVMF_VARS:-}" ]] || {
            echo "Set both COSMOPOD_OVMF_CODE and COSMOPOD_OVMF_VARS" >&2
            return 1
        }
        printf '%s|%s\n' "$COSMOPOD_OVMF_CODE" "$COSMOPOD_OVMF_VARS"
        return
    fi
    for pair in \
        "$qemu_data/edk2-x86_64-code.fd|$qemu_data/edk2-i386-vars.fd" \
        "$cache_root/work-vm/build/tmp/deploy/images/genericx86-64/ovmf.code.qcow2|$cache_root/work-vm/build/tmp/deploy/images/genericx86-64/ovmf.vars.qcow2" \
        /usr/share/OVMF/OVMF_CODE_4M.fd\|/usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd\|/usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd\|/usr/share/edk2/ovmf/OVMF_VARS.fd
    do
        code=${pair%%|*}
        vars=${pair#*|}
        if [[ -f "$code" && -f "$vars" ]]; then
            printf '%s\n' "$pair"
            return
        fi
    done
    echo "Cannot find matching OVMF code/vars files; set COSMOPOD_OVMF_CODE and COSMOPOD_OVMF_VARS" >&2
    return 1
}

detect_image_format() {
    local path=$1 detected
    detected=$("$qemu_img" info --output=json "$path" | \
        python3 -c 'import json, sys; print(json.load(sys.stdin)["format"])') || {
        echo "Cannot inspect image format: $path" >&2
        return 1
    }
    case "$detected" in
        raw|qcow2) printf '%s\n' "$detected" ;;
        *)
            echo "Unsupported pflash image format '$detected': $path" >&2
            return 1
            ;;
    esac
}

runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/cosmopod-smoke.XXXXXX")
active_pid=
active_qmp=

qmp_quit() {
    local socket=$1
    [[ -S "$socket" ]] || return 1
    command -v socat >/dev/null 2>&1 || return 1
    printf '%s\n%s\n' \
        '{"execute":"qmp_capabilities"}' \
        '{"execute":"quit"}' | socat -T 2 - "UNIX-CONNECT:$socket" >/dev/null 2>&1
}

qmp_screendump() {
    local socket=$1 output=$2 deadline response returns
    [[ -S "$socket" ]] || return 1
    command -v socat >/dev/null 2>&1 || return 1
    response=$(printf '%s\n' \
        '{"execute":"qmp_capabilities"}' \
        "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$output\"}}" | \
        socat -T 2 - "UNIX-CONNECT:$socket" 2>/dev/null || true)
    [[ "$response" != *'"error"'* ]] || return 1
    returns=$(grep -o '"return"' <<< "$response" | wc -l || true)
    ((returns >= 2)) || return 1
    deadline=$((SECONDS + 5))
    while [[ ! -s "$output" ]] && ((SECONDS < deadline)); do
        sleep 1
    done
    [[ -s "$output" ]]
}

qmp_hmp() {
    local socket=$1 command=$2 response returns
    [[ -S "$socket" ]] || return 1
    response=$(printf '%s\n' \
        '{"execute":"qmp_capabilities"}' \
        "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"$command\"}}" | \
        socat -T 2 - "UNIX-CONNECT:$socket" 2>/dev/null || true)
    [[ "$response" != *'"error"'* ]] || return 1
    returns=$(grep -o '"return"' <<< "$response" | wc -l || true)
    ((returns >= 2))
}

wait_until_stopped() {
    local pid=$1 seconds=$2 deadline=$((SECONDS + seconds))
    while kill -0 "$pid" 2>/dev/null && ((SECONDS < deadline)); do
        sleep 1
    done
    ! kill -0 "$pid" 2>/dev/null
}

cleanup() {
    if [[ -n "$active_pid" ]] && kill -0 "$active_pid" 2>/dev/null; then
        qmp_quit "$active_qmp" || true
        wait_until_stopped "$active_pid" 3 || kill "$active_pid" 2>/dev/null || true
        wait_until_stopped "$active_pid" 3 || kill -KILL "$active_pid" 2>/dev/null || true
        if kill -0 "$active_pid" 2>/dev/null; then
            echo "Leaving runtime directory because QEMU $active_pid did not stop" >&2
            return
        fi
    fi
    case "$runtime_dir" in
        "${TMPDIR:-/tmp}"/cosmopod-smoke.*) rm -rf -- "$runtime_dir" ;;
    esac
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

normalize_serial() {
    local source=$1 destination=$2
    sed -E $'s/\033\\[[0-9;?]*[ -\\/]*[@-~]//g' "$source" | tr -d '\r' > "$destination"
}

validate_ppm() {
    python3 - "$1" <<'PY'
from pathlib import Path
import sys

data = Path(sys.argv[1]).read_bytes()
position = 0

def token() -> bytes:
    global position
    while position < len(data):
        if data[position:position + 1] == b"#":
            end = data.find(b"\n", position)
            position = len(data) if end < 0 else end + 1
        elif data[position:position + 1].isspace():
            position += 1
        else:
            break
    start = position
    while position < len(data) and not data[position:position + 1].isspace():
        position += 1
    if start == position:
        raise ValueError("missing PPM token")
    return data[start:position]

magic = token()
width = int(token())
height = int(token())
maximum = int(token())
if magic not in (b"P3", b"P6") or width < 320 or height < 200 or maximum != 255:
    raise ValueError("invalid PPM header or dimensions")

pixel_count = width * height
if magic == b"P6":
    if data[position:position + 2] == b"\r\n":
        position += 2
    elif data[position:position + 1].isspace():
        position += 1
    payload = data[position:]
    if len(payload) < pixel_count * 3:
        raise ValueError("truncated PPM payload")
    stride = max(1, pixel_count // 10000)
    colours = {
        payload[index * 3:index * 3 + 3]
        for index in range(0, pixel_count, stride)
    }
else:
    values = [int(item) for item in data[position:].split()]
    if len(values) < pixel_count * 3:
        raise ValueError("truncated PPM payload")
    stride = max(3, (pixel_count // 10000) * 3)
    colours = {
        tuple(values[index:index + 3])
        for index in range(0, pixel_count * 3, stride)
    }

if len(colours) < 4:
    raise ValueError("screen image is blank or nearly uniform")
print(f"{width}x{height},sample_colours={len(colours)}")
PY
}

extract_weston_log() {
    local serial_log=$1 output=$2
    awk '
        /^COSMOPOD_WESTON_LOG_BEGIN$/ { inside=1; next }
        /^COSMOPOD_WESTON_LOG_END$/ { inside=0 }
        inside { print }
    ' "$serial_log" > "$output"
}

serial_complete() {
    local log=$1
    grep -aq 'COSMOPOD_SMOKE_RESULT=' "$log" 2>/dev/null && \
        grep -aEq '[[:alnum:]_.-]+ login:' "$log" 2>/dev/null
}

allocate_loopback_port() {
    python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

scan_ssh_host() {
    local port=$1 output=$2 temporary="$output.tmp"
    if ssh-keyscan -T 1 -p "$port" -t ed25519,rsa 127.0.0.1 \
        > "$temporary" 2>/dev/null && [[ -s "$temporary" ]]
    then
        mv -- "$temporary" "$output"
        return 0
    fi
    rm -f -- "$temporary"
    return 1
}

ssh_fingerprint_set() {
    ssh-keygen -lf "$1" 2>/dev/null | awk '{print $2}' | sort -u
}

wait_for_smoke() {
    local raw_log=$1 screenshot=$2 ssh_port=$3 ssh_scan=$4
    local deadline=$((SECONDS + timeout_seconds))
    local screenshot_attempted=0 ssh_scanned=0
    while ((SECONDS < deadline)); do
        if grep -aq 'COSMOPOD_SMOKE_SCREENSHOT_READY' "$raw_log" 2>/dev/null; then
            if ((screenshot_attempted == 0)) && \
                qmp_screendump "$active_qmp" "$screenshot"
            then
                screenshot_attempted=1
            fi
            if ((ssh_scanned == 0)) && scan_ssh_host "$ssh_port" "$ssh_scan"; then
                ssh_scanned=1
            fi
        fi
        serial_complete "$raw_log" && return 0
        kill -0 "$active_pid" 2>/dev/null || return 1
        sleep 1
    done
    return 1
}

finish_qemu() {
    local pid=$active_pid qmp=$active_qmp status forced=0
    if ! wait_until_stopped "$pid" 20; then
        forced=1
        qmp_quit "$qmp" || true
    fi
    if ! wait_until_stopped "$pid" 5; then
        kill "$pid" 2>/dev/null || true
    fi
    if ! wait_until_stopped "$pid" 5; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    if kill -0 "$pid" 2>/dev/null; then
        echo "QEMU process $pid did not stop after bounded cleanup" >&2
        return 1
    fi
    set +e
    wait "$pid"
    status=$?
    set -e
    active_pid=
    active_qmp=
    if ((forced)); then
        echo "QEMU required forced QMP shutdown" >&2
        return 1
    fi
    if ((status != 0)); then
        echo "QEMU exited with status $status" >&2
        return 1
    fi
}

check_result() {
    local name=$1 raw_log=$2 qemu_log=$3 screenshot=$4 ssh_scan=$5
    local serial_log="$smoke_dir/$name.serial.log"
    local weston_log="$smoke_dir/$name.weston.log"
    local screenshot_valid=0 ssh_valid=1 ppm_info= fingerprint_count=0
    cp -- "$raw_log" "$smoke_dir/$name.serial.raw.log"
    normalize_serial "$raw_log" "$serial_log"
    extract_weston_log "$serial_log" "$weston_log"
    cp -- "$qemu_log" "$smoke_dir/$name.qemu.log"
    if [[ -s "$screenshot" ]] && ppm_info=$(validate_ppm "$screenshot" 2>/dev/null); then
        cp -- "$screenshot" "$smoke_dir/$name.screen.ppm"
        screenshot_valid=1
        printf '%s_screen=%s\n' "$name" "$ppm_info" >> "$manifest"
    fi
    if [[ -s "$ssh_scan" ]]; then
        cp -- "$ssh_scan" "$smoke_dir/$name.ssh-hostkeys"
        while read -r _ fingerprint _; do
            [[ -n "$fingerprint" ]] || continue
            fingerprint_count=$((fingerprint_count + 1))
            grep -Fq "$fingerprint" "$serial_log" || ssh_valid=0
        done < <(ssh-keygen -lf "$ssh_scan" 2>/dev/null || true)
    else
        ssh_valid=0
    fi

    if grep -Eiq \
        'failed to mount.*(boot-sr0|nfsd)|NFSD configuration.*failed|failed to start Remount Root|/rootfs/media/boot-sr0.*(no such|failed)|mkdir:.*boot-sr0.*read-only file system' \
        "$serial_log"
    then
        echo "$name: known live-boot regression found in serial log" >&2
        return 1
    fi
    if ! grep -Eq '[[:alnum:]_.-]+ login:' "$serial_log"; then
        echo "$name: serial login prompt missing" >&2
        return 1
    fi
    if ! grep -Fqx 'COSMOPOD_SMOKE boot.serial-console=PASS' "$serial_log"; then
        echo "$name: serial kernel command line not proven" >&2
        return 1
    fi
    if ! grep -Fqx 'COSMOPOD_SMOKE_RESULT=PASS' "$serial_log"; then
        echo "$name: guest smoke checks failed" >&2
        grep -Ei -m 1 'fatal|error|failed|cannot|permission|no drm' "$weston_log" >&2 || true
        return 1
    fi
    if ((screenshot_valid == 0)); then
        echo "$name: QMP screenshot missing or invalid" >&2
        return 1
    fi
    if ((ssh_valid == 0 || fingerprint_count < 2)); then
        echo "$name: loopback SSH host-key handshake failed" >&2
        return 1
    fi
    echo "$name: PASS"
}

run_iso() {
    local raw_log="$runtime_dir/iso.serial.raw"
    local qemu_log="$runtime_dir/iso.qemu.log"
    local screenshot="$runtime_dir/iso.screen.ppm"
    local ssh_scan="$runtime_dir/iso.ssh-hostkeys"
    local ssh_port
    ssh_port=$(allocate_loopback_port)
    printf 'iso_ssh_host_port=%s\n' "$ssh_port" >> "$manifest"
    active_qmp="$runtime_dir/iso.qmp"
    : > "$raw_log"
    : > "$qemu_log"
    "$qemu" \
        -name cosmopod-smoke-iso \
        -machine q35,accel=tcg \
        -cpu max -smp 2 -m 4096 \
        -L "$qemu_data" -k "$qemu_keymap" \
        -no-reboot -boot d -cdrom "$iso" \
        -smbios type=1,serial=COSMOPOD-SMOKE-ISO \
        -vga none -device virtio-vga \
        -display vnc=127.0.0.1:0,to=99 \
        -nic "user,model=virtio-net-pci,restrict=on,hostfwd=tcp:127.0.0.1:$ssh_port-:22" \
        -serial "file:$raw_log" -monitor none \
        -qmp "unix:$active_qmp,server=on,wait=off" \
        > /dev/null 2> "$qemu_log" &
    active_pid=$!

    sleep 3
    if ! qmp_hmp "$active_qmp" 'sendkey down'; then
        echo "ISO: could not select serial boot entry" >&2
        qmp_quit "$active_qmp" || true
        finish_qemu || true
        return 1
    fi
    sleep 1
    if ! qmp_hmp "$active_qmp" 'sendkey ret'; then
        echo "ISO: could not start serial boot entry" >&2
        qmp_quit "$active_qmp" || true
        finish_qemu || true
        return 1
    fi

    wait_for_smoke "$raw_log" "$screenshot" "$ssh_port" "$ssh_scan" || true
    local finish_status=0 result_status=0
    finish_qemu || finish_status=$?
    check_result iso "$raw_log" "$qemu_log" "$screenshot" "$ssh_scan" || result_status=$?
    ((finish_status == 0 && result_status == 0))
}

run_qcow2_boot() {
    local boot=$1 overlay=$2 code=$3 code_format=$4 vars_copy=$5 vars_format=$6
    local name="qcow2.boot$boot"
    local raw_log="$runtime_dir/$name.serial.raw"
    local qemu_log="$runtime_dir/$name.qemu.log"
    local screenshot="$runtime_dir/$name.screen.ppm"
    local ssh_scan="$runtime_dir/$name.ssh-hostkeys"
    local ssh_port
    ssh_port=$(allocate_loopback_port)
    printf 'qcow2_boot%s_ssh_host_port=%s\n' "$boot" "$ssh_port" >> "$manifest"
    active_qmp="$runtime_dir/$name.qmp"
    : > "$raw_log"
    : > "$qemu_log"

    "$qemu" \
        -name "cosmopod-smoke-qcow2-boot$boot" \
        -machine q35,accel=tcg \
        -cpu max -smp 2 -m 4096 \
        -L "$qemu_data" -k "$qemu_keymap" \
        -no-reboot \
        -smbios type=1,serial=COSMOPOD-SMOKE-QCOW2 \
        -drive "if=pflash,format=$code_format,unit=0,readonly=on,file=$code" \
        -drive "if=pflash,format=$vars_format,unit=1,file=$vars_copy" \
        -drive "if=virtio,format=qcow2,file=$overlay" \
        -vga none -device virtio-vga \
        -display vnc=127.0.0.1:0,to=99 \
        -nic "user,model=virtio-net-pci,restrict=on,hostfwd=tcp:127.0.0.1:$ssh_port-:22" \
        -serial "file:$raw_log" -monitor none \
        -qmp "unix:$active_qmp,server=on,wait=off" \
        > /dev/null 2> "$qemu_log" &
    active_pid=$!

    wait_for_smoke "$raw_log" "$screenshot" "$ssh_port" "$ssh_scan" || true
    local finish_status=0 result_status=0
    finish_qemu || finish_status=$?
    check_result "$name" "$raw_log" "$qemu_log" "$screenshot" "$ssh_scan" || result_status=$?
    ((finish_status == 0 && result_status == 0))
}

check_qcow2_persistence() {
    local first_serial="$smoke_dir/qcow2.boot1.serial.log"
    local second_serial="$smoke_dir/qcow2.boot2.serial.log"
    local first_scan="$smoke_dir/qcow2.boot1.ssh-hostkeys"
    local second_scan="$smoke_dir/qcow2.boot2.ssh-hostkeys"
    local first_keys second_keys key_count

    grep -Fqx 'COSMOPOD_SMOKE persistence.state=created' "$first_serial" || {
        echo "qcow2: first boot did not create the persistence sentinel" >&2
        return 1
    }
    grep -Fqx 'COSMOPOD_SMOKE persistence.state=existing' "$second_serial" || {
        echo "qcow2: second boot did not recover the persistence sentinel" >&2
        return 1
    }
    first_keys=$(ssh_fingerprint_set "$first_scan")
    second_keys=$(ssh_fingerprint_set "$second_scan")
    key_count=$(grep -c . <<< "$first_keys" || true)
    if [[ -z "$first_keys" || "$first_keys" != "$second_keys" || "$key_count" -lt 2 ]]; then
        echo "qcow2: persistent SSH host keys changed across boots" >&2
        return 1
    fi
    while IFS= read -r fingerprint; do
        [[ -n "$fingerprint" ]] && printf 'qcow2_persistent_hostkey=%s\n' "$fingerprint" >> "$manifest"
    done <<< "$first_keys"
    printf 'qcow2_persistence=two-boots-pass\n' >> "$manifest"
}

run_qcow2() {
    local ovmf code vars code_format vars_format
    ovmf=$(find_ovmf) || return 1
    code=${ovmf%%|*}
    vars=${ovmf#*|}
    code_format=$(detect_image_format "$code") || return 1
    vars_format=$(detect_image_format "$vars") || return 1
    {
        printf 'ovmf_code=%s\n' "$code"
        printf 'ovmf_vars=%s\n' "$vars"
        sha256sum -- "$code" "$vars"
    } >> "$manifest"

    local overlay="$runtime_dir/disk.qcow2"
    local vars_copy="$runtime_dir/ovmf-vars"
    "$qemu_img" create -q -f qcow2 -F qcow2 -b "$qcow" "$overlay" || return 1
    cp -L -- "$vars" "$vars_copy" || return 1

    run_qcow2_boot 1 "$overlay" "$code" "$code_format" "$vars_copy" "$vars_format" || return 1
    run_qcow2_boot 2 "$overlay" "$code" "$code_format" "$vars_copy" "$vars_format" || return 1
    check_qcow2_persistence
}

tests=()
[[ "$media" == all || "$media" == iso ]] && tests+=(iso)
[[ "$media" == all || "$media" == qcow2 ]] && tests+=(qcow2)
evidence_names=()
[[ "$media" == all || "$media" == iso ]] && evidence_names+=(iso)
if [[ "$media" == all || "$media" == qcow2 ]]; then
    evidence_names+=(qcow2.boot1 qcow2.boot2)
fi
tap="$smoke_dir/results.tap"
manifest="$smoke_dir/manifest.txt"
cleanup_names=("${evidence_names[@]}")
[[ "$media" == all || "$media" == qcow2 ]] && cleanup_names+=(qcow2)
for test_name in "${cleanup_names[@]}"; do
    rm -f -- \
        "$smoke_dir/$test_name.serial.raw.log" \
        "$smoke_dir/$test_name.serial.log" \
        "$smoke_dir/$test_name.weston.log" \
        "$smoke_dir/$test_name.qemu.log" \
        "$smoke_dir/$test_name.ssh-hostkeys" \
        "$smoke_dir/$test_name.screen.ppm"
done
rm -f -- "$smoke_dir/SHA256SUMS" "$tap" "$manifest"
{
    printf 'started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'source_commit=%s\n' "$(git -C "$root" rev-parse HEAD)"
    if [[ -n "$(git -C "$root" status --porcelain --untracked-files=normal)" ]]; then
        printf 'source_dirty=true\n'
    else
        printf 'source_dirty=false\n'
    fi
    printf 'media=%s\n' "$media"
    printf 'channel=%s\n' "$channel"
    printf 'timeout_seconds=%s\n' "$timeout_seconds"
    printf 'qemu_path=%s\n' "$qemu"
    printf 'qemu_version=%s\n' "$("$qemu" --version | head -n 1)"
    if [[ -n "$qemu_img" ]]; then
        printf 'qemu_img_path=%s\n' "$qemu_img"
        printf 'qemu_img_version=%s\n' "$("$qemu_img" --version | head -n 1)"
    fi
    printf 'qemu_data=%s\n' "$qemu_data"
    printf 'qemu_keymap=%s\n' "$qemu_keymap"
    printf 'qemu_machine=q35,accel=tcg\n'
    printf 'qemu_cpu=max\n'
    printf 'qemu_memory_mib=4096\n'
    printf 'qemu_network=user,restrict=on,loopback-ssh-forward\n'
    printf 'qemu_display=virtio-vga,loopback-vnc\n'
    sha256sum -- "$qemu" "$qemu_keymap" "$root/scripts/smoke-vm.sh" \
        "$root/meta-cosmopod/recipes-core/cosmopod-vm-config/files/cosmopod-vm-smoke"
    [[ -z "$qemu_img" ]] || sha256sum -- "$qemu_img"
    [[ "$media" != qcow2 ]] || sha256sum -- "$qcow"
    [[ "$media" != iso ]] || sha256sum -- "$iso"
    [[ "$media" != all ]] || sha256sum -- "$iso" "$qcow"
} > "$manifest"
printf 'TAP version 13\n1..%d\n' "${#tests[@]}" > "$tap"

failures=0
number=0
for test_name in "${tests[@]}"; do
    number=$((number + 1))
    if "run_$test_name"; then
        printf 'ok %d - %s\n' "$number" "$test_name" >> "$tap"
    else
        printf 'not ok %d - %s\n' "$number" "$test_name" >> "$tap"
        failures=$((failures + 1))
    fi
done

printf 'finished_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$manifest"
hash_files=("$tap" "$manifest")
for test_name in "${evidence_names[@]}"; do
    for evidence in \
        "$smoke_dir/$test_name.serial.raw.log" \
        "$smoke_dir/$test_name.serial.log" \
        "$smoke_dir/$test_name.weston.log" \
        "$smoke_dir/$test_name.qemu.log" \
        "$smoke_dir/$test_name.ssh-hostkeys" \
        "$smoke_dir/$test_name.screen.ppm"
    do
        [[ -f "$evidence" ]] && hash_files+=("$evidence")
    done
done
sha256sum -- "${hash_files[@]}" > "$smoke_dir/SHA256SUMS"
cat "$tap"
((failures == 0))
