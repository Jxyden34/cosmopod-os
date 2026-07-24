#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

usage() {
  cat <<'EOF'
Usage: postflight.sh --context CONTEXT --hostname HOSTNAME [options]

Checks Mender workload rollouts, runs Helm tests, and probes two Mender APIs.

Options:
  --namespace NAME       Kubernetes namespace (default: mender)
  --release NAME         Helm release (default: cosmopod-mender)
  --timeout DURATION     Rollout and Helm test timeout (default: 20m)
  --help                 Show this help
EOF
}

while (($#)); do
  case "$1" in
    --context)
      require_option_value "$1" "${2-}"
      KUBE_CONTEXT="$2"
      shift 2
      ;;
    --hostname)
      require_option_value "$1" "${2-}"
      MENDER_HOSTNAME="$2"
      shift 2
      ;;
    --namespace)
      require_option_value "$1" "${2-}"
      NAMESPACE="$2"
      shift 2
      ;;
    --release)
      require_option_value "$1" "${2-}"
      RELEASE_NAME="$2"
      shift 2
      ;;
    --timeout)
      require_option_value "$1" "${2-}"
      HELM_TIMEOUT="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

validate_context_name "${KUBE_CONTEXT}" || fail "--context must name one Kubernetes context"
validate_hostname "${MENDER_HOSTNAME}" || fail "--hostname must be a lowercase fully qualified DNS name"
validate_dns_label "${NAMESPACE}" || fail "--namespace must be a valid Kubernetes DNS label"
validate_dns_label "${RELEASE_NAME}" || fail "--release must be a valid Helm release name"
[[ "${HELM_TIMEOUT}" =~ ^[1-9][0-9]*(s|m|h)$ ]] || fail "invalid --timeout"

for command in helm kubectl curl; do
  need_command "${command}"
done

context="$(kubectl config get-contexts "${KUBE_CONTEXT}" -o name 2>/dev/null)"
[[ "${context}" == "${KUBE_CONTEXT}" ]] || fail "Kubernetes context not found: ${KUBE_CONTEXT}"
kubectl_cluster get namespace "${NAMESPACE}" >/dev/null || fail "namespace not found: ${NAMESPACE}"

mapfile -t workloads < <(
  kubectl_namespaced get deployments.apps,statefulsets.apps \
    --selector "app.kubernetes.io/instance=${RELEASE_NAME}" \
    -o name
)
((${#workloads[@]} > 0)) || fail "no Mender workloads found for release ${RELEASE_NAME}"

for workload in "${workloads[@]}"; do
  kubectl_namespaced rollout status "${workload}" --timeout "${HELM_TIMEOUT}"
done

helm test "${RELEASE_NAME}" \
  --kube-context "${KUBE_CONTEXT}" \
  --namespace "${NAMESPACE}" \
  --timeout "${HELM_TIMEOUT}"

probe_mender_api() {
  local path="$1"

  curl --proto '=https' \
    --tlsv1.2 \
    --silent \
    --show-error \
    --request POST \
    --header 'Content-Type: application/json' \
    --data '{}' \
    --dump-header - \
    --output /dev/null \
    --connect-timeout 15 \
    --max-time 30 \
    --retry 5 \
    --retry-all-errors \
    "https://${MENDER_HOSTNAME}${path}" | \
    awk '
      /^HTTP\// { status=$2 }
      tolower($1) == "x-men-requestid:" && length($2) > 1 { request_id=1 }
      END { exit !(status ~ /^4[0-9][0-9]$/ && request_id) }
    ' || fail "Mender API identity probe failed: ${path}"
}

probe_mender_api '/api/management/v1/useradm/auth/login'
probe_mender_api '/api/devices/v1/authentication/auth_requests'

printf 'Postflight passed: rollouts, Helm tests, and Mender API probes healthy for %s.\n' \
  "${MENDER_HOSTNAME}"
