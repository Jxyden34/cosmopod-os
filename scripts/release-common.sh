#!/usr/bin/env bash

# Shared release-input validation. Callers choose their own error messages.
validate_https_origin() {
    local origin=${1-} authority host port label
    local -a labels

    [[ "$origin" == https://* ]] || return 1
    authority=${origin#https://}
    [[ "$authority" =~ ^([A-Za-z0-9.-]+)(:([0-9]+))?$ ]] || return 1
    host=${BASH_REMATCH[1]}
    port=${BASH_REMATCH[3]:-}
    ((${#host} <= 253)) || return 1
    [[ "$host" != .* && "$host" != *. && "$host" != *..* ]] || return 1

    IFS=. read -r -a labels <<< "$host"
    ((${#labels[@]} > 0)) || return 1
    for label in "${labels[@]}"; do
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done

    if [[ -n "$port" ]]; then
        [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
        ((10#$port <= 65535)) || return 1
    fi
}

# Exact repository files allowed to influence a release build. Keeping this
# list shared prevents builder, validator, and offline signer policy drift.
release_input_paths() {
    local kas_config=${1-} kas_version=${2-}
    [[ "$kas_version" == 5.4 ]] || return 1
    case "$kas_config" in
        kas/raspberrypi4.yml|kas/raspberrypi5.yml|kas/vm-x86_64.yml) ;;
        *) return 1 ;;
    esac
    printf '%s\n' \
        scripts/build.sh \
        scripts/release-common.sh \
        "scripts/requirements-kas-$kas_version-linux-x86_64.txt" \
        scripts/verify-kas-install.py \
        scripts/check-cve-report.py \
        scripts/inspect-cve-database.py \
        security/cve-waivers.json \
        kas/common.yml \
        "$kas_config" \
        meta-cosmopod/recipes-mender/mender/files/artifact-verify-key.pem
}

# Hash every tracked and non-ignored untracked source file plus Git status.
# This catches working-tree changes while a long build is running.
git_source_fingerprint() {
    local repo=$1 path file_hash
    (
        cd -- "$repo"
        printf 'commit\0'
        git rev-parse HEAD
        printf 'status\0'
        git status --porcelain=v1 -z --untracked-files=all
        printf 'files\0'
        git ls-files --cached --others --exclude-standard -z | \
            LC_ALL=C sort -zu | while IFS= read -r -d '' path; do
                printf 'path\0%s\0' "$path"
                if [[ -L "$path" ]]; then
                    printf 'symlink\0%s\0' "$(readlink -- "$path")"
                elif [[ -f "$path" ]]; then
                    file_hash=$(sha256sum -- "$path" | awk '{print $1}')
                    printf 'file\0%s\0' "$file_hash"
                elif [[ -d "$path" ]]; then
                    printf 'directory\0'
                else
                    printf 'missing\0'
                fi
            done
    ) | sha256sum | awk '{print $1}'
}
