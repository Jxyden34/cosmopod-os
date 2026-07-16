#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
    echo "Usage: scripts/sign-release.sh PATH/TO/*-unsigned.mender" >&2
}

[[ $# -eq 1 ]] || { usage; exit 2; }
input=$(realpath "$1")
[[ -f "$input" && "$input" == *-unsigned.mender ]] || {
    echo "Input must be an existing *-unsigned.mender file" >&2
    exit 2
}

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
key_dir=${COSMOPOD_KEY_DIR:-"$HOME/.config/cosmopod-os/keys"}
private="$key_dir/artifact-signing-private.pem"
public="$root/meta-cosmopod/recipes-mender/mender/files/artifact-verify-key.pem"
output=${input%-unsigned.mender}.mender

[[ -s "$private" ]] || { echo "Missing private key: $private" >&2; exit 1; }
command -v mender-artifact >/dev/null || {
    echo "mender-artifact is required. Install stable workstation tools from docs.mender.io." >&2
    exit 1
}

[[ ! -e "$output" ]] || { echo "Refusing to overwrite $output" >&2; exit 1; }
mender-artifact sign "$input" -k "$private" -o "$output"
mender-artifact validate "$output" -k "$public"

(
    cd "$(dirname "$output")"
    sha256sum "$(basename "$output")" > "$(basename "$output").sha256"
    find . -maxdepth 1 -type f \
        ! -name SHA256SUMS ! -name '.SHA256SUMS.tmp' \
        -print0 | sort -z | xargs -0 sha256sum > .SHA256SUMS.tmp
    mv -- .SHA256SUMS.tmp SHA256SUMS
)

echo "Signed and verified: $output"
