#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    echo "Usage: scripts/validate-artifacts.sh {pi4|pi5|vm} [VERSION] [--channel development|release]" >&2
}

[[ $# -ge 1 && $# -le 4 ]] || { usage; exit 2; }
board=$1
shift
case "$board" in
    pi4|pi5|vm) ;;
    *) usage; exit 2 ;;
esac

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$script_dir/.." && pwd -P)
# shellcheck source=release-common.sh
source "$script_dir/release-common.sh"
version=$(<"$root/VERSION")
channel=release
version_supplied=false
while (($#)); do
    case "$1" in
        --channel)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            channel=$2
            shift 2
            ;;
        development|release)
            channel=$1
            shift
            ;;
        *)
            [[ "$version_supplied" == false ]] || { usage; exit 2; }
            version=$1
            version_supplied=true
            shift
            ;;
    esac
done
case "$channel" in
    development|release) ;;
    *) usage; exit 2 ;;
esac
out_dir="$root/out/$version/$board-$channel"
build_root=${COSMOPOD_BUILD_ROOT:-"$HOME/.cache/cosmopod-os"}
tmp_dir="$build_root/tmp"
temp_files=()

cleanup() {
    if ((${#temp_files[@]})); then
        rm -f -- "${temp_files[@]}"
    fi
}
trap cleanup EXIT

[[ -d "$out_dir" ]] || { echo "Missing artifact directory: $out_dir" >&2; exit 1; }
cd "$out_dir"

require() {
    command -v "$1" >/dev/null || { echo "Missing validation tool: $1" >&2; exit 1; }
}

native_tool() {
    local tool=$1
    find "$tmp_dir/work/x86_64-linux" -type f -executable \
        -path "*/usr/bin/$tool" -print -quit
}

image_rootfs() {
    local machine artifact candidate resolved
    case "$board" in
        pi4)
            machine=raspberrypi4-64
            artifact=cosmopod-rpi4-64
            ;;
        pi5)
            machine=raspberrypi5
            artifact=cosmopod-rpi5
            ;;
        *)
            echo "No deployed ext4 rootfs is defined for $board" >&2
            return 1
            ;;
    esac

    candidate="$tmp_dir/deploy/images/$machine/cosmopod-image-$artifact.ext4"
    resolved=$(readlink -f -- "$candidate")
    [[ "$resolved" == "$tmp_dir/deploy/images/$machine/"* && -f "$resolved" ]] || {
        echo "Missing deployed rootfs for $board: $candidate" >&2
        return 1
    }
    printf '%s\n' "$resolved"
}

