#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

load_config
need_command git
need_command getent
need_command awk
check_compose_version
check_docker_access

printf '%s\n' 'LAB ONLY: upstream Docker Compose is for evaluation, never production.' >&2
mkdir -p -- "${STATE_DIR}"

if [[ -e "${MENDER_SERVER_DIR}" && ! -d "${MENDER_SERVER_DIR}/.git" ]]; then
  fail "${MENDER_SERVER_DIR} exists but is not a Git checkout; refusing to overwrite it"
fi

if [[ ! -d "${MENDER_SERVER_DIR}/.git" ]]; then
  mkdir -- "${MENDER_SERVER_DIR}"
  git -C "${MENDER_SERVER_DIR}" init --quiet
  git -C "${MENDER_SERVER_DIR}" remote add origin "${MENDER_SERVER_REPOSITORY}"
fi

origin="$(git -C "${MENDER_SERVER_DIR}" remote get-url origin)"
case "${origin}" in
  "${MENDER_SERVER_REPOSITORY}"|"${MENDER_SERVER_REPOSITORY%.git}") ;;
  *) fail "unexpected origin ${origin}; refusing to fetch or check out" ;;
esac

if ! git -C "${MENDER_SERVER_DIR}" cat-file -e "${MENDER_SERVER_COMMIT}^{commit}" 2>/dev/null; then
  git -C "${MENDER_SERVER_DIR}" fetch --no-tags --depth 1 origin "${MENDER_SERVER_COMMIT}"
fi

current="$(git -C "${MENDER_SERVER_DIR}" rev-parse --verify HEAD 2>/dev/null || true)"
if [[ "${current}" != "${MENDER_SERVER_COMMIT}" ]]; then
  [[ -z "$(git -C "${MENDER_SERVER_DIR}" status --porcelain)" ]] || \
    fail "evaluation checkout has local changes; refusing to replace them"
  git -C "${MENDER_SERVER_DIR}" checkout --quiet --detach "${MENDER_SERVER_COMMIT}"
fi

require_checkout
compose config --quiet
warn_if_hosts_missing

printf 'Ready: Mender evaluation server pinned to %s\n' "${MENDER_SERVER_COMMIT}"
printf 'Start with: bash %s/start.sh\n' "${SCRIPT_DIR}"
