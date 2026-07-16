#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

load_config
bash "${SCRIPT_DIR}/bootstrap-evaluation.sh"
require_checkout
check_docker_access

printf '%s\n' 'LAB ONLY: starting upstream Mender evaluation composition.' >&2
compose up --detach
compose ps
warn_if_hosts_missing

printf 'UI: https://docker.mender.io\n'
printf 'Suggested lab admin email: %s\n' "${MENDER_ADMIN_EMAIL}"
printf 'No admin password was generated or stored. See backend/README.md.\n'
