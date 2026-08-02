#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=_common.sh
source "${SCRIPT_DIR}/_common.sh"

usage() {
  cat <<'EOF'
Usage: deploy.sh --context CONTEXT --hostname HOSTNAME \
  --ingress-class CLASS --storage-class CLASS --apply \
  --approve-hostname HOSTNAME --confirm-backup BACKUP_REFERENCE [options]

Runs read-only preflight, shows secret-suppressed Helm diff, then performs one
atomic Helm install/upgrade. Namespace must already exist.

Options:
  --namespace NAME                  Kubernetes namespace (default: mender)
  --release NAME                    Helm release (default: cosmopod-mender)
  --values FILE                     Additional non-secret values; repeatable
  --s3-workload-identity NAME       Service account; omit static S3 auth keys
  --timeout DURATION                Helm timeout (default: 20m)
  --apply                           Required mutation gate
  --approve-hostname HOSTNAME       Must exactly equal --hostname
  --confirm-backup REFERENCE        Restorable backup/snapshot reference
  --help                            Show this help
EOF
}

apply_requested=0
approved_hostname=""
backup_reference=""

parse_preflight_options "$@"
if ((SHOW_HELP)); then
  usage
  exit 0
fi

set -- "${REMAINING_ARGS[@]}"
while (($#)); do
  case "$1" in
    --apply)
      apply_requested=1
      shift
      ;;
    --approve-hostname)
      require_option_value "$1" "${2-}"
      approved_hostname="$2"
      shift 2
      ;;
    --confirm-backup)
      require_option_value "$1" "${2-}"
      backup_reference="$2"
      shift 2
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

validate_inputs
((apply_requested == 1)) || fail "refusing deployment without --apply"
[[ "${approved_hostname}" == "${MENDER_HOSTNAME}" ]] || \
  fail "--approve-hostname must exactly equal --hostname"
[[ "${backup_reference}" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@+-]{7,199}$ ]] || \
  fail "--confirm-backup must provide an immutable backup reference of 8-200 safe characters"

build_preflight_arguments
"${SCRIPT_DIR}/preflight.sh" "${PREFLIGHT_ARGS[@]}"

need_command helm
helm plugin list | awk '$1 == "diff" { found=1 } END { exit !found }' || \
  fail "Helm diff plugin is required before deployment"
prepare_helm_arguments
umask 077
temporary_directory="$(mktemp -d)"
trap 'rm -f -- "${temporary_directory}/${CHART_ARCHIVE_BASENAME}"; rmdir -- "${temporary_directory}"' EXIT
fetch_and_verify_chart "${temporary_directory}"
validate_chart_metadata "${VERIFIED_CHART_PACKAGE}"

printf '%s\n' 'Reviewing secret-suppressed Helm diff...'
helm diff upgrade "${RELEASE_NAME}" "${VERIFIED_CHART_PACKAGE}" \
  --kube-context "${KUBE_CONTEXT}" \
  --namespace "${NAMESPACE}" \
  --allow-unreleased \
  --suppress-secrets \
  "${HELM_VALUE_ARGS[@]}" \
  "${HELM_HOST_ARGS[@]}"

printf '%s\n' 'Applying atomic Mender release...'
helm upgrade --install "${RELEASE_NAME}" "${VERIFIED_CHART_PACKAGE}" \
  --kube-context "${KUBE_CONTEXT}" \
  --namespace "${NAMESPACE}" \
  --atomic \
  --cleanup-on-fail \
  --wait \
  --wait-for-jobs \
  --timeout "${HELM_TIMEOUT}" \
  --history-max 10 \
  "${HELM_VALUE_ARGS[@]}" \
  "${HELM_HOST_ARGS[@]}"

printf 'Atomic deployment completed for https://%s. Run postflight.sh now.\n' "${MENDER_HOSTNAME}"
