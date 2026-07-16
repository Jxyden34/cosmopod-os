#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

load_config
if [[ ! -d "${MENDER_SERVER_DIR}/.git" ]]; then
  printf '%s\n' 'Evaluation backend is not bootstrapped; nothing to stop.'
  exit 0
fi

need_command git
check_compose_version
check_docker_access
require_checkout
compose stop
printf '%s\n' 'Stopped evaluation containers. Volumes and data retained.'
