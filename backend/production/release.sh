#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
# shellcheck source=../../scripts/release-common.sh
source "${ROOT}/scripts/release-common.sh"

action=""
server_url="https://kys.dpdns.org"
version=""
board=""
artifact=""
approved_sha256=""
ring=""
approved_ring=""
deployment_name=""
upload_record=""
previous_record=""
token_file=""
record_dir="${ROOT}/backend/.runtime/release-records"
apply_requested=0
stable_approved=0

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage:
  release.sh --action upload --version VERSION --board pi4|pi5 \
    --approve-artifact-sha256 SHA256 [--artifact FILE] [--apply --token-file FILE]

  release.sh --action deploy --version VERSION --board pi4|pi5 \
    --approve-artifact-sha256 SHA256 --ring RING --approve-ring RING \
    --deployment-name NAME --upload-record FILE [--previous-record FILE] \
    [--approve-stable] [--artifact FILE] [--apply --token-file FILE]

Options:
  --server-url URL                  HTTPS Mender origin
  --record-dir DIRECTORY           Operation receipt directory
  --apply                          Perform remote mutation; otherwise plan only
  --token-file FILE                Mode 0600 bearer-token file for --apply
  --help                           Show help

Allowed rings, in required order:
  ring-0-lab, ring-1-canary, ring-2-beta, ring-3-stable

Every artifact, signed index, signing record, signature, internal Artifact
name, compatible device type, and approved digest is verified before any API
request. Higher rings require previous-ring success receipts. Stable also
requires --approve-stable. Token value is read from a private file and placed
only in a mode-0600 temporary curl configuration, never command arguments.
EOF
}

require_value() {
    [[ -n "${2-}" && "${2-}" != --* ]] || fail "$1 requires a value"
}

while (($#)); do
    case "$1" in
        --action) require_value "$1" "${2-}"; action=$2; shift 2 ;;
        --server-url) require_value "$1" "${2-}"; server_url=$2; shift 2 ;;
        --version) require_value "$1" "${2-}"; version=$2; shift 2 ;;
        --board) require_value "$1" "${2-}"; board=$2; shift 2 ;;
        --artifact) require_value "$1" "${2-}"; artifact=$2; shift 2 ;;
        --approve-artifact-sha256) require_value "$1" "${2-}"; approved_sha256=$2; shift 2 ;;
        --ring) require_value "$1" "${2-}"; ring=$2; shift 2 ;;
        --approve-ring) require_value "$1" "${2-}"; approved_ring=$2; shift 2 ;;
        --deployment-name) require_value "$1" "${2-}"; deployment_name=$2; shift 2 ;;
        --upload-record) require_value "$1" "${2-}"; upload_record=$2; shift 2 ;;
        --previous-record) require_value "$1" "${2-}"; previous_record=$2; shift 2 ;;
        --token-file) require_value "$1" "${2-}"; token_file=$2; shift 2 ;;
        --record-dir) require_value "$1" "${2-}"; record_dir=$2; shift 2 ;;
        --apply) apply_requested=1; shift ;;
        --approve-stable) stable_approved=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
done

[[ "$action" =~ ^(upload|deploy)$ ]] || fail "--action must be upload or deploy"
[[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$ ]] || fail "invalid --version"
[[ "$board" =~ ^(pi4|pi5)$ ]] || fail "--board must be pi4 or pi5"
validate_https_origin "$server_url" || fail "--server-url must be one HTTPS origin without a path"
[[ "$approved_sha256" =~ ^[0-9a-f]{64}$ ]] || \
    fail "--approve-artifact-sha256 must be one lowercase SHA-256"
