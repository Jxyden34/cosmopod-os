#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

load_config
if [[ ! -d "${MENDER_SERVER_DIR}/.git" ]]; then
  printf '%s\n' 'Evaluation backend: not bootstrapped'
  exit 0
fi

need_command git
check_compose_version
check_docker_access
require_checkout

printf 'Evaluation commit: %s (pinned)\n' "$(git -C "${MENDER_SERVER_DIR}" rev-parse HEAD)"
printf 'Compose project: %s\n' "${MENDER_COMPOSE_PROJECT}"
compose ps --all
warn_if_hosts_missing
