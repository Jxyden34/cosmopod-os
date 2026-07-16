#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly BACKEND_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
readonly STATE_DIR="${BACKEND_DIR}/.state"
readonly MENDER_SERVER_DIR="${STATE_DIR}/mender-server"
readonly MENDER_SERVER_REPOSITORY="https://github.com/mendersoftware/mender-server.git"
readonly MENDER_SERVER_COMMIT="c5edfdb18b05e7f623580a53c2180fc45ae5f157"
readonly MINIMUM_COMPOSE_VERSION="2.24.4"
readonly CONFIG_FILE="${BACKEND_DIR}/.env"
readonly MENDER_IMAGE_REGISTRY="docker.io"
readonly MENDER_IMAGE_REPOSITORY="mendersoftware"
readonly MENDER_IMAGE_TAG="v4.1.1"

MENDER_COMPOSE_PROJECT="cosmopod-mender-eval"
MENDER_ADMIN_EMAIL="admin@docker.mender.io"
MENDER_BIND_ADDRESS="127.0.0.1"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

load_config() {
  local line key value line_number=0

  [[ -f "${CONFIG_FILE}" ]] || return 0

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line_number=$((line_number + 1))
    line="${line%$'\r'}"
    [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    [[ "${line}" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || \
      fail "invalid ${CONFIG_FILE}:${line_number}; expected KEY=VALUE"

    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    if [[ "${value}" == \"*\" && ${#value} -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${value}" == \'*\' && ${#value} -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    fi

    case "${key}" in
      MENDER_COMPOSE_PROJECT|MENDER_ADMIN_EMAIL|MENDER_BIND_ADDRESS)
        printf -v "${key}" '%s' "${value}"
        ;;
      *)
        fail "unsupported setting in ${CONFIG_FILE}:${line_number}: ${key}"
        ;;
    esac
  done < "${CONFIG_FILE}"

  [[ "${MENDER_COMPOSE_PROJECT}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || \
    fail "MENDER_COMPOSE_PROJECT must match [a-z0-9][a-z0-9_-]*"
  [[ "${MENDER_ADMIN_EMAIL}" == *@* && "${MENDER_ADMIN_EMAIL}" != *[[:space:]]* ]] || \
    fail "MENDER_ADMIN_EMAIL must look like an email address"
  [[ "${MENDER_BIND_ADDRESS}" == "127.0.0.1" || "${MENDER_BIND_ADDRESS}" == "0.0.0.0" ]] || \
    fail "MENDER_BIND_ADDRESS must be 127.0.0.1 or explicit 0.0.0.0"
}

check_compose_version() {
  local raw version oldest

  need_command docker
  need_command sort
  raw="$(docker compose version --short 2>/dev/null)" || \
    fail "Docker Compose v2 is unavailable; version ${MINIMUM_COMPOSE_VERSION} or newer is required"
  version="${raw#v}"
  version="${version%%-*}"
  version="${version%%+*}"
  oldest="$(printf '%s\n%s\n' "${MINIMUM_COMPOSE_VERSION}" "${version}" | sort -V | head -n 1)"
  [[ "${oldest}" == "${MINIMUM_COMPOSE_VERSION}" ]] || \
    fail "Docker Compose ${version} is too old; ${MINIMUM_COMPOSE_VERSION} or newer is required"
}

check_docker_access() {
  docker info >/dev/null 2>&1 || fail \
    "Docker daemon unavailable to this user. Start Docker and grant this user socket access; do not place credentials in .env."
}

require_checkout() {
  [[ -d "${MENDER_SERVER_DIR}/.git" ]] || \
    fail "evaluation checkout missing; run scripts/bootstrap-evaluation.sh first"
  [[ "$(git -C "${MENDER_SERVER_DIR}" rev-parse HEAD)" == "${MENDER_SERVER_COMMIT}" ]] || \
    fail "evaluation checkout is not pinned to ${MENDER_SERVER_COMMIT}"
  [[ -f "${MENDER_SERVER_DIR}/docker-compose.yml" ]] || \
    fail "pinned checkout has no docker-compose.yml"
}

compose() {
  (
    cd -- "${MENDER_SERVER_DIR}"
    export MENDER_IMAGE_REGISTRY MENDER_IMAGE_REPOSITORY MENDER_IMAGE_TAG MENDER_BIND_ADDRESS
    docker compose \
      --project-name "${MENDER_COMPOSE_PROJECT}" \
      --file docker-compose.yml \
      --file "${BACKEND_DIR}/evaluation.override.yml" \
      "$@"
  )
}

warn_if_hosts_missing() {
  local missing=0 host

  for host in docker.mender.io s3.docker.mender.io; do
    if ! getent ahostsv4 "${host}" 2>/dev/null | awk '$1 == "127.0.0.1" { found=1 } END { exit !found }'; then
      missing=1
    fi
  done

  if (( missing )); then
    cat >&2 <<'EOF'
warning: lab host mappings missing. Review, then add once outside these scripts:
  127.0.0.1 docker.mender.io s3.docker.mender.io
Scripts never edit /etc/hosts automatically.
EOF
  fi
}
