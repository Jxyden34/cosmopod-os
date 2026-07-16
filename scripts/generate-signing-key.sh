#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
key_dir=${COSMOPOD_KEY_DIR:-"$HOME/.config/cosmopod-os/keys"}
private="$key_dir/artifact-signing-private.pem"
public="$key_dir/artifact-signing-public.pem"
device_public="$root/meta-cosmopod/recipes-mender/mender/files/artifact-verify-key.pem"

[[ "${1:-}" == "--replace-device-key" && $# -eq 1 ]] || {
    echo "Usage: scripts/generate-signing-key.sh --replace-device-key" >&2
    echo "This initializes a local pair and replaces trust in future factory images." >&2
    exit 2
}

if [[ -e "$private" || -e "$public" ]]; then
    echo "Signing key already exists. Refusing unsafe in-place rotation." >&2
    exit 1
fi

umask 077
install -d -m 0700 "$key_dir"
openssl genpkey -algorithm RSA -out "$private" -pkeyopt rsa_keygen_bits:3072
openssl rsa -in "$private" -pubout -out "$public"
install -m 0644 "$public" "$device_public"

cat <<EOF
Created:
  private: $private
  public:  $device_public

Back up private key offline. Rebuild all factory images before using this key.
EOF
