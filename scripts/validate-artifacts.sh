#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    echo "Usage: scripts/validate-artifacts.sh {pi4|pi5|vm} [VERSION]" >&2
}

[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 2; }
board=$1
case "$board" in
    pi4|pi5|vm) ;;
    *) usage; exit 2 ;;
esac

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
version=${2:-$(<"$root/VERSION")}
out_dir="$root/out/$version/$board"
work_dir=${COSMOPOD_BUILD_ROOT:-"$HOME/.cache/cosmopod-os"}/work-$board

[[ -d "$out_dir" ]] || { echo "Missing artifact directory: $out_dir" >&2; exit 1; }
cd "$out_dir"
sha256sum --check SHA256SUMS

require() {
    command -v "$1" >/dev/null || { echo "Missing validation tool: $1" >&2; exit 1; }
}

partition_value() {
    local image=$1 number=$2 tag=$3 start sectors
    read -r start sectors < <(partx -g -n "$number" -o START,SECTORS "$image")
    [[ -n "$start" && -n "$sectors" ]] || return 1
    blkid -p -D -O $((start * 512)) -S $((sectors * 512)) \
        -s "$tag" -o value "$image"
}

validate_pi() {
    local image mender raw device_type artifact_tool os_release metadata
    image="Cosmopod-OS-$version-$board.img.xz"
    mender="Cosmopod-OS-$version-$board-unsigned.mender"
    if [[ "$board" == pi4 ]]; then
        device_type=cosmopod-rpi4-64
    else
        device_type=cosmopod-rpi5
    fi

    for tool in xz file fdisk sfdisk partx blkid; do require "$tool"; done
    xz --test --verbose "$image"
    file "$image" "$mender"

    mkdir -p "${COSMOPOD_BUILD_ROOT:-"$HOME/.cache/cosmopod-os"}"
    raw=$(mktemp "${COSMOPOD_BUILD_ROOT:-"$HOME/.cache/cosmopod-os"}/$board-validate.XXXXXX.img")
    trap 'rm -f -- "${raw:-}" "${converted:-}"' EXIT
    xz -dc -- "$image" > "$raw"
    file "$raw"
    fdisk -l "$raw"

    [[ $(partx -g -o NR "$raw" | wc -l) -eq 4 ]]
    sfdisk --dump "$raw" | grep -q '^label: dos$'
    sfdisk --dump "$raw" | grep -q 'bootable'
    [[ $(partition_value "$raw" 1 TYPE) == vfat ]]
    [[ $(partition_value "$raw" 1 LABEL) == boot ]]
    [[ $(partition_value "$raw" 2 TYPE) == ext4 ]]
    [[ $(partition_value "$raw" 3 TYPE) == ext4 ]]
    [[ $(partition_value "$raw" 4 TYPE) == ext4 ]]
    [[ $(partition_value "$raw" 4 LABEL) == data ]]

    artifact_tool=${MENDER_ARTIFACT:-"$work_dir/build/tmp/sysroots-components/x86_64/mender-artifact-native/usr/bin/mender-artifact"}
    [[ -x "$artifact_tool" ]] || { echo "Missing mender-artifact: $artifact_tool" >&2; exit 1; }
    "$artifact_tool" validate "$mender"
    metadata=$("$artifact_tool" read "$mender")
    printf '%s\n' "$metadata"
    grep -Fq "cosmopod-os-$version-$board" <<<"$metadata"
    grep -Fq "$device_type" <<<"$metadata"

    os_release=$(find "$work_dir/build/tmp/work" -maxdepth 6 \
        -path '*/cosmopod-image/*/rootfs/etc/os-release' -print -quit)
    [[ -n "$os_release" ]]
    grep -q '^ID=cosmopod$' "$os_release"
    grep -q '^NAME="Cosmopod OS"$' "$os_release"
    grep -q "^VERSION_ID=$version$" "$os_release"
    grep -E '^(ID|NAME|VERSION_ID)=' "$os_release"
}

validate_vm() {
    local iso qcow qemu_img isoinfo converted listing os_release
    iso="Cosmopod-OS-$version-vm-x86_64.iso"
    qcow="Cosmopod-OS-$version-vm-x86_64.qcow2"
    for tool in file fdisk sfdisk partx blkid; do require "$tool"; done
    file "$iso" "$qcow"
    fdisk -l "$iso"

    qemu_img=${QEMU_IMG:-$(find "$work_dir/build/tmp/sysroots-components/x86_64" \
        -path '*/usr/bin/qemu-img' -type f -print -quit)}
    isoinfo=${ISOINFO:-$(find "$work_dir/build/tmp/sysroots-components/x86_64" \
        -path '*/usr/bin/isoinfo' -type f -print -quit)}
    [[ -x "$qemu_img" ]] || { echo "Missing qemu-img validator" >&2; exit 1; }
    [[ -x "$isoinfo" ]] || { echo "Missing isoinfo validator" >&2; exit 1; }
    "$qemu_img" info --output=json "$qcow"
    "$qemu_img" check -f qcow2 "$qcow"

    converted=$(mktemp "${COSMOPOD_BUILD_ROOT:-"$HOME/.cache/cosmopod-os"}/vm-validate.XXXXXX.raw")
    trap 'rm -f -- "${raw:-}" "${converted:-}"' EXIT
    "$qemu_img" convert -f qcow2 -O raw "$qcow" "$converted"
    file "$converted"
    fdisk -l "$converted"
    [[ $(partx -g -o NR "$converted" | wc -l) -eq 4 ]]
    sfdisk --dump "$converted" | grep -q '^label: gpt$'
    [[ $(partition_value "$converted" 1 TYPE) == vfat ]]
    [[ $(partition_value "$converted" 1 LABEL) == boot ]]
    [[ $(partition_value "$converted" 2 TYPE) == ext4 ]]
    [[ $(partition_value "$converted" 3 TYPE) == ext4 ]]
    [[ $(partition_value "$converted" 3 LABEL) == cosmopod-data ]]
    [[ $(partition_value "$converted" 4 TYPE) == swap ]]
    [[ $(partition_value "$converted" 4 LABEL) == swap1 ]]

    "$isoinfo" -d -i "$iso"
    listing=$("$isoinfo" -R -f -i "$iso")
    printf '%s\n' "$listing"
    grep -Fxiq '/isolinux/isolinux.bin' <<<"$listing"
    grep -Fxiq '/efi.img' <<<"$listing"
    grep -Fxiq '/rootfs.img' <<<"$listing"

    os_release=$(find "$work_dir/build/tmp/work" -maxdepth 6 \
        -path '*/cosmopod-image/*/rootfs/etc/os-release' -print -quit)
    [[ -n "$os_release" ]]
    grep -q '^ID=cosmopod$' "$os_release"
    grep -q '^NAME="Cosmopod OS"$' "$os_release"
    grep -q "^VERSION_ID=$version$" "$os_release"
    grep -E '^(ID|NAME|VERSION_ID)=' "$os_release"
}

if [[ "$board" == vm ]]; then
    validate_vm
else
    validate_pi
fi

echo "PASS Cosmopod OS $version $board artifact validation"