[[ "$record_dir" = /* ]] || record_dir="${ROOT}/${record_dir}"
[[ ! -L "$record_dir" ]] || fail "--record-dir must not be a symlink"

case "$board" in
    pi4) device_type=cosmopod-rpi4-64 ;;
    pi5) device_type=cosmopod-rpi5 ;;
esac
artifact_name="cosmopod-os-${version}-${board}"
release_dir="${ROOT}/out/${version}/${board}-release"
expected_artifact="${release_dir}/Cosmopod-OS-${version}-${board}.mender"
if [[ -z "$artifact" ]]; then
    artifact=$expected_artifact
fi

if [[ "$action" == deploy ]]; then
    [[ "$ring" =~ ^(ring-0-lab|ring-1-canary|ring-2-beta|ring-3-stable)$ ]] || \
        fail "invalid --ring"
    [[ "$approved_ring" == "$ring" ]] || fail "--approve-ring must exactly equal --ring"
    [[ "$deployment_name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{7,127}$ ]] || \
        fail "--deployment-name must contain 8-128 safe characters"
    [[ -n "$upload_record" ]] || fail "--upload-record is required for deployment"
    case "$ring" in
        ring-0-lab)
            [[ -z "$previous_record" ]] || fail "ring-0-lab must not use --previous-record"
            ;;
        ring-1-canary) required_previous_ring=ring-0-lab ;;
        ring-2-beta) required_previous_ring=ring-1-canary ;;
        ring-3-stable)
            required_previous_ring=ring-2-beta
            ((stable_approved == 1)) || fail "ring-3-stable requires --approve-stable"
            ;;
    esac
    if [[ -n "${required_previous_ring:-}" ]]; then
        [[ -n "$previous_record" ]] || fail "$ring requires --previous-record from $required_previous_ring"
    fi
else
    [[ -z "$ring" && -z "$approved_ring" && -z "$deployment_name" && \
       -z "$upload_record" && -z "$previous_record" && $stable_approved -eq 0 ]] || \
        fail "deployment-only options cannot be used with --action upload"
fi

for command_name in awk curl date grep head id install jq mktemp openssl realpath sed sha256sum stat; do
    command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done
artifact_tool=${MENDER_ARTIFACT:-}
if [[ -n "$artifact_tool" ]]; then
    [[ -x "$artifact_tool" ]] || fail "MENDER_ARTIFACT is not executable: $artifact_tool"
else
    artifact_tool=$(command -v mender-artifact 2>/dev/null) || \
        fail "required command not found: mender-artifact"
fi

release_dir=$(realpath -e -- "$release_dir") || fail "release directory not found"
artifact=$(realpath -e -- "$artifact") || fail "signed artifact not found"
expected_artifact=$(realpath -e -- "$expected_artifact") || fail "expected signed artifact not found"
[[ "$artifact" == "$expected_artifact" && ! -L "$artifact" ]] || \
    fail "artifact must be the trusted signed release output: $expected_artifact"

public_key="${ROOT}/meta-cosmopod/recipes-mender/mender/files/artifact-verify-key.pem"
index="${release_dir}/SHA256SUMS"
index_signature="${release_dir}/SHA256SUMS.sig"
signing_record="${artifact}.signing-record.txt"
for trusted_file in "$public_key" "$index" "$index_signature" "$signing_record"; do
    [[ -f "$trusted_file" && -s "$trusted_file" && ! -L "$trusted_file" ]] || \
        fail "trusted release evidence missing, empty, or symlinked: $trusted_file"
done

openssl dgst -sha256 -verify "$public_key" -signature "$index_signature" "$index" \
    >/dev/null || fail "release index signature verification failed"
(cd -- "$release_dir" && sha256sum --check --strict SHA256SUMS >/dev/null) || \
    fail "release index checksum verification failed"
actual_sha256=$(sha256sum -- "$artifact" | awk '{print $1}')
[[ "$actual_sha256" == "$approved_sha256" ]] || fail "artifact digest does not match approval"
[[ $(grep -Fxc 'format=cosmopod-signing-record-v2' "$signing_record") -eq 1 &&
   $(grep -Fxc "artifact_name=$artifact_name" "$signing_record") -eq 1 &&
   $(grep -Fxc "device_type=$device_type" "$signing_record") -eq 1 &&
   $(grep -Fxc "mender_server_url=$server_url" "$signing_record") -eq 1 &&
   $(grep -Fxc "signed_artifact_sha256=$actual_sha256" "$signing_record") -eq 1 &&
   $(grep -Fxc 'release_index_authenticated=true' "$signing_record") -eq 1 ]] || \
    fail "signing record does not match approved operation"

"$artifact_tool" validate "$artifact" -k "$public_key" >/dev/null || \
    fail "Mender Artifact signature validation failed"
metadata=$("$artifact_tool" read "$artifact")
actual_name=$(sed -n 's/^  Name: //p' <<< "$metadata")
actual_devices=$(sed -n 's/^  Compatible devices: \[\(.*\)\]$/\1/p' <<< "$metadata")
[[ $(grep -c '^  Name: ' <<< "$metadata") -eq 1 && "$actual_name" == "$artifact_name" ]] || \
    fail "internal Artifact name does not match release"
[[ $(grep -c '^  Compatible devices: ' <<< "$metadata") -eq 1 && \
   "$actual_devices" == "$device_type" ]] || fail "Artifact device compatibility does not match board"
[[ $(grep -c '^  Signature: ' <<< "$metadata") -eq 1 &&
   $(grep -Fxc '  Signature: no signature' <<< "$metadata") -eq 0 ]] || \
    fail "Artifact metadata does not report one signature"

verify_receipt() {
    local file=$1 expected_action=$2 expected_ring=${3-}
    file=$(realpath -e -- "$file") || fail "operation receipt not found: $1"
    [[ -f "$file" && -s "$file" && ! -L "$file" ]] || fail "invalid operation receipt: $file"
    [[ $(grep -Fxc 'format=cosmopod-backend-operation-v1' "$file") -eq 1 &&
       $(grep -Fxc "action=$expected_action" "$file") -eq 1 &&
       $(grep -Fxc "server_url=$server_url" "$file") -eq 1 &&
       $(grep -Fxc "artifact_name=$artifact_name" "$file") -eq 1 &&
       $(grep -Fxc "artifact_sha256=$actual_sha256" "$file") -eq 1 &&
       $(grep -Fxc 'result=PASS' "$file") -eq 1 ]] || fail "operation receipt does not match release"
    if [[ -n "$expected_ring" ]]; then
        [[ $(grep -Fxc "ring=$expected_ring" "$file") -eq 1 ]] || \
            fail "previous receipt is not for $expected_ring"
    fi
}

if [[ "$action" == deploy ]]; then
    verify_receipt "$upload_record" upload
    if [[ -n "${required_previous_ring:-}" ]]; then
        verify_receipt "$previous_record" deploy "$required_previous_ring"
    fi
fi

if ((apply_requested == 0)); then
    printf 'PLAN action=%s server=%s artifact=%s sha256=%s' \
        "$action" "$server_url" "$artifact_name" "$actual_sha256"
    [[ "$action" != deploy ]] || printf ' ring=%s deployment=%s' "$ring" "$deployment_name"
    printf '\nNo remote state changed. Add --apply --token-file FILE after review.\n'
    exit 0
fi

[[ -n "$token_file" ]] || fail "--token-file is required with --apply"
token_file=$(realpath -e -- "$token_file") || fail "token file not found"
[[ -f "$token_file" && ! -L "$token_file" ]] || fail "token file must be a regular non-symlink file"
token_mode=$(stat -c '%a' -- "$token_file")
token_owner=$(stat -c '%u' -- "$token_file")
[[ "$token_owner" == "$(id -u)" && $((8#$token_mode & 077)) -eq 0 ]] || \
    fail "token file must be owned by current user with mode 0600 or stricter"
token=$(<"$token_file")
[[ "$token" =~ ^[A-Za-z0-9._~-]{20,4096}$ ]] || fail "token file has invalid content"

umask 077
temporary_directory=$(mktemp -d)
curl_config="${temporary_directory}/curl.conf"
response_headers="${temporary_directory}/headers"
response_body="${temporary_directory}/body"
request_body="${temporary_directory}/request.json"
cleanup() {
    token=""
    rm -f -- "$curl_config" "$response_headers" "$response_body" "$request_body" \
        "${temporary_directory}/operation.record"
    rmdir -- "$temporary_directory"
}
trap cleanup EXIT
cat > "$curl_config" <<EOF
silent
show-error
proto = "=https"
tlsv1.2
connect-timeout = 15
max-time = 7200
retry = 2
retry-connrefused
header = "Accept: application/json"
header = "Authorization: Bearer ${token}"
EOF
token=""

mkdir -p -- "$record_dir"
[[ -d "$record_dir" && ! -L "$record_dir" ]] || fail "unsafe record directory"

if [[ "$action" == upload ]]; then
    artifact_size=$(stat -c '%s' -- "$artifact")
    http_status=$(curl --config "$curl_config" \
        --request POST \
        --form-string "size=$artifact_size" \
        --form-string "description=Cosmopod OS $version $board signed release" \
        --form "artifact=@${artifact};type=application/octet-stream" \
        --dump-header "$response_headers" \
        --output "$response_body" \
        --write-out '%{http_code}' \
        "${server_url}/api/management/v1/deployments/artifacts") || \
        fail "artifact upload request failed"
    [[ "$http_status" == 201 ]] || {
        head -c 4096 "$response_body" >&2 || true
        fail "artifact upload returned HTTP $http_status"
    }
    expected_location_prefix='/api/management/v1/deployments/artifacts/'
    record_basename="upload-${artifact_name}-${actual_sha256:0:12}.record"
else
    jq -n --arg name "$deployment_name" --arg artifact "$artifact_name" \
        '{name:$name, artifact_name:$artifact, retries:3}' > "$request_body"
    http_status=$(curl --config "$curl_config" \
        --request POST \
        --header 'Content-Type: application/json' \
        --data-binary "@${request_body}" \
        --dump-header "$response_headers" \
        --output "$response_body" \
        --write-out '%{http_code}' \
        "${server_url}/api/management/v1/deployments/deployments/group/${ring}") || \
        fail "deployment creation request failed"
    [[ "$http_status" == 201 ]] || {
        head -c 4096 "$response_body" >&2 || true
        fail "deployment creation returned HTTP $http_status"
    }
    expected_location_prefix='/api/management/v1/deployments/deployments/'
    record_basename="deploy-${ring}-${deployment_name}.record"
fi

location=$(awk 'tolower($1) == "location:" {sub(/\r$/, "", $2); print $2}' "$response_headers")
[[ $(grep -ic '^location:' "$response_headers") -eq 1 ]] || fail "response lacks one Location header"
case "$location" in
    "$expected_location_prefix"*|"$server_url$expected_location_prefix"*) ;;
    *) fail "response Location is outside expected Mender API path" ;;
esac

record_path="${record_dir}/${record_basename}"
[[ ! -e "$record_path" && ! -L "$record_path" ]] || fail "operation receipt already exists: $record_path"
{
    printf 'format=cosmopod-backend-operation-v1\n'
    printf 'action=%s\n' "$action"
    printf 'server_url=%s\n' "$server_url"
    printf 'version=%s\n' "$version"
    printf 'board=%s\n' "$board"
    printf 'artifact_name=%s\n' "$artifact_name"
    printf 'device_type=%s\n' "$device_type"
    printf 'artifact_sha256=%s\n' "$actual_sha256"
    [[ "$action" != deploy ]] || printf 'ring=%s\ndeployment_name=%s\n' "$ring" "$deployment_name"
    printf 'location=%s\n' "$location"
    printf 'completed_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'result=PASS\n'
} > "${temporary_directory}/operation.record"
install -m 0600 -- "${temporary_directory}/operation.record" "$record_path"
rm -f -- "${temporary_directory}/operation.record"
printf 'PASS %s receipt=%s\n' "$action" "$record_path"