validate_checksum_index() {
    local expected_entries=$1
    local expected_checksum_entries actual_checksum_entries
    [[ -s SHA256SUMS && ! -L SHA256SUMS ]] || {
        echo "Release checksum index is missing, empty, or symlinked" >&2
        exit 1
    }
    if LC_ALL=C grep -Eqv \
        '^[0-9a-f]{64}  \./[0-9A-Za-z][0-9A-Za-z._+-]*$' SHA256SUMS; then
        echo "Release checksum index contains an unsafe or malformed record" >&2
        exit 1
    fi
    expected_checksum_entries=$(printf '%s\n' "$expected_entries" |
        grep -Fvx SHA256SUMS | grep -Fvx SHA256SUMS.sig | sort)
    actual_checksum_entries=$(awk '{
        name=$2
        sub(/^\.\//, "", name)
        print name
    }' SHA256SUMS | sort)
    [[ "$actual_checksum_entries" == "$expected_checksum_entries" ]] || {
        echo "Release checksum index does not cover the exact approved file set" >&2
        exit 1
    }
    sha256sum --check --strict SHA256SUMS
}

validate_vm_smoke_evidence() {
    local smoke_dir actual_entries expected_entries entry hash path commit
    smoke_dir="$out_dir/smoke"
    [[ -d "$smoke_dir" && ! -L "$smoke_dir" ]] || {
        echo "VM smoke-test evidence is missing" >&2
        exit 1
    }
    expected_entries=$(printf '%s\n' \
        SHA256SUMS manifest.txt results.tap \
        iso.qemu.log iso.screen.ppm iso.serial.log iso.serial.raw.log iso.ssh-hostkeys iso.weston.log \
        qcow2.boot1.qemu.log qcow2.boot1.screen.ppm qcow2.boot1.serial.log qcow2.boot1.serial.raw.log qcow2.boot1.ssh-hostkeys qcow2.boot1.weston.log \
        qcow2.boot2.qemu.log qcow2.boot2.screen.ppm qcow2.boot2.serial.log qcow2.boot2.serial.raw.log qcow2.boot2.ssh-hostkeys qcow2.boot2.weston.log | sort)
    actual_entries=$(find "$smoke_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
    [[ "$actual_entries" == "$expected_entries" ]] || {
        echo "VM smoke evidence file set is not approved" >&2
        exit 1
    }
    while IFS= read -r entry; do
        [[ -f "$smoke_dir/$entry" && ! -L "$smoke_dir/$entry" ]] || {
            echo "VM smoke evidence entry is not a regular file: $entry" >&2
            exit 1
        }
    done <<< "$expected_entries"
    [[ -s "$smoke_dir/SHA256SUMS" ]] || {
        echo "VM smoke evidence checksum index is missing" >&2
        exit 1
    }
    while read -r hash path; do
        [[ "$hash" =~ ^[0-9a-f]{64}$ && "$path" == "$smoke_dir/"* ]] || {
            echo "VM smoke evidence checksum index contains an unsafe record" >&2
            exit 1
        }
    done < "$smoke_dir/SHA256SUMS"
    sha256sum --check --strict "$smoke_dir/SHA256SUMS"
    grep -Fqx 'TAP version 13' "$smoke_dir/results.tap"
    grep -Fqx '1..2' "$smoke_dir/results.tap"
    grep -Fqx 'ok 1 - iso' "$smoke_dir/results.tap"
    grep -Fqx 'ok 2 - qcow2' "$smoke_dir/results.tap"
    commit=$(manifest_value source_commit)
    grep -Fqx "source_commit=$commit" "$smoke_dir/manifest.txt"
    grep -Fqx 'source_dirty=false' "$smoke_dir/manifest.txt"
    grep -Fqx 'media=all' "$smoke_dir/manifest.txt"
}

validate_archive_paths() {
    local list_file=$1 label=$2 entry
    [[ -s "$list_file" ]] || {
        echo "$label archive has no entries" >&2
        exit 1
    }
    while IFS= read -r entry; do
        case "$entry" in
            ""|/*|..|../*|*/..|*/../*)
                echo "$label archive contains an unsafe path: $entry" >&2
                exit 1
                ;;
        esac
    done < "$list_file"
}

manifest_value() {
    local key=$1 value count
    count=$(grep -c "^${key}=" BUILD-MANIFEST.txt || true)
    [[ "$count" -eq 1 ]] || {
        echo "Build manifest must contain exactly one $key field" >&2
        return 1
    }
    value=$(sed -n "s/^${key}=//p" BUILD-MANIFEST.txt)
    printf '%s\n' "$value"
}

validate_manifest() {
    local expected_machine expected_device expected_kas commit tree content manifest_key actual_key
    local input_checks server_url expected_inputs actual_inputs
    local spdx_bundle license_archive cve_report cve_gate cve_database_evidence cve_gate_as_of
    local cve_gate_checked_at cve_database_sha256 cve_database_mtime_utc
    local cve_database_age_seconds cve_database_max_age_seconds
    local kas_overlay kas_overlay_sha256 bb_number_threads parallel_make_jobs
    local kas_version
    for tool in git sed; do require "$tool"; done
    [[ -s BUILD-MANIFEST.txt ]] || { echo "BUILD-MANIFEST.txt is missing" >&2; exit 1; }
    grep -Fqx 'format=cosmopod-build-manifest-v1' BUILD-MANIFEST.txt
    grep -Fqx "version=$version" BUILD-MANIFEST.txt
    grep -Fqx "board=$board" BUILD-MANIFEST.txt
    grep -Fqx "artifact_name=cosmopod-os-$version-$board" BUILD-MANIFEST.txt
    grep -Fqx 'source_dirty=false' BUILD-MANIFEST.txt
    grep -Fqx 'environment_sanitized=true' BUILD-MANIFEST.txt
    grep -Fqx 'task_network_isolation=true' BUILD-MANIFEST.txt

    case "$board" in
        pi4) expected_machine=raspberrypi4-64; expected_device=cosmopod-rpi4-64; expected_kas=kas/raspberrypi4.yml ;;
        pi5) expected_machine=raspberrypi5; expected_device=cosmopod-rpi5; expected_kas=kas/raspberrypi5.yml ;;
        vm) expected_machine=genericx86-64; expected_device=cosmopod-vm-x86-64; expected_kas=kas/vm-x86_64.yml ;;
    esac
    grep -Fqx "machine=$expected_machine" BUILD-MANIFEST.txt
    grep -Fqx "device_type=$expected_device" BUILD-MANIFEST.txt

    commit=$(manifest_value source_commit)
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid source commit in build manifest" >&2; exit 1; }
    [[ "$(git -C "$root" rev-parse HEAD)" == "$commit" ]] || {
        echo "Artifact source commit does not match this checkout" >&2
        exit 1
    }
    tree=$(manifest_value source_tree)
    [[ "$tree" =~ ^[0-9a-f]{40}$ && "$(git -C "$root" rev-parse 'HEAD^{tree}')" == "$tree" ]] || {
        echo "Artifact source tree does not match this checkout" >&2
        exit 1
    }
    content=$(manifest_value source_content_sha256)
    [[ "$content" =~ ^[0-9a-f]{64}$ && "$(git_source_fingerprint "$root")" == "$content" ]] || {
        echo "Artifact source content does not match this checkout" >&2
        exit 1
    }
    server_url=$(manifest_value mender_server_url)
    validate_https_origin "$server_url" || {
        echo "Invalid Mender server URL in build manifest" >&2
        exit 1
    }
    manifest_key=$(manifest_value verification_key_sha256)
    actual_key=$(sha256sum "$root/meta-cosmopod/recipes-mender/mender/files/artifact-verify-key.pem" | awk '{print $1}')
    [[ "$manifest_key" == "$actual_key" ]] || {
        echo "Artifact verification key does not match this checkout" >&2
        exit 1
    }
    spdx_bundle=$(manifest_value spdx_bundle)
    license_archive=$(manifest_value license_archive)
    cve_report=$(manifest_value cve_report)
    cve_gate=$(manifest_value cve_gate)
    cve_database_evidence=$(manifest_value cve_database_evidence)
    cve_gate_as_of=$(manifest_value cve_gate_as_of)
    cve_gate_checked_at=$(manifest_value cve_gate_checked_at)
    cve_database_sha256=$(manifest_value cve_database_sha256)
    cve_database_mtime_utc=$(manifest_value cve_database_mtime_utc)
    cve_database_age_seconds=$(manifest_value cve_database_age_seconds)
    cve_database_max_age_seconds=$(manifest_value cve_database_max_age_seconds)
    [[ "$spdx_bundle" == "Cosmopod-OS-$version-$board-spdx.tar.zst" &&
       "$license_archive" == "Cosmopod-OS-$version-$board-licenses.tar.xz" &&
       "$cve_report" == "Cosmopod-OS-$version-$board-cve.json" &&
       "$cve_gate" == "Cosmopod-OS-$version-$board-cve-gate.txt" &&
       "$cve_database_evidence" == "Cosmopod-OS-$version-$board-cve-database.txt" &&
       "$cve_gate_as_of" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ &&
       "$cve_gate_checked_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ &&
       "$cve_database_sha256" =~ ^[0-9a-f]{64}$ &&
       "$cve_database_mtime_utc" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ &&
       "$cve_database_age_seconds" =~ ^[0-9]+$ &&
       "$cve_database_max_age_seconds" == 172800 ]] || {
        echo "Build manifest security evidence names or date are invalid" >&2
        exit 1
    }
    kas_overlay=$(manifest_value kas_overlay)
    kas_overlay_sha256=$(manifest_value kas_overlay_sha256)
    bb_number_threads=$(manifest_value bb_number_threads)
    parallel_make_jobs=$(manifest_value parallel_make_jobs)
    kas_version=$(manifest_value kas_version)
    [[ "$kas_overlay" == BUILD-KAS-OVERLAY.yml &&
       "$kas_overlay_sha256" =~ ^[0-9a-f]{64}$ &&
       "$bb_number_threads" =~ ^[1-9][0-9]?$ &&
       "$parallel_make_jobs" =~ ^[1-9][0-9]?$ ]] || {
        echo "Build manifest KAS overlay evidence is invalid" >&2
        exit 1
    }
    [[ "$kas_version" == 5.4 ]] || {
        echo "Build manifest KAS version is not approved" >&2
        exit 1
    }
    input_checks=$(awk '
        /^input_sha256_begin$/ { inside=1; next }
        /^input_sha256_end$/ { inside=0 }
        inside { print }
    ' BUILD-MANIFEST.txt)
    [[ -n "$input_checks" ]] || { echo "Build manifest input hashes are missing" >&2; exit 1; }
    if grep -Eqv '^[0-9a-f]{64}  [A-Za-z0-9_./%+-]+$' <<< "$input_checks"; then
        echo "Build manifest contains an invalid input hash record" >&2
        exit 1
    fi
    expected_inputs=$(release_input_paths "$expected_kas" "$kas_version" | sort)
    actual_inputs=$(awk '{print $2}' <<< "$input_checks" | sort)
    [[ "$actual_inputs" == "$expected_inputs" ]] || {
        echo "Build manifest input file set is not the approved set" >&2
        exit 1
    }
    printf '%s\n' "$input_checks" | (cd "$root" && sha256sum --check --strict)
}

validate_security_evidence() {
    local spdx_bundle license_archive cve_report cve_gate cve_database_evidence cve_gate_as_of
    local cve_gate_checked_at cve_database_sha256 cve_database_mtime_utc
    local cve_database_age_seconds cve_database_max_age_seconds
    local kas_overlay kas_overlay_sha256 bb_number_threads parallel_make_jobs
    local mender_server_url device_type evidence_name evidence_path replay
    local expected_entries actual_entries checksum_entries expected_overlay_text
    local signed_artifact signed_record signed_checksum signed_index_signature signed_count
    local entry spdx_entries license_entries normalized_license_entries required_license_entry license_manifest
    for tool in awk cat cmp find grep mktemp openssl python3 sha256sum sort tar xz zstd; do
        require "$tool"
    done
    spdx_bundle=$(manifest_value spdx_bundle)
    license_archive=$(manifest_value license_archive)
    cve_report=$(manifest_value cve_report)
    cve_gate=$(manifest_value cve_gate)
    cve_database_evidence=$(manifest_value cve_database_evidence)
    cve_gate_as_of=$(manifest_value cve_gate_as_of)
    cve_gate_checked_at=$(manifest_value cve_gate_checked_at)
    cve_database_sha256=$(manifest_value cve_database_sha256)
    cve_database_mtime_utc=$(manifest_value cve_database_mtime_utc)
    cve_database_age_seconds=$(manifest_value cve_database_age_seconds)
    cve_database_max_age_seconds=$(manifest_value cve_database_max_age_seconds)
    kas_overlay=$(manifest_value kas_overlay)
    kas_overlay_sha256=$(manifest_value kas_overlay_sha256)
    bb_number_threads=$(manifest_value bb_number_threads)
    parallel_make_jobs=$(manifest_value parallel_make_jobs)
    mender_server_url=$(manifest_value mender_server_url)
    device_type=$(manifest_value device_type)
    signed_count=0

    if [[ "$board" == vm ]]; then
        expected_entries=$(printf '%s\n' \
            "Cosmopod-OS-$version-vm-x86_64.iso" \
            "Cosmopod-OS-$version-vm-x86_64.iso.xz" \
            "Cosmopod-OS-$version-vm-x86_64.qcow2" \
            "$spdx_bundle" "$license_archive" "$cve_report" "$cve_gate" \
            "$cve_database_evidence" \
            "$kas_overlay" BUILD-MANIFEST.txt SHA256SUMS smoke | sort)
    else
        signed_artifact="Cosmopod-OS-$version-$board.mender"
        signed_record="$signed_artifact.signing-record.txt"
        signed_checksum="$signed_artifact.sha256"
        signed_index_signature=SHA256SUMS.sig
        signed_count=0
        for evidence_name in "$signed_artifact" "$signed_record" "$signed_checksum" \
            "$signed_index_signature"; do
            [[ -e "$out_dir/$evidence_name" || -L "$out_dir/$evidence_name" ]] &&
                signed_count=$((signed_count + 1))
        done
        [[ "$signed_count" -eq 0 || "$signed_count" -eq 4 ]] || {
            echo "Signed Pi release sidecars are incomplete" >&2
            exit 1
        }
        expected_entries=$(printf '%s\n' \
            "Cosmopod-OS-$version-$board.img.xz" \
            "Cosmopod-OS-$version-$board-unsigned.mender" \
            "$spdx_bundle" "$license_archive" "$cve_report" "$cve_gate" \
            "$cve_database_evidence" \
            "$kas_overlay" BUILD-MANIFEST.txt SHA256SUMS | sort)
        if [[ "$signed_count" -eq 4 ]]; then
            expected_entries=$(printf '%s\n' "$expected_entries" \
                "$signed_artifact" "$signed_record" "$signed_checksum" \
                "$signed_index_signature" | sort)
        fi
    fi
    actual_entries=$(find "$out_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
    [[ "$actual_entries" == "$expected_entries" ]] || {
        echo "Release directory does not match the approved unsigned file set" >&2
        exit 1
    }
    while IFS= read -r entry; do
        [[ "$entry" == smoke ]] && continue
        [[ -f "$out_dir/$entry" && ! -L "$out_dir/$entry" ]] || {
            echo "Release entry is not one regular, non-symlinked file: $entry" >&2
            exit 1
        }
    done <<< "$expected_entries"
    checksum_entries=$(printf '%s\n' "$expected_entries" | grep -Fvx smoke)
    validate_checksum_index "$checksum_entries"
    [[ "$board" != vm ]] || validate_vm_smoke_evidence
    if [[ "$board" != vm && "$signed_count" -eq 4 ]]; then
        openssl dgst -sha256 \
            -verify "$root/meta-cosmopod/recipes-mender/mender/files/artifact-verify-key.pem" \
            -signature "$out_dir/$signed_index_signature" \
            "$out_dir/SHA256SUMS" >/dev/null
    fi

    for evidence_name in "$spdx_bundle" "$license_archive" "$cve_report" \
        "$cve_gate" "$cve_database_evidence" "$kas_overlay"; do
        evidence_path="$out_dir/$evidence_name"
        [[ -f "$evidence_path" && -s "$evidence_path" && ! -L "$evidence_path" ]] || {
            echo "Required release security evidence is missing, empty, or symlinked: $evidence_name" >&2
            exit 1
        }
    done
    [[ "$(sha256sum "$out_dir/$kas_overlay" | awk '{print $1}')" == "$kas_overlay_sha256" ]] || {
        echo "KAS overlay does not match its build-manifest digest" >&2
        exit 1
    }
    expected_overlay_text=$(cat <<EOF
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
    BB_NUMBER_THREADS = "$bb_number_threads"
    PARALLEL_MAKE = "-j $parallel_make_jobs"
    COSMOPOD_ALLOW_UNCONFINED_TASK_NETWORK = "false"
EOF
)
    [[ "$(<"$out_dir/$kas_overlay")" == "$expected_overlay_text" ]] || {
        echo "KAS overlay does not reproduce from recorded build inputs" >&2
        exit 1
    }
    spdx_entries=$(mktemp "${TMPDIR:-/tmp}/cosmopod-spdx-entries.XXXXXX")
    license_entries=$(mktemp "${TMPDIR:-/tmp}/cosmopod-license-entries.XXXXXX")
    temp_files+=("$spdx_entries" "$license_entries")
    zstd --test --quiet "$out_dir/$spdx_bundle"
    zstd --decompress --stdout --quiet "$out_dir/$spdx_bundle" |
        tar -tf - > "$spdx_entries"
    validate_archive_paths "$spdx_entries" "SPDX"
    grep -Eq '(^|/)[^/]+\.spdx\.json$' "$spdx_entries" || {
        echo "SPDX archive contains no SPDX JSON document" >&2
        exit 1
    }
    xz --test --verbose "$out_dir/$license_archive"
    tar -tJf "$out_dir/$license_archive" > "$license_entries"
    validate_archive_paths "$license_entries" "License"
    normalized_license_entries=$(mktemp \
        "${TMPDIR:-/tmp}/cosmopod-license-normalized.XXXXXX")
    license_manifest=$(mktemp \
        "${TMPDIR:-/tmp}/cosmopod-license-manifest.XXXXXX")
    temp_files+=("$normalized_license_entries" "$license_manifest")
    sed 's|^\./||' "$license_entries" > "$normalized_license_entries"
    for required_license_entry in \
        image_license.manifest license.manifest package.manifest; do
        [[ $(grep -Fxc "$required_license_entry" \
            "$normalized_license_entries") -eq 1 ]] || {
            echo "License archive must contain exactly one $required_license_entry" >&2
            exit 1
        }
    done
    tar -xJOf "$out_dir/$license_archive" ./license.manifest > "$license_manifest"
    [[ -s "$license_manifest" ]] || {
        echo "Extracted license manifest is empty" >&2
        exit 1
    }
    if [[ "$channel" == release ]]; then
        cve_decision=PASS
    else
        cve_decision=$(sed -n 's/^decision=//p' "$out_dir/$cve_gate")
        [[ "$cve_decision" == PASS || "$cve_decision" == FAIL ]] || {
            echo "Development CVE gate contains an invalid decision" >&2
            exit 1
        }
    fi
    [[ $(grep -Fxc 'format=cosmopod-cve-gate-v4' "$out_dir/$cve_gate") -eq 1 &&
       $(grep -Fxc "as_of=$cve_gate_as_of" "$out_dir/$cve_gate") -eq 1 &&
       $(grep -Fxc "evaluated_at=$cve_gate_checked_at" "$out_dir/$cve_gate") -eq 1 &&
       $(grep -Fxc "report_sha256=$(sha256sum "$out_dir/$cve_report" | awk '{print $1}')" "$out_dir/$cve_gate") -eq 1 &&
       $(grep -Fxc "waivers_sha256=$(sha256sum "$root/security/cve-waivers.json" | awk '{print $1}')" "$out_dir/$cve_gate") -eq 1 &&
       $(grep -Fxc "license_manifest_sha256=$(sha256sum "$license_manifest" | awk '{print $1}')" "$out_dir/$cve_gate") -eq 1 &&
       $(grep -Fxc "database_evidence_sha256=$(sha256sum "$out_dir/$cve_database_evidence" | awk '{print $1}')" "$out_dir/$cve_gate") -eq 1 &&
       $(grep -Fxc "database_sha256=$cve_database_sha256" "$out_dir/$cve_gate") -eq 1 &&
       $(grep -Fxc "database_mtime_utc=$cve_database_mtime_utc" "$out_dir/$cve_gate") -eq 1 &&
       $(grep -Fxc "database_age_seconds=$cve_database_age_seconds" "$out_dir/$cve_gate") -eq 1 &&
       $(grep -Fxc "database_max_age_seconds=$cve_database_max_age_seconds" "$out_dir/$cve_gate") -eq 1 &&
       $(grep -Fxc 'database_fresh=true' "$out_dir/$cve_gate") -eq 1 &&
       $(grep -Fxc 'coverage_complete=true' "$out_dir/$cve_gate") -eq 1 &&
       $(grep -Fxc "decision=$cve_decision" "$out_dir/$cve_gate") -eq 1 ]] || {
        echo "Recorded CVE gate evidence is invalid or did not pass" >&2
        exit 1
    }

    replay=$(mktemp "${COSMOPOD_BUILD_ROOT:-"$HOME/.cache/cosmopod-os"}/$board-cve-gate.XXXXXX.txt")
    temp_files+=("$replay")
    set +e
    python3 "$root/scripts/check-cve-report.py" \
        --report "$out_dir/$cve_report" \
        --waivers "$root/security/cve-waivers.json" \
        --license-manifest "$license_manifest" \
        --database-evidence "$out_dir/$cve_database_evidence" \
        --verification-at "$cve_gate_checked_at" \
        --as-of "$cve_gate_as_of" \
        --output "$replay" >/dev/null
    replay_status=$?
    set -e
    if ((replay_status != 0)); then
        [[ "$channel" == development && "$cve_decision" == FAIL &&
           "$replay_status" -eq 1 ]] || {
            echo "CVE gate replay failed" >&2
            exit 1
        }
    fi
    cmp -s -- "$out_dir/$cve_gate" "$replay" || {
        echo "Recorded CVE gate evidence does not reproduce from trusted inputs" >&2
        exit 1
    }
}

partition_value() {
    local image=$1 number=$2 tag=$3 start sectors
    read -r start sectors < <(partx -g -n "$number" -o START,SECTORS "$image")
    [[ -n "$start" && -n "$sectors" ]] || return 1
    blkid -p -D -O $((start * 512)) -S $((sectors * 512)) \
        -s "$tag" -o value "$image"
}

validate_pi() {
    local image mender raw rootfs device_type artifact_tool os_release metadata
    local signed signed_record signed_checksum signed_metadata public
    local approved_build_index approved_unsigned
    image="Cosmopod-OS-$version-$board.img.xz"
    mender="Cosmopod-OS-$version-$board-unsigned.mender"
    if [[ "$board" == pi4 ]]; then
        device_type=cosmopod-rpi4-64
    else
        device_type=cosmopod-rpi5
    fi

    for tool in xz file fdisk sfdisk partx blkid debugfs; do require "$tool"; done
    xz --test --verbose "$image"
    file "$image" "$mender"

    mkdir -p "${COSMOPOD_BUILD_ROOT:-"$HOME/.cache/cosmopod-os"}"
    raw=$(mktemp "${COSMOPOD_BUILD_ROOT:-"$HOME/.cache/cosmopod-os"}/$board-validate.XXXXXX.img")
    temp_files+=("$raw")
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

    artifact_tool=${MENDER_ARTIFACT:-$(find "$tmp_dir/work/x86_64-linux/mender-artifact-native" \
        -type f -executable \( -path '*/build/bin/mender-artifact' -o -path '*/usr/bin/mender-artifact' \) \
        -print -quit)}
    [[ -x "$artifact_tool" ]] || { echo "Missing mender-artifact: $artifact_tool" >&2; exit 1; }
    "$artifact_tool" validate "$mender"
    metadata=$("$artifact_tool" read "$mender")
    printf '%s\n' "$metadata"
    grep -Fq "cosmopod-os-$version-$board" <<<"$metadata"
    grep -Fq "$device_type" <<<"$metadata"

    signed="Cosmopod-OS-$version-$board.mender"
    signed_record="$signed.signing-record.txt"
    signed_checksum="$signed.sha256"
    if [[ -f "$signed" ]]; then
        public="$root/meta-cosmopod/recipes-mender/mender/files/artifact-verify-key.pem"
        (cd "$out_dir" && sha256sum --check --strict "$signed_checksum")
        "$artifact_tool" validate "$signed" -k "$public"
        signed_metadata=$("$artifact_tool" read "$signed")
        grep -Fq "cosmopod-os-$version-$board" <<<"$signed_metadata"
        grep -Fq "$device_type" <<<"$signed_metadata"
        grep -Fqx 'format=cosmopod-signing-record-v2' "$signed_record"
        grep -Fqx "artifact_name=cosmopod-os-$version-$board" "$signed_record"
        grep -Fqx "device_type=$device_type" "$signed_record"
        grep -Fqx "source_commit=$(manifest_value source_commit)" "$signed_record"
        [[ $(grep -Ec '^approved_build_index_sha256=[0-9a-f]{64}$' "$signed_record") -eq 1 ]]
        approved_build_index=$(sed -n 's/^approved_build_index_sha256=//p' "$signed_record")
        [[ "$approved_build_index" =~ ^[0-9a-f]{64}$ ]]
        approved_unsigned=$(sha256sum "$mender" | awk '{print $1}')
        grep -Fqx "approved_unsigned_artifact_sha256=$approved_unsigned" "$signed_record"
        grep -Fqx "unsigned_artifact_sha256=$(sha256sum "$mender" | awk '{print $1}')" "$signed_record"
        grep -Fqx "signed_artifact_sha256=$(sha256sum "$signed" | awk '{print $1}')" "$signed_record"
        grep -Fqx "build_manifest_sha256=$(sha256sum BUILD-MANIFEST.txt | awk '{print $1}')" "$signed_record"
        grep -Fqx "spdx_bundle_sha256=$(sha256sum "$(manifest_value spdx_bundle)" | awk '{print $1}')" "$signed_record"
        grep -Fqx "license_archive_sha256=$(sha256sum "$(manifest_value license_archive)" | awk '{print $1}')" "$signed_record"
        grep -Fqx "cve_report_sha256=$(sha256sum "$(manifest_value cve_report)" | awk '{print $1}')" "$signed_record"
        grep -Fqx "cve_gate_sha256=$(sha256sum "$(manifest_value cve_gate)" | awk '{print $1}')" "$signed_record"
        grep -Fqx "cve_database_evidence_sha256=$(sha256sum "$(manifest_value cve_database_evidence)" | awk '{print $1}')" "$signed_record"
        grep -Fqx 'unsigned_rejected=true' "$signed_record"
        grep -Fqx 'wrong_key_rejected=true' "$signed_record"
        grep -Fqx 'release_index_authenticated=true' "$signed_record"
    fi

    rootfs=$(image_rootfs)
    os_release=$(mktemp "${COSMOPOD_BUILD_ROOT:-"$HOME/.cache/cosmopod-os"}/$board-os-release.XXXXXX")
    temp_files+=("$os_release")
    debugfs -R 'cat /usr/lib/os-release' "$rootfs" > "$os_release" 2>/dev/null
    [[ -s "$os_release" ]]
    grep -q '^ID=cosmopod$' "$os_release"
    grep -q '^NAME="Cosmopod OS"$' "$os_release"
    grep -q "^VERSION_ID=$version$" "$os_release"
    grep -E '^(ID|NAME|VERSION_ID)=' "$os_release"
}

validate_vm() {
    local iso iso_archive qcow qemu_img isoinfo converted listing os_release archive_size
    local kernel_config kernel_control
    iso="Cosmopod-OS-$version-vm-x86_64.iso"
    iso_archive="$iso.xz"
    qcow="Cosmopod-OS-$version-vm-x86_64.qcow2"
    for tool in cmp file fdisk sfdisk partx blkid stat xz; do require "$tool"; done
    file "$iso" "$iso_archive" "$qcow"
    xz --test --verbose "$iso_archive"
    archive_size=$(stat -c '%s' "$iso_archive")
    ((archive_size < 2147483648)) || {
        echo "Compressed ISO exceeds GitHub's per-asset 2 GiB limit" >&2
        exit 1
    }
    xz -dc -- "$iso_archive" | cmp -s -- "$iso" - || {
        echo "Compressed ISO does not reproduce the release ISO" >&2
        exit 1
    }
    fdisk -l "$iso"

    qemu_img=${QEMU_IMG:-$(native_tool qemu-img)}
    isoinfo=${ISOINFO:-$(native_tool isoinfo)}
    [[ -x "$qemu_img" ]] || { echo "Missing qemu-img validator" >&2; exit 1; }
    [[ -x "$isoinfo" ]] || { echo "Missing isoinfo validator" >&2; exit 1; }

    kernel_config="$tmp_dir/work-shared/genericx86-64/kernel-build-artifacts/.config"
    [[ -s "$kernel_config" ]] || {
        echo "Missing final VM kernel configuration: $kernel_config" >&2
        exit 1
    }
    for kernel_control in \
        CONFIG_HYPERVISOR_GUEST=y \
        CONFIG_HYPERV_NET=y \
        CONFIG_HYPERV_STORAGE=y \
        CONFIG_HYPERV_KEYBOARD=y \
        CONFIG_HID_HYPERV_MOUSE=y \
        CONFIG_DRM_HYPERV=y \
        CONFIG_DRM_SIMPLEDRM=y \
        CONFIG_DRM_VIRTIO_GPU=y; do
        grep -Fqx "$kernel_control" "$kernel_config" || {
            echo "Final VM kernel config lacks required control: $kernel_control" >&2
            exit 1
        }
    done
    grep -Fqx '# CONFIG_FB_HYPERV is not set' "$kernel_config" || {
        echo "Legacy Hyper-V framebuffer must be disabled in favor of DRM" >&2
        exit 1
    }

    "$qemu_img" info --output=json "$qcow"
    "$qemu_img" check -f qcow2 "$qcow"

    converted=$(mktemp "${COSMOPOD_BUILD_ROOT:-"$HOME/.cache/cosmopod-os"}/vm-validate.XXXXXX.raw")
    temp_files+=("$converted")
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

    os_release=$(find "$tmp_dir/work/genericx86_64-poky-linux/cosmopod-image" \
        -path '*/rootfs/etc/os-release' -type f -print -quit)
    [[ -n "$os_release" ]]
    grep -q '^ID=cosmopod$' "$os_release"
    grep -q '^NAME="Cosmopod OS"$' "$os_release"
    grep -q "^VERSION_ID=$version$" "$os_release"
    grep -E '^(ID|NAME|VERSION_ID)=' "$os_release"
}

validate_manifest
validate_security_evidence

if [[ "$board" == vm ]]; then
    validate_vm
else
    validate_pi
fi

if [[ "$channel" == release ]]; then
    echo "PASS Cosmopod OS $version $board release artifact validation"
else
    echo "PASS Cosmopod OS $version $board development artifact integrity validation (CVE decision: $cve_decision; not release-qualified)"
fi
