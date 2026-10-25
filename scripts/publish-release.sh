#!/usr/bin/env bash
set -euo pipefail

[[ $# == 1 && $1 =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
    echo 'Usage: scripts/publish-release.sh VERSION' >&2
    exit 2
}
version=$1
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$root"
[[ "$(cat VERSION)" == "$version" && -z "$(git status --porcelain)" ]] || {
    echo 'Publish from the clean matching release checkout' >&2
    exit 1
}
command -v gh >/dev/null
# Reuse the full signature, provenance, CVE and integrity validators.
for board in vm pi4 pi5; do
    bash scripts/validate-artifacts.sh "$board" "$version" --channel release
done
for board in pi4 pi5; do
    test -s "out/$version/$board-release/Cosmopod-OS-$version-$board.mender"
    test -s "out/$version/$board-release/SHA256SUMS.sig"
done
if gh release view "v$version" --repo Jxyden34/cosmopod-os >/dev/null 2>&1; then
    echo 'Release already exists; refusing to overwrite assets' >&2
    exit 1
fi
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
for board in vm pi4 pi5; do
    directory="out/$version/$board-release"
    for file in "$directory"/*; do
        [[ -f "$file" && ! -L "$file" ]] || exit 1
        name=${file##*/}
        case "$name" in
            SHA256SUMS) name="SHA256SUMS-$board" ;;
            SHA256SUMS.sig) name="SHA256SUMS-$board.sig" ;;
            BUILD-MANIFEST.txt) name="BUILD-MANIFEST-$board.txt" ;;
            BUILD-KAS-OVERLAY.yml) name="BUILD-KAS-OVERLAY-$board.yml" ;;
            *.iso) continue ;;
            *.qcow2)
                xz -T0 -6 --stdout -- "$file" > "$stage/$name.xz"
                continue
                ;;
        esac
        test ! -e "$stage/$name"
        cp --reflink=auto -- "$file" "$stage/$name"
    done
done
for file in "$stage"/*; do
    (( $(stat -c '%s' "$file") < 2147483648 )) || {
        echo "Asset exceeds GitHub's per-file 2 GiB limit: ${file##*/}" >&2
        exit 1
    }
done
gh release create "v$version" "$stage"/* --repo Jxyden34/cosmopod-os \
    --target "$(git rev-parse HEAD)" --title "Cosmopod OS $version" --draft \
    --notes 'Signed standalone Pi updates and factory/VM media. Physical qualification and release approval must be reviewed before publishing this draft. See docs/UPDATE-SYSTEM.md for installation and recovery.'
echo 'Draft uploaded. Publish only after hardware, power-loss and signed update/rollback qualification passes.'
