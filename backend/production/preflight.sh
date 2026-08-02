#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

usage() {
  cat <<'EOF'
Usage: preflight.sh --context CONTEXT --hostname HOSTNAME \
  --ingress-class CLASS --storage-class CLASS [options]

Read-only production checks. Required namespace and secrets must already exist.

Options:
  --namespace NAME                  Kubernetes namespace (default: mender)
  --release NAME                    Helm release (default: cosmopod-mender)
  --values FILE                     Additional non-secret values; repeatable
  --s3-workload-identity NAME       Service account; omit static S3 auth keys
  --timeout DURATION                Helm operation timeout (default: 20m)
  --help                            Show this help
EOF
}

parse_preflight_options "$@"
if ((SHOW_HELP)); then
  usage
  exit 0
fi
((${#REMAINING_ARGS[@]} == 0)) || fail "unknown argument: ${REMAINING_ARGS[0]}"

validate_inputs
require_production_commands
prepare_helm_arguments

umask 077
temporary_directory="$(mktemp -d)"
trap 'rm -f -- "${temporary_directory}/mender-rendered.yaml" "${temporary_directory}/${CHART_ARCHIVE_BASENAME}"; rmdir -- "${temporary_directory}"' EXIT

printf '%s\n' 'Checking Kubernetes context, namespace, ingress, storage, and network policy...'
validate_cluster_prerequisites
validate_network_policy_prerequisites
printf '%s\n' 'Checking required secret names, data keys, certificate, and key types...'
validate_required_secrets
printf '%s\n' 'Checking hostname DNS uses origin addresses outside Cloudflare proxy ranges...'
validate_dns_only_artifact_path
printf '%s\n' 'Downloading, locking, and rendering pinned production chart...'
fetch_and_verify_chart "${temporary_directory}"
validate_chart_metadata "${VERIFIED_CHART_PACKAGE}"
render_and_validate_chart "${temporary_directory}/mender-rendered.yaml" "${VERIFIED_CHART_PACKAGE}"

printf 'Preflight passed for https://%s in context %s namespace %s. No cluster state changed.\n' \
  "${MENDER_HOSTNAME}" "${KUBE_CONTEXT}" "${NAMESPACE}"
