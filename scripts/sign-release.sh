#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: scripts/sign-release.sh --approve-server-url https://HOST \
  --approve-build-index-sha256 SHA256 \
  --approve-unsigned-sha256 SHA256 PATH/TO/*-unsigned.mender
EOF
}

[[ $# -eq 7 && "$1" == --approve-server-url &&
   "$3" == --approve-build-index-sha256 &&
   "$5" == --approve-unsigned-sha256 ]] || { usage; exit 2; }
approved_server_url=$2
approved_build_index_sha256=$4
approved_unsigned_sha256=$6
input=$(realpath -- "$7")
[[ "$approved_build_index_sha256" =~ ^[0-9a-f]{64}$ &&
   "$approved_unsigned_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Approved digests must be lowercase SHA-256 values" >&2
    exit 2
}
[[ -f "$input" && "$input" == *-unsigned.mender ]] || {
    echo "Input must be an existing *-unsigned.mender file" >&2
    exit 2
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
root=$(cd -- "$script_dir/.." && pwd -P)
# shellcheck source=release-common.sh
source "$script_dir/release-common.sh"

input_name=$(basename -- "$input")
input_pattern='^Cosmopod-OS-([0-9A-Za-z][0-9A-Za-z._+-]{0,63})-(pi4|pi5)-unsigned\.mender$'
[[ "$input_name" =~ $input_pattern ]] || {
    echo "Unsigned artifact filename is not an approved Pi release name" >&2
    exit 1
}
version=${BASH_REMATCH[1]}
board=${BASH_REMATCH[2]}
source_release_dir=$(dirname -- "$input")
expected_input="$root/out/$version/$board-release/$input_name"
[[ "$input" == "$expected_input" && "$source_release_dir" == "$root/out/$version/$board-release" ]] || {
    echo "Unsigned artifact must be under the trusted checkout: $expected_input" >&2
    exit 1
}
validate_https_origin "$approved_server_url" || {
    echo "Approved Mender server URL must be one canonical HTTPS origin" >&2
    exit 2
}

case "$board" in
    pi4)
        expected_machine=raspberrypi4-64
        expected_device_type=cosmopod-rpi4-64
        expected_kas=kas/raspberrypi4.yml
        ;;
    pi5)
        expected_machine=raspberrypi5
        expected_device_type=cosmopod-rpi5
        expected_kas=kas/raspberrypi5.yml
        ;;
    *) echo "Signing helper accepts Pi release artifacts only" >&2; exit 1 ;;
esac

spdx_bundle="Cosmopod-OS-$version-$board-spdx.tar.zst"
license_archive="Cosmopod-OS-$version-$board-licenses.tar.xz"
cve_report="Cosmopod-OS-$version-$board-cve.json"
cve_gate="Cosmopod-OS-$version-$board-cve-gate.txt"
cve_database_evidence="Cosmopod-OS-$version-$board-cve-database.txt"
kas_overlay=BUILD-KAS-OVERLAY.yml
unsigned_entries=$(printf '%s\n' \
    "Cosmopod-OS-$version-$board.img.xz" \
    "$input_name" \
    "$spdx_bundle" \
    "$license_archive" \
    "$cve_report" \
    "$cve_gate" \
    "$cve_database_evidence" \
    "$kas_overlay" \
    BUILD-MANIFEST.txt \
    SHA256SUMS | sort)

key_dir=${COSMOPOD_KEY_DIR:-"$HOME/.config/cosmopod-os/keys"}
private="$key_dir/artifact-signing-private.pem"
public="$root/meta-cosmopod/recipes-mender/mender/files/artifact-verify-key.pem"
output_name=${input_name%-unsigned.mender}.mender
record_name="$output_name.signing-record.txt"
artifact_checksum_name="$output_name.sha256"
index_signature_name=SHA256SUMS.sig
output="$source_release_dir/$output_name"
record="$source_release_dir/$record_name"
artifact_checksum="$source_release_dir/$artifact_checksum_name"
index_signature="$source_release_dir/$index_signature_name"
checksum_file="$source_release_dir/SHA256SUMS"
signed_entries=$(printf '%s\n' "$unsigned_entries" \
    "$output_name" "$record_name" "$artifact_checksum_name" "$index_signature_name" | sort)

for tool in awk basename cat cmp cp date find git grep ln mender-artifact mkdir \
    mktemp mv openssl python3 readlink realpath rm sed sha256sum sort stat tar \
    xargs xz zstd; do
    command -v "$tool" >/dev/null || {
        echo "$tool is required for offline release signing" >&2
        exit 1
    }
done
[[ -s "$private" ]] || { echo "Missing private key: $private" >&2; exit 1; }
[[ -s "$public" && ! -L "$public" ]] || {
    echo "Missing or symlinked verification key: $public" >&2
    exit 1
}
private_mode=$(stat -c '%a' "$private")
[[ "$private_mode" == 400 || "$private_mode" == 600 ]] || {
    echo "Private signing key must have mode 0400 or 0600, not $private_mode" >&2
    exit 1
}

validate_regular_file_set() {
    local directory=$1 expected_entries=$2 error_message=$3
    local actual_entries entry
    [[ -d "$directory" && ! -L "$directory" ]] || {
        echo "$error_message" >&2
        return 1
    }
    actual_entries=$(find "$directory" -mindepth 1 -maxdepth 1 \
        ! -name .cosmopod-sign.lock -printf '%f\n' | sort)
    [[ "$actual_entries" == "$expected_entries" ]] || {
        echo "$error_message" >&2
        return 1
    }
    while IFS= read -r entry; do
        [[ -f "$directory/$entry" && ! -L "$directory/$entry" ]] || {
            echo "Release entry is not one regular, non-symlinked file: $entry" >&2
            return 1
        }
    done <<< "$expected_entries"
}

validate_checksum_index() {
    local directory=$1 expected_entries=$2
    local index="$directory/SHA256SUMS"
    local expected_checksum_entries actual_checksum_entries
    [[ -s "$index" && ! -L "$index" ]] || {
        echo "Release checksum index is missing, empty, or symlinked" >&2
        return 1
    }
    if LC_ALL=C grep -Eqv \
        '^[0-9a-f]{64}  \./[0-9A-Za-z][0-9A-Za-z._+-]*$' "$index"; then
        echo "Release checksum index contains an unsafe or malformed record" >&2
        return 1
    fi
    expected_checksum_entries=$(printf '%s\n' "$expected_entries" |
        grep -Fvx SHA256SUMS | grep -Fvx SHA256SUMS.sig | sort)
    actual_checksum_entries=$(awk '{
        name=$2
        sub(/^\.\//, "", name)
        print name
    }' "$index" | sort)
    [[ "$actual_checksum_entries" == "$expected_checksum_entries" ]] || {
        echo "Release checksum index does not cover the exact approved file set" >&2
        return 1
    }
    (
        cd -- "$directory"
        sha256sum --check --strict SHA256SUMS
    )
}

verify_unsigned_release() {
    local directory=$1 index_hash artifact_hash
    validate_regular_file_set "$directory" "$unsigned_entries" \
        "Release directory does not match the approved unsigned Pi file set"
    validate_checksum_index "$directory" "$unsigned_entries"
    index_hash=$(sha256sum "$directory/SHA256SUMS" | awk '{print $1}')
    artifact_hash=$(sha256sum "$directory/$input_name" | awk '{print $1}')
    [[ "$index_hash" == "$approved_build_index_sha256" ]] || {
        echo "Release index does not match the independently approved build digest" >&2
        return 1
    }
    [[ "$artifact_hash" == "$approved_unsigned_sha256" ]] || {
        echo "Unsigned Artifact does not match the independently approved digest" >&2
        return 1
    }
}

verify_signed_release() {
    local directory=$1
    validate_regular_file_set "$directory" "$signed_entries" \
        "Release directory does not match the approved signed Pi file set"
    validate_checksum_index "$directory" "$signed_entries"
    openssl dgst -sha256 -verify "$public" \
        -signature "$directory/$index_signature_name" \
        "$directory/SHA256SUMS" >/dev/null
}

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

lock_dir="$source_release_dir/.cosmopod-sign.lock"
lock_token="${HOSTNAME:-unknown}:$$:$RANDOM:$RANDOM"
lock_owned=false
temp_dir=
release_temp_dir=
publish_started=false
publish_complete=false
checksum_next="$source_release_dir/.SHA256SUMS.next.$$.tmp"
checksum_restore="$source_release_dir/.SHA256SUMS.restore.$$.tmp"
snapshot_output=
snapshot_record=
snapshot_artifact_checksum=
snapshot_index_signature=

cleanup() {
    local status=$?
    if [[ "$publish_started" == true && "$publish_complete" != true ]]; then
        if [[ -n "$snapshot_output" && -e "$output" && "$output" -ef "$snapshot_output" ]]; then
            rm -f -- "$output"
        fi
        if [[ -n "$snapshot_record" && -e "$record" && "$record" -ef "$snapshot_record" ]]; then
            rm -f -- "$record"
        fi
        if [[ -n "$snapshot_artifact_checksum" && -e "$artifact_checksum" &&
              "$artifact_checksum" -ef "$snapshot_artifact_checksum" ]]; then
            rm -f -- "$artifact_checksum"
        fi
        if [[ -n "$snapshot_index_signature" && -e "$index_signature" &&
              "$index_signature" -ef "$snapshot_index_signature" ]]; then
            rm -f -- "$index_signature"
        fi
        if [[ -n "$release_temp_dir" && -f "$release_temp_dir/SHA256SUMS" &&
              -n "$temp_dir" && -f "$temp_dir/previous-SHA256SUMS" &&
              -f "$checksum_file" ]] &&
           cmp -s -- "$checksum_file" "$release_temp_dir/SHA256SUMS"; then
            cp -- "$temp_dir/previous-SHA256SUMS" "$checksum_restore"
            mv -- "$checksum_restore" "$checksum_file"
        fi
    fi
    rm -f -- "$checksum_next" "$checksum_restore"
    case "$temp_dir" in
        "${TMPDIR:-/tmp}"/cosmopod-sign-check.*) rm -rf -- "$temp_dir" ;;
    esac
    case "$release_temp_dir" in
        "$(dirname -- "$source_release_dir")"/.cosmopod-sign-output.*)
            rm -rf -- "$release_temp_dir"
            ;;
    esac
    if [[ "$lock_owned" == true && -f "$lock_dir/owner" ]] &&
       [[ "$(<"$lock_dir/owner")" == "$lock_token" ]]; then
        rm -rf -- "$lock_dir"
    fi
    return "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if ! mkdir -- "$lock_dir" 2>/dev/null; then
    echo "Release signing is locked: $lock_dir" >&2
    echo "Inspect its owner file; remove lock only after confirming no signer is running." >&2
    exit 1
fi
lock_owned=true
printf '%s\n' "$lock_token" > "$lock_dir/owner"

[[ ! -e "$output" && ! -e "$record" && ! -e "$artifact_checksum" &&
   ! -e "$index_signature" ]] || {
    echo "Refusing to overwrite signed output or signing evidence" >&2
    exit 1
}

# Authenticate the complete builder output before parsing any builder metadata.
# Copy into a private, non-hardlinked snapshot and authenticate the copy again.
verify_unsigned_release "$source_release_dir"
umask 077
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cosmopod-sign-check.XXXXXX")
release_temp_dir=$(mktemp -d \
    "$(dirname -- "$source_release_dir")/.cosmopod-sign-output.XXXXXX")
cp --archive --reflink=auto -- "$source_release_dir/." "$release_temp_dir/"
rm -rf -- "$release_temp_dir/.cosmopod-sign.lock"
verify_unsigned_release "$release_temp_dir"

snapshot_input="$release_temp_dir/$input_name"
manifest="$release_temp_dir/BUILD-MANIFEST.txt"
snapshot_output="$release_temp_dir/$output_name"
snapshot_record="$release_temp_dir/$record_name"
snapshot_artifact_checksum="$release_temp_dir/$artifact_checksum_name"
snapshot_index_signature="$release_temp_dir/$index_signature_name"
cp -- "$release_temp_dir/SHA256SUMS" "$temp_dir/previous-SHA256SUMS"

manifest_value() {
    local key=$1 value count
    count=$(grep -c "^${key}=" "$manifest" || true)
    [[ "$count" -eq 1 ]] || {
        echo "Build manifest must contain exactly one $key field" >&2
        return 1
    }
    value=$(sed -n "s/^${key}=//p" "$manifest")
    printf '%s\n' "$value"
}

[[ -s "$manifest" && ! -L "$manifest" ]] || {
    echo "Missing or symlinked build provenance: $manifest" >&2
    exit 1
}
[[ $(grep -Fxc 'format=cosmopod-build-manifest-v1' "$manifest") -eq 1 ]] || {
    echo "Unsupported or invalid build manifest" >&2
    exit 1
}
[[ $(grep -Fxc 'source_dirty=false' "$manifest") -eq 1 ]] || {
    echo "Refusing to sign an artifact built from dirty source" >&2
    exit 1
}
[[ $(grep -Fxc 'environment_sanitized=true' "$manifest") -eq 1 ]] || {
    echo "Refusing to sign a build without environment sanitization evidence" >&2
    exit 1
}

manifest_version=$(manifest_value version)
manifest_board=$(manifest_value board)
artifact_name=$(manifest_value artifact_name)
machine=$(manifest_value machine)
device_type=$(manifest_value device_type)
source_commit=$(manifest_value source_commit)
source_tree=$(manifest_value source_tree)
source_content_sha256=$(manifest_value source_content_sha256)
mender_server_url=$(manifest_value mender_server_url)
manifest_key_sha256=$(manifest_value verification_key_sha256)
manifest_spdx_bundle=$(manifest_value spdx_bundle)
manifest_license_archive=$(manifest_value license_archive)
manifest_cve_report=$(manifest_value cve_report)
manifest_cve_gate=$(manifest_value cve_gate)
manifest_cve_database_evidence=$(manifest_value cve_database_evidence)
cve_gate_as_of=$(manifest_value cve_gate_as_of)
cve_gate_checked_at=$(manifest_value cve_gate_checked_at)
cve_database_sha256=$(manifest_value cve_database_sha256)
cve_database_mtime_utc=$(manifest_value cve_database_mtime_utc)
cve_database_age_seconds=$(manifest_value cve_database_age_seconds)
cve_database_max_age_seconds=$(manifest_value cve_database_max_age_seconds)
manifest_kas_overlay=$(manifest_value kas_overlay)
kas_overlay_sha256=$(manifest_value kas_overlay_sha256)
bb_number_threads=$(manifest_value bb_number_threads)
parallel_make_jobs=$(manifest_value parallel_make_jobs)
kas_version=$(manifest_value kas_version)

[[ "$manifest_version" == "$version" && "$manifest_board" == "$board" ]] || {
    echo "Build manifest version or board disagrees with the approved path" >&2
    exit 1
}
[[ "$artifact_name" == "cosmopod-os-$version-$board" ]] || {
    echo "Build manifest artifact name does not match version and board" >&2
    exit 1
}
[[ "$machine" == "$expected_machine" && "$device_type" == "$expected_device_type" ]] || {
    echo "Build manifest board, machine, and device type disagree" >&2
    exit 1
}
[[ "$manifest_spdx_bundle" == "$spdx_bundle" &&
   "$manifest_license_archive" == "$license_archive" &&
   "$manifest_cve_report" == "$cve_report" &&
   "$manifest_cve_gate" == "$cve_gate" &&
   "$manifest_cve_database_evidence" == "$cve_database_evidence" &&
   "$cve_gate_as_of" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ &&
   "$cve_gate_checked_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ &&
   "$cve_database_sha256" =~ ^[0-9a-f]{64}$ &&
   "$cve_database_mtime_utc" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ &&
   "$cve_database_age_seconds" =~ ^[0-9]+$ &&
   "$cve_database_max_age_seconds" == 172800 ]] || {
    echo "Build manifest security evidence names or date are invalid" >&2
    exit 1
}
[[ "$manifest_kas_overlay" == "$kas_overlay" &&
   "$kas_overlay_sha256" =~ ^[0-9a-f]{64}$ &&
   "$bb_number_threads" =~ ^[1-9][0-9]?$ &&
   "$parallel_make_jobs" =~ ^[1-9][0-9]?$ &&
   "$kas_version" == 5.4 ]] || {
    echo "Build manifest KAS overlay evidence is invalid" >&2
    exit 1
}
[[ "$source_commit" =~ ^[0-9a-f]{40}$ &&
   "$source_tree" =~ ^[0-9a-f]{40}$ &&
   "$source_content_sha256" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Build manifest source identity is invalid" >&2
    exit 1
}
[[ "$(git -C "$root" rev-parse HEAD)" == "$source_commit" ]] || {
    echo "Build manifest source commit does not match trusted signing checkout" >&2
    exit 1
}
[[ "$(git -C "$root" rev-parse 'HEAD^{tree}')" == "$source_tree" ]] || {
    echo "Build manifest source tree does not match trusted signing checkout" >&2
    exit 1
}
[[ -z "$(git -C "$root" status --porcelain --untracked-files=normal)" ]] || {
    echo "Trusted signing checkout must be clean" >&2
    exit 1
}
[[ "$(git_source_fingerprint "$root")" == "$source_content_sha256" ]] || {
    echo "Build manifest source content does not match trusted signing checkout" >&2
    exit 1
}
validate_https_origin "$mender_server_url" || {
    echo "Invalid Mender server URL in build manifest" >&2
    exit 1
}
[[ "$mender_server_url" == "$approved_server_url" ]] || {
    echo "Approved server URL does not match the build manifest: $mender_server_url" >&2
    exit 1
}
public_sha256=$(sha256sum "$public" | awk '{print $1}')
[[ "$manifest_key_sha256" == "$public_sha256" ]] || {
    echo "Build manifest verification key does not match this signing workspace" >&2
    exit 1
}

verify_trusted_checkout() {
    [[ "$(git -C "$root" rev-parse HEAD)" == "$source_commit" &&
       "$(git -C "$root" rev-parse 'HEAD^{tree}')" == "$source_tree" &&
       -z "$(git -C "$root" status --porcelain --untracked-files=normal)" &&
       "$(git_source_fingerprint "$root")" == "$source_content_sha256" &&
       "$(sha256sum "$public" | awk '{print $1}')" == "$public_sha256" ]] || {
        echo "Trusted signing checkout changed during signing" >&2
        return 1
    }
}
verify_trusted_checkout

input_checks=$(awk '
    /^input_sha256_begin$/ { inside=1; next }
    /^input_sha256_end$/ { inside=0 }
    inside { print }
' "$manifest")
[[ -n "$input_checks" ]] || {
    echo "Build manifest input hashes are missing" >&2
    exit 1
}
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
printf '%s\n' "$input_checks" | (
    cd -- "$root"
    sha256sum --check --strict
)

for evidence_name in "$spdx_bundle" "$license_archive" "$cve_report" \
    "$cve_gate" "$cve_database_evidence" "$kas_overlay"; do
    evidence_path="$release_temp_dir/$evidence_name"
    [[ -f "$evidence_path" && -s "$evidence_path" && ! -L "$evidence_path" ]] || {
        echo "Required release security evidence is missing, empty, or symlinked: $evidence_name" >&2
        exit 1
    }
done

zstd --test --quiet "$release_temp_dir/$spdx_bundle"
zstd --decompress --stdout --quiet "$release_temp_dir/$spdx_bundle" |
    tar -tf - > "$temp_dir/spdx.entries"
validate_archive_paths "$temp_dir/spdx.entries" "SPDX"
grep -Eq '(^|/)[^/]+\.spdx\.json$' "$temp_dir/spdx.entries" || {
    echo "SPDX archive contains no SPDX JSON document" >&2
    exit 1
}

xz --test "$release_temp_dir/$license_archive"
tar -tJf "$release_temp_dir/$license_archive" > "$temp_dir/license.entries"
validate_archive_paths "$temp_dir/license.entries" "License"
sed 's|^\./||' "$temp_dir/license.entries" > "$temp_dir/license.entries.normalized"
for required_license_entry in \
    image_license.manifest license.manifest package.manifest; do
    [[ $(grep -Fxc "$required_license_entry" \
        "$temp_dir/license.entries.normalized") -eq 1 ]] || {
        echo "License archive must contain exactly one $required_license_entry" >&2
        exit 1
    }
done

tar -xJOf "$release_temp_dir/$license_archive" ./license.manifest \
    > "$temp_dir/license.manifest"
[[ -s "$temp_dir/license.manifest" ]] || {
    echo "Extracted license manifest is empty" >&2
    exit 1
}

[[ "$(sha256sum "$release_temp_dir/$kas_overlay" | awk '{print $1}')" == "$kas_overlay_sha256" ]] || {
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
EOF
)
[[ "$(<"$release_temp_dir/$kas_overlay")" == "$expected_overlay_text" ]] || {
    echo "KAS overlay does not reproduce from recorded build inputs" >&2
    exit 1
}
[[ $(grep -Fxc 'format=cosmopod-cve-gate-v3' "$release_temp_dir/$cve_gate") -eq 1 &&
   $(grep -Fxc "as_of=$cve_gate_as_of" "$release_temp_dir/$cve_gate") -eq 1 &&
   $(grep -Fxc "evaluated_at=$cve_gate_checked_at" "$release_temp_dir/$cve_gate") -eq 1 &&
   $(grep -Fxc "report_sha256=$(sha256sum "$release_temp_dir/$cve_report" | awk '{print $1}')" "$release_temp_dir/$cve_gate") -eq 1 &&
   $(grep -Fxc "waivers_sha256=$(sha256sum "$root/security/cve-waivers.json" | awk '{print $1}')" "$release_temp_dir/$cve_gate") -eq 1 &&
   $(grep -Fxc "license_manifest_sha256=$(sha256sum "$temp_dir/license.manifest" | awk '{print $1}')" "$release_temp_dir/$cve_gate") -eq 1 &&
   $(grep -Fxc "database_evidence_sha256=$(sha256sum "$release_temp_dir/$cve_database_evidence" | awk '{print $1}')" "$release_temp_dir/$cve_gate") -eq 1 &&
   $(grep -Fxc "database_sha256=$cve_database_sha256" "$release_temp_dir/$cve_gate") -eq 1 &&
   $(grep -Fxc "database_mtime_utc=$cve_database_mtime_utc" "$release_temp_dir/$cve_gate") -eq 1 &&
   $(grep -Fxc "database_age_seconds=$cve_database_age_seconds" "$release_temp_dir/$cve_gate") -eq 1 &&
   $(grep -Fxc "database_max_age_seconds=$cve_database_max_age_seconds" "$release_temp_dir/$cve_gate") -eq 1 &&
   $(grep -Fxc 'database_fresh=true' "$release_temp_dir/$cve_gate") -eq 1 &&
   $(grep -Fxc 'coverage_complete=true' "$release_temp_dir/$cve_gate") -eq 1 &&
   $(grep -Fxc 'decision=PASS' "$release_temp_dir/$cve_gate") -eq 1 ]] || {
    echo "Recorded CVE gate evidence is invalid or did not pass" >&2
    exit 1
}
python3 "$root/scripts/check-cve-report.py" \
    --report "$release_temp_dir/$cve_report" \
    --waivers "$root/security/cve-waivers.json" \
    --license-manifest "$temp_dir/license.manifest" \
    --database-evidence "$release_temp_dir/$cve_database_evidence" \
    --verification-at "$cve_gate_checked_at" \
    --as-of "$cve_gate_as_of" \
    --output "$temp_dir/cve-gate-replay.txt" >/dev/null
cmp -s -- "$release_temp_dir/$cve_gate" "$temp_dir/cve-gate-replay.txt" || {
    echo "Recorded CVE gate evidence does not reproduce from trusted inputs" >&2
    exit 1
}

metadata=$(mender-artifact read "$snapshot_input")
actual_name=$(sed -n 's/^  Name: //p' <<< "$metadata")
[[ $(grep -c '^  Name: ' <<< "$metadata") -eq 1 &&
   "$actual_name" == "$artifact_name" ]] || {
    echo "Unsigned artifact name does not match build manifest" >&2
    exit 1
}
actual_devices=$(sed -n 's/^  Compatible devices: \[\(.*\)\]$/\1/p' <<< "$metadata")
[[ $(grep -c '^  Compatible devices: ' <<< "$metadata") -eq 1 &&
   "$actual_devices" == "$device_type" ]] || {
    echo "Unsigned artifact device type does not match build manifest" >&2
    exit 1
}
[[ $(grep -Fxc '  Signature: no signature' <<< "$metadata") -eq 1 ]] || {
    echo "Input is not an unsigned Mender Artifact" >&2
    exit 1
}
[[ $(grep -Fxc '    - ArtifactCommit_Enter_50_cosmopod-health' <<< "$metadata") -eq 1 ]] || {
    echo "Unsigned artifact lacks the required post-update health state script" >&2
    exit 1
}
mender-artifact validate "$snapshot_input"
if mender-artifact validate "$snapshot_input" -k "$public" >/dev/null 2>&1; then
    echo "Unsigned artifact unexpectedly passed required-signature validation" >&2
    exit 1
fi

verify_trusted_checkout
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
    -out "$temp_dir/wrong-private.pem" >/dev/null 2>&1
openssl pkey -in "$temp_dir/wrong-private.pem" -pubout \
    -out "$temp_dir/wrong-public.pem" >/dev/null 2>&1

mender-artifact sign "$snapshot_input" -k "$private" -o "$snapshot_output"
mender-artifact validate "$snapshot_output" -k "$public"
if mender-artifact validate "$snapshot_output" \
    -k "$temp_dir/wrong-public.pem" >/dev/null 2>&1; then
    echo "Signed artifact unexpectedly passed wrong-key validation" >&2
    exit 1
fi

signed_sha256=$(sha256sum "$snapshot_output" | awk '{print $1}')
{
    printf 'format=cosmopod-signing-record-v2\n'
    printf 'artifact_name=%s\n' "$artifact_name"
    printf 'device_type=%s\n' "$device_type"
    printf 'source_commit=%s\n' "$source_commit"
    printf 'source_tree=%s\n' "$source_tree"
    printf 'source_content_sha256=%s\n' "$source_content_sha256"
    printf 'mender_server_url=%s\n' "$mender_server_url"
    printf 'signed_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'approved_build_index_sha256=%s\n' "$approved_build_index_sha256"
    printf 'approved_unsigned_artifact_sha256=%s\n' "$approved_unsigned_sha256"
    printf 'unsigned_artifact_sha256=%s\n' "$approved_unsigned_sha256"
    printf 'signed_artifact_sha256=%s\n' "$signed_sha256"
    printf 'verification_key_sha256=%s\n' "$public_sha256"
    printf 'build_manifest_sha256=%s\n' "$(sha256sum "$manifest" | awk '{print $1}')"
    printf 'spdx_bundle_sha256=%s\n' \
        "$(sha256sum "$release_temp_dir/$spdx_bundle" | awk '{print $1}')"
    printf 'license_archive_sha256=%s\n' \
        "$(sha256sum "$release_temp_dir/$license_archive" | awk '{print $1}')"
    printf 'cve_report_sha256=%s\n' \
        "$(sha256sum "$release_temp_dir/$cve_report" | awk '{print $1}')"
    printf 'cve_gate_sha256=%s\n' \
        "$(sha256sum "$release_temp_dir/$cve_gate" | awk '{print $1}')"
    printf 'cve_database_evidence_sha256=%s\n' \
        "$(sha256sum "$release_temp_dir/$cve_database_evidence" | awk '{print $1}')"
    printf 'cve_gate_as_of=%s\n' "$cve_gate_as_of"
    printf 'cve_gate_checked_at=%s\n' "$cve_gate_checked_at"
    printf 'cve_database_sha256=%s\n' "$cve_database_sha256"
    printf 'cve_database_mtime_utc=%s\n' "$cve_database_mtime_utc"
    printf 'cve_database_age_seconds=%s\n' "$cve_database_age_seconds"
    printf 'cve_database_max_age_seconds=%s\n' "$cve_database_max_age_seconds"
    printf 'kas_overlay_sha256=%s\n' "$kas_overlay_sha256"
    printf 'unsigned_rejected=true\n'
    printf 'wrong_key_rejected=true\n'
    printf 'release_index_authenticated=true\n'
} > "$snapshot_record"
(
    cd -- "$release_temp_dir"
    sha256sum "$output_name" > "$artifact_checksum_name"
    find . -maxdepth 1 -type f \
        ! -name SHA256SUMS ! -name SHA256SUMS.sig -print0 |
        sort -z | xargs -0 sha256sum > "$temp_dir/SHA256SUMS.signed"
)
cp -- "$temp_dir/SHA256SUMS.signed" "$release_temp_dir/SHA256SUMS"
openssl dgst -sha256 -sign "$private" \
    -out "$snapshot_index_signature" "$release_temp_dir/SHA256SUMS"
verify_signed_release "$release_temp_dir"

# Re-authenticate the live unsigned directory immediately before publishing.
# Publish sidecars and the authenticated index first; the signed Artifact is the
# completion marker. Hard links refuse to overwrite unexpected paths.
verify_trusted_checkout
verify_unsigned_release "$source_release_dir"
[[ ! -e "$output" && ! -e "$record" && ! -e "$artifact_checksum" &&
   ! -e "$index_signature" ]] || {
    echo "Signed output appeared while signing; refusing to overwrite it" >&2
    exit 1
}
publish_started=true
ln -- "$snapshot_record" "$record"
ln -- "$snapshot_artifact_checksum" "$artifact_checksum"
ln -- "$snapshot_index_signature" "$index_signature"
cp -- "$release_temp_dir/SHA256SUMS" "$checksum_next"
mv -- "$checksum_next" "$checksum_file"
ln -- "$snapshot_output" "$output"
verify_signed_release "$source_release_dir"
mender-artifact validate "$output" -k "$public"
publish_complete=true

echo "Signed, authenticated, and verified: $output"
