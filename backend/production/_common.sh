#!/usr/bin/env bash

set -Eeuo pipefail

readonly PRODUCTION_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly BASE_VALUES_FILE="${PRODUCTION_DIR}/values.yaml"
readonly CHART_REPOSITORY_NAME="mender"
readonly CHART_REPOSITORY_URL="https://charts.mender.io"
readonly CHART_REFERENCE="mender/mender"
readonly CHART_VERSION="7.7.4"
readonly CHART_APP_VERSION="v4.1.1"
readonly CHART_ARCHIVE_BASENAME="mender-${CHART_VERSION}.tgz"
readonly CHART_ARCHIVE_SHA256="1ed0eb4bf3d3af5108483bbbdab37c17090eb49b1e3010eefe3174a26fdefc40"
readonly DEFAULT_DENY_NETWORK_POLICY="cosmopod-default-deny"
readonly MENDER_ALLOW_NETWORK_POLICY="cosmopod-mender-allow"

KUBE_CONTEXT=""
MENDER_HOSTNAME=""
NAMESPACE="mender"
INGRESS_CLASS=""
STORAGE_CLASS=""
RELEASE_NAME="cosmopod-mender"
HELM_TIMEOUT="20m"
S3_WORKLOAD_IDENTITY_SERVICE_ACCOUNT=""
SHOW_HELP=0
EXTRA_VALUES_FILES=()
REMAINING_ARGS=()
HELM_VALUE_ARGS=()
HELM_HOST_ARGS=()
VERIFIED_CHART_PACKAGE=""

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_option_value() {
  local option="$1"
  local value="${2-}"

  [[ -n "${value}" && "${value}" != --* ]] || fail "${option} requires a value"
}

parse_preflight_options() {
  REMAINING_ARGS=()

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
      --ingress-class)
        require_option_value "$1" "${2-}"
        INGRESS_CLASS="$2"
        shift 2
        ;;
      --storage-class)
        require_option_value "$1" "${2-}"
        STORAGE_CLASS="$2"
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
      --values)
        require_option_value "$1" "${2-}"
        EXTRA_VALUES_FILES+=("$2")
        shift 2
        ;;
      --s3-workload-identity)
        require_option_value "$1" "${2-}"
        S3_WORKLOAD_IDENTITY_SERVICE_ACCOUNT="$2"
        shift 2
        ;;
      --help|-h)
        SHOW_HELP=1
        shift
        ;;
      *)
        REMAINING_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

validate_dns_label() {
  local label="$1"

  [[ ${#label} -le 63 ]] || return 1
  [[ "${label}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]
}

validate_dns_subdomain() {
  local name="$1"
  local label
  local labels=()

  [[ -n "${name}" && ${#name} -le 253 ]] || return 1
  [[ "${name}" != .* && "${name}" != *. && "${name}" != *..* ]] || return 1
  IFS='.' read -r -a labels <<< "${name}"
  for label in "${labels[@]}"; do
    validate_dns_label "${label}" || return 1
  done
}

validate_hostname() {
  local hostname="$1"

  [[ "${hostname}" == *.* ]] || return 1
  [[ "${hostname}" != *$'\n'* && "${hostname}" != *$'\r'* ]] || return 1
  validate_dns_subdomain "${hostname}"
}

validate_context_name() {
  local context="$1"

  [[ -n "${context}" && ${#context} -le 253 ]] || return 1
  [[ "${context}" != *$'\n'* && "${context}" != *$'\r'* ]]
}

validate_inputs() {
  validate_context_name "${KUBE_CONTEXT}" || fail "--context must name one Kubernetes context"
  validate_hostname "${MENDER_HOSTNAME}" || fail "--hostname must be a lowercase fully qualified DNS name"
  validate_dns_label "${NAMESPACE}" || fail "--namespace must be a valid Kubernetes DNS label"
  validate_dns_subdomain "${INGRESS_CLASS}" || fail "--ingress-class must be a valid Kubernetes DNS subdomain"
  validate_dns_subdomain "${STORAGE_CLASS}" || fail "--storage-class must be a valid Kubernetes DNS subdomain"
  validate_dns_label "${RELEASE_NAME}" || fail "--release must be a valid Helm release name"
  [[ "${HELM_TIMEOUT}" =~ ^[1-9][0-9]*(s|m|h)$ ]] || fail "--timeout must look like 30s, 20m, or 1h"

  if [[ -n "${S3_WORKLOAD_IDENTITY_SERVICE_ACCOUNT}" ]]; then
    validate_dns_label "${S3_WORKLOAD_IDENTITY_SERVICE_ACCOUNT}" || \
      fail "--s3-workload-identity must be a valid service account name"
  fi
}

prepare_helm_arguments() {
  local values_file

  [[ -f "${BASE_VALUES_FILE}" ]] || fail "base values file missing: ${BASE_VALUES_FILE}"
  HELM_VALUE_ARGS=(--values "${BASE_VALUES_FILE}")
  for values_file in "${EXTRA_VALUES_FILES[@]}"; do
    [[ -f "${values_file}" ]] || fail "values file not found: ${values_file}"
    HELM_VALUE_ARGS+=(--values "${values_file}")
  done

  HELM_HOST_ARGS=(
    --set "global.enterprise=false"
    --set "global.hosted=false"
    --set-string "global.image.username="
    --set-string "global.image.password="
    --set-string "global.url=https://${MENDER_HOSTNAME}"
    --set-string "global.mongodb.existingSecret=cosmopod-mender-mongodb"
    --set-string "global.mongodb.URL="
    --set-string "global.nats.existingSecret=cosmopod-mender-nats"
    --set-string "global.nats.URL="
    --set-string "global.smtp.existingSecret=cosmopod-mender-smtp"
    --set-string "global.s3.existingSecret=cosmopod-mender-s3"
    --set "mongodb.enabled=false"
    --set "nats.enabled=false"
    --set "redis.enabled=false"
    --set "api_gateway.env.SSL=false"
    --set "ingress.enabled=true"
    --set-string "ingress.ingressClassName=${INGRESS_CLASS}"
    --set-string "ingress.hosts[0]=${MENDER_HOSTNAME}"
    --set-string "ingress.tls[0].secretName=mender-ingress-tls"
    --set-string "ingress.tls[0].hosts[0]=${MENDER_HOSTNAME}"
    --set-string "device_auth.certs.existingSecret=cosmopod-mender-deviceauth-signing"
    --set-string "useradm.certs.existingSecret=cosmopod-mender-useradm-signing"
    --set "tests.enabled=true"
  )
  if [[ -n "${S3_WORKLOAD_IDENTITY_SERVICE_ACCOUNT}" ]]; then
    HELM_HOST_ARGS+=(
      --set-string "global.s3.AWS_SERVICE_ACCOUNT_NAME=${S3_WORKLOAD_IDENTITY_SERVICE_ACCOUNT}"
    )
  fi
}

kubectl_cluster() {
  kubectl --context "${KUBE_CONTEXT}" "$@"
}

kubectl_namespaced() {
  kubectl --context "${KUBE_CONTEXT}" --namespace "${NAMESPACE}" "$@"
}

irsa_service_account_is_safe() {
  jq -e '
    (.metadata.annotations // {}) as $annotations |
    ($annotations["eks.amazonaws.com/role-arn"] // "") |
    type == "string" and
    test("^arn:aws(-[a-z0-9]+)?:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$")
  ' >/dev/null
}

validate_cluster_prerequisites() {
  local context

  context="$(kubectl config get-contexts "${KUBE_CONTEXT}" -o name 2>/dev/null)"
  [[ "${context}" == "${KUBE_CONTEXT}" ]] || fail "Kubernetes context not found: ${KUBE_CONTEXT}"

  kubectl_cluster get namespace "${NAMESPACE}" -o json | \
    jq -e '.status.phase == "Active"' >/dev/null || \
    fail "namespace is missing or not Active: ${NAMESPACE}"
  kubectl_cluster get ingressclass "${INGRESS_CLASS}" -o json | \
    jq -e --arg name "${INGRESS_CLASS}" '.metadata.name == $name' >/dev/null || \
    fail "ingress class not found: ${INGRESS_CLASS}"
  kubectl_cluster get storageclass "${STORAGE_CLASS}" -o json | \
    jq -e --arg name "${STORAGE_CLASS}" \
      '.metadata.name == $name and (.provisioner | type == "string" and length > 0)' >/dev/null || \
    fail "storage class is missing or has no provisioner: ${STORAGE_CLASS}"

  if [[ -n "${S3_WORKLOAD_IDENTITY_SERVICE_ACCOUNT}" ]]; then
    kubectl_namespaced get serviceaccount "${S3_WORKLOAD_IDENTITY_SERVICE_ACCOUNT}" -o json | \
      irsa_service_account_is_safe || fail \
      "workload identity service account is missing a valid AWS EKS IRSA role annotation"
  fi
}

default_deny_network_policy_is_safe() {
  jq -e '
      .spec.podSelector == {} and
      (.spec.policyTypes | index("Ingress")) != null and
      (.spec.policyTypes | index("Egress")) != null and
      ((.spec.ingress // []) | length) == 0 and
      ((.spec.egress // []) | length) == 0
    ' >/dev/null
}

mender_allow_network_policy_is_safe() {
  local policy_json

  policy_json="$(cat)" || return 1
  printf '%s\n' "${policy_json}" | jq -e --arg release "${RELEASE_NAME}" '
      def selector_is_scoped:
        (.matchLabels // {}) as $labels |
        (.matchExpressions // []) as $expressions |
        type == "object" and
        ($labels | type == "object") and
        ($expressions | type == "array") and
        (($labels | length) > 0 or ($expressions | length) > 0) and
        all($labels[]; type == "string") and
        all($expressions[];
          type == "object" and
          ((.key // "") | (type == "string" and length > 0)) and
          .operator == "In" and
          ((.values // []) | (type == "array" and length > 0)) and
          all(.values[]; type == "string")
        );
      def peer_is_scoped:
        if has("ipBlock") then
          ((keys | sort) == ["ipBlock"]) and
          ((.ipBlock.cidr // "") as $cidr |
            ($cidr | (type == "string" and length > 0)) and
            $cidr != "0.0.0.0/0" and $cidr != "::/0")
        elif has("namespaceSelector") then
          ((keys | sort) == ["namespaceSelector"] or
           (keys | sort) == ["namespaceSelector", "podSelector"]) and
          (.namespaceSelector | selector_is_scoped) and
          ((has("podSelector") | not) or (.podSelector | selector_is_scoped))
        elif has("podSelector") then
          ((keys | sort) == ["podSelector"]) and
          (.podSelector | selector_is_scoped)
        else
          false
        end;
      def port_is_scoped:
        type == "object" and
        (has("endPort") | not) and
        (
          if (.port? | type) == "number" then
            .port >= 1 and .port <= 65535
          elif (.port? | type) == "string" then
            (.port | length) >= 1 and (.port | length) <= 15 and
            (.port | test("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"))
          else
            false
          end
        ) and
        ((.protocol // "TCP") | (. == "TCP" or . == "UDP" or . == "SCTP"));
      (.spec.ingress // []) as $ingress |
      (.spec.egress // []) as $egress |
      .spec.podSelector.matchLabels["app.kubernetes.io/instance"] == $release and
      (.spec.policyTypes | index("Ingress")) != null and
      (.spec.policyTypes | index("Egress")) != null and
      ($ingress | length) > 0 and
      ($egress | length) > 0 and
      all($ingress[];
        ((.from // []) | length) > 0 and
        ((.ports // []) | length) > 0 and
        all(.from[]; peer_is_scoped) and
        all(.ports[]; port_is_scoped)
      ) and
      all($egress[];
        ((.to // []) | length) > 0 and
        ((.ports // []) | length) > 0 and
        all(.to[]; peer_is_scoped) and
        all(.ports[]; port_is_scoped)
      )
    ' >/dev/null || return 1

  printf '%s\n' "${policy_json}" | python3 -c '
import ipaddress
import json
import sys

policy = json.load(sys.stdin)
directions = (("ingress", "from"), ("egress", "to"))
limits = {4: (8, 1 << 24), 6: (32, 1 << 96)}

for direction, peer_key in directions:
    networks = {4: [], 6: []}
    for rule in policy.get("spec", {}).get(direction, []):
        for peer in rule.get(peer_key, []):
            block = peer.get("ipBlock")
            if block is None:
                continue
            try:
                network = ipaddress.ip_network(block["cidr"], strict=False)
            except (KeyError, TypeError, ValueError):
                sys.exit(1)
            minimum_prefix, _ = limits[network.version]
            if network.prefixlen < minimum_prefix:
                sys.exit(1)
            networks[network.version].append(network)

    for version, candidates in networks.items():
        _, maximum_addresses = limits[version]
        covered = sum(
            network.num_addresses
            for network in ipaddress.collapse_addresses(candidates)
        )
        if covered > maximum_addresses:
            sys.exit(1)
' >/dev/null
}

network_policy_inventory_is_safe() {
  jq -e \
    --arg release "${RELEASE_NAME}" \
    --arg default_deny "${DEFAULT_DENY_NETWORK_POLICY}" \
    --arg mender_allow "${MENDER_ALLOW_NETWORK_POLICY}" '
      def excludes_release($release):
        (.matchLabels // {}) as $labels |
        (.matchExpressions // []) as $expressions |
        (($labels["app.kubernetes.io/instance"]? != null) and
          ($labels["app.kubernetes.io/instance"] != $release)) or
        any($expressions[]?;
          .key == "app.kubernetes.io/instance" and
          (
            (.operator == "In" and ((.values // []) | index($release) | not)) or
            (.operator == "NotIn" and ((.values // []) | index($release) != null)) or
            .operator == "DoesNotExist"
          )
        );
      (.items | type == "array") and
      all(.items[];
        (.metadata.name == $default_deny) or
        (.metadata.name == $mender_allow) or
        ((.spec.podSelector // {}) | excludes_release($release))
      )
    ' >/dev/null
}

validate_network_policy_prerequisites() {
  local default_deny_policy
  local mender_allow_policy
  local policy_inventory

  policy_inventory="$(kubectl_namespaced get networkpolicy -o json)" || \
    fail "unable to list namespace NetworkPolicies"
  default_deny_policy="$(printf '%s\n' "${policy_inventory}" | jq -ce \
    --arg name "${DEFAULT_DENY_NETWORK_POLICY}" \
    '[.items[] | select(.metadata.name == $name)] |
     if length == 1 then .[0] else error("required policy count is not one") end')" || \
    fail "required NetworkPolicy not found exactly once: ${DEFAULT_DENY_NETWORK_POLICY}"
  mender_allow_policy="$(printf '%s\n' "${policy_inventory}" | jq -ce \
    --arg name "${MENDER_ALLOW_NETWORK_POLICY}" \
    '[.items[] | select(.metadata.name == $name)] |
     if length == 1 then .[0] else error("required policy count is not one") end')" || \
    fail "required NetworkPolicy not found exactly once: ${MENDER_ALLOW_NETWORK_POLICY}"

  printf '%s\n' "${default_deny_policy}" | default_deny_network_policy_is_safe || fail \
    "${DEFAULT_DENY_NETWORK_POLICY} must deny all namespace ingress and egress"

  printf '%s\n' "${mender_allow_policy}" | \
    mender_allow_network_policy_is_safe || fail \
    "${MENDER_ALLOW_NETWORK_POLICY} must select this release and use scoped peers and ports"

  printf '%s\n' "${policy_inventory}" | \
    network_policy_inventory_is_safe || fail \
    "unapproved NetworkPolicy may select ${RELEASE_NAME} workloads"
}

secret_type() {
  kubectl_namespaced get secret "$1" -o jsonpath='{.type}'
}

require_secret_type() {
  local name="$1"
  local expected_type="$2"
  local actual_type

  actual_type="$(secret_type "${name}" 2>/dev/null)" || fail "required secret not found: ${name}"
  [[ "${actual_type}" == "${expected_type}" ]] || \
    fail "secret ${name} must have type ${expected_type}"
}

require_secret_key() {
  local name="$1"
  local key="$2"

  kubectl_namespaced get secret "${name}" -o json | \
    jq -e --arg key "${key}" \
      '.data[$key] | type == "string" and length > 0' >/dev/null || \
    fail "secret ${name} is missing required data key ${key}"
}

secret_has_key() {
  local name="$1"
  local key="$2"

  kubectl_namespaced get secret "${name}" -o json | \
    jq -e --arg key "${key}" \
      '.data[$key] | type == "string" and length > 0' >/dev/null
}

secret_data() {
  local name="$1"
  local key="$2"

  kubectl_namespaced get secret "${name}" -o json | jq -er --arg key "${key}" '.data[$key]'
}

decoded_secret_data() {
  secret_data "$1" "$2" | base64 --decode
}

https_url_is_safe() {
  awk '
    { lines++ }
    /^https:\/\/[^[:space:]]+$/ { secure++ }
    END { exit !(lines == 1 && secure == 1) }
  '
}

smtp_ssl_is_safe() {
  awk '
    { lines++ }
    tolower($0) == "true" { secure++ }
    END { exit !(lines == 1 && secure == 1) }
  '
}

nats_url_is_safe() {
  awk '
    { lines++ }
    /^tls:\/\/[^\/@[:space:]]+@[^[:space:]]+$/ { secure++ }
    END { exit !(lines == 1 && secure == 1) }
  '
}

mongodb_url_is_safe() {
  awk '
    {
      lines++
      url=tolower($0)
      insecure=(url ~ /[?&](tls|ssl)(insecure|allowinvalidcertificates|allowinvalidhostnames)=true([&#]|$)/)
      if (url ~ /^mongodb\+srv:\/\/[^[:space:]]+$/ &&
          url !~ /[?&](tls|ssl)=false([&#]|$)/ && !insecure) {
        secure++
      }
      if (url ~ /^mongodb:\/\/[^[:space:]]+$/ &&
          url ~ /[?&](tls|ssl)=true([&#]|$)/ &&
          url !~ /[?&](tls|ssl)=false([&#]|$)/ && !insecure) {
        secure++
      }
    }
    END { exit !(lines == 1 && secure == 1) }
  '
}

require_opaque_secret_keys() {
  local name="$1"
  shift

  require_secret_type "${name}" "Opaque"
  while (($#)); do
    require_secret_key "${name}" "$1"
    shift
  done
}

ed25519_fingerprint() {
  secret_data "$1" 'private.pem' | \
    base64 --decode | \
    openssl pkey -pubout -outform DER 2>/dev/null | \
    sha256sum | awk '{print $1}'
}

require_ed25519_secret() {
  local name="$1"

  require_opaque_secret_keys "${name}" 'private.pem'
  secret_data "${name}" 'private.pem' | \
    base64 --decode | \
    openssl pkey -text_pub -noout 2>/dev/null | \
    awk '/ED25519 (Private|Public)-Key/ { found=1 } END { exit !found }' || \
    fail "secret ${name} must contain an Ed25519 private key"
}

certificate_public_fingerprint() {
  secret_data 'mender-ingress-tls' 'tls.crt' | \
    base64 --decode | \
    openssl x509 -pubkey -noout 2>/dev/null | \
    openssl pkey -pubin -outform DER 2>/dev/null | \
    sha256sum | awk '{print $1}'
}

tls_key_public_fingerprint() {
  secret_data 'mender-ingress-tls' 'tls.key' | \
    base64 --decode | \
    openssl pkey -pubout -outform DER 2>/dev/null | \
    sha256sum | awk '{print $1}'
}

validate_tls_secret() {
  local certificate_fingerprint
  local key_fingerprint

  require_secret_type 'mender-ingress-tls' 'kubernetes.io/tls'
  require_secret_key 'mender-ingress-tls' 'tls.crt'
  require_secret_key 'mender-ingress-tls' 'tls.key'

  secret_data 'mender-ingress-tls' 'tls.crt' | \
    base64 --decode | \
    openssl x509 -noout -checkhost "${MENDER_HOSTNAME}" -checkend 604800 >/dev/null 2>&1 || \
    fail "TLS certificate must cover ${MENDER_HOSTNAME} and remain valid for at least seven days"

  certificate_fingerprint="$(certificate_public_fingerprint)" || fail "TLS certificate is invalid"
  key_fingerprint="$(tls_key_public_fingerprint)" || fail "TLS private key is invalid"
  [[ -n "${certificate_fingerprint}" && "${certificate_fingerprint}" == "${key_fingerprint}" ]] || \
    fail "TLS certificate and private key do not match"
}

validate_required_secrets() {
  local device_auth_fingerprint
  local useradm_fingerprint

  require_opaque_secret_keys 'cosmopod-mender-mongodb' 'MONGO' 'MONGO_URL'
  require_opaque_secret_keys 'cosmopod-mender-s3' \
    'AWS_URI' 'AWS_BUCKET' 'STORAGE_BUCKET' 'AWS_REGION' 'AWS_FORCE_PATH_STYLE'
  decoded_secret_data 'cosmopod-mender-s3' 'AWS_URI' | \
    https_url_is_safe || \
    fail "cosmopod-mender-s3 AWS_URI must use HTTPS"
  if secret_has_key 'cosmopod-mender-s3' 'AWS_EXTERNAL_URI'; then
    decoded_secret_data 'cosmopod-mender-s3' 'AWS_EXTERNAL_URI' | \
      https_url_is_safe || \
      fail "cosmopod-mender-s3 AWS_EXTERNAL_URI must use HTTPS"
  fi
  if [[ -z "${S3_WORKLOAD_IDENTITY_SERVICE_ACCOUNT}" ]]; then
    require_secret_key 'cosmopod-mender-s3' 'AWS_AUTH_KEY'
    require_secret_key 'cosmopod-mender-s3' 'AWS_AUTH_SECRET'
  fi
  require_opaque_secret_keys 'cosmopod-mender-smtp' \
    'EMAIL_SENDER' 'SMTP_HOST' 'SMTP_AUTH_MECHANISM' \
    'SMTP_USERNAME' 'SMTP_PASSWORD' 'SMTP_SSL'
  decoded_secret_data 'cosmopod-mender-smtp' 'SMTP_SSL' | \
    smtp_ssl_is_safe || \
    fail "cosmopod-mender-smtp SMTP_SSL must be true"
  require_opaque_secret_keys 'cosmopod-mender-nats' 'NATS_URL'
  decoded_secret_data 'cosmopod-mender-nats' 'NATS_URL' | \
    nats_url_is_safe || \
    fail "cosmopod-mender-nats NATS_URL must use TLS and authentication userinfo"

  decoded_secret_data 'cosmopod-mender-mongodb' 'MONGO' | \
    mongodb_url_is_safe || \
    fail "cosmopod-mender-mongodb MONGO must use SRV TLS or enable TLS explicitly"
  decoded_secret_data 'cosmopod-mender-mongodb' 'MONGO_URL' | \
    mongodb_url_is_safe || \
    fail "cosmopod-mender-mongodb MONGO_URL must use SRV TLS or enable TLS explicitly"

  require_ed25519_secret 'cosmopod-mender-deviceauth-signing'
  require_ed25519_secret 'cosmopod-mender-useradm-signing'
  device_auth_fingerprint="$(ed25519_fingerprint 'cosmopod-mender-deviceauth-signing')" || \
    fail "could not inspect device authentication signing key"
  useradm_fingerprint="$(ed25519_fingerprint 'cosmopod-mender-useradm-signing')" || \
    fail "could not inspect user administration signing key"
  [[ -n "${device_auth_fingerprint}" && "${device_auth_fingerprint}" != "${useradm_fingerprint}" ]] || \
    fail "device authentication and user administration signing keys must differ"

  validate_tls_secret
}

validate_helm_repository() {
  local repository_url

  repository_url="$(helm repo list -o json 2>/dev/null | \
    jq -r --arg name "${CHART_REPOSITORY_NAME}" \
      'first(.[] | select(.name == $name) | .url) // empty')"
  repository_url="${repository_url%/}"
  [[ "${repository_url}" == "${CHART_REPOSITORY_URL}" ]] || \
    fail "Helm repository mender must be ${CHART_REPOSITORY_URL}; add it explicitly before preflight"
}

fetch_and_verify_chart() {
  local destination="$1"
  local actual_sha256

  validate_helm_repository
  helm pull "${CHART_REFERENCE}" \
    --version "${CHART_VERSION}" \
    --destination "${destination}" >/dev/null || \
    fail "could not download pinned Mender Helm chart ${CHART_VERSION}"
  VERIFIED_CHART_PACKAGE="${destination}/${CHART_ARCHIVE_BASENAME}"
  [[ -f "${VERIFIED_CHART_PACKAGE}" ]] || fail "Helm chart archive was not downloaded"
  actual_sha256="$(sha256sum "${VERIFIED_CHART_PACKAGE}" | awk '{print $1}')"
  [[ "${actual_sha256}" == "${CHART_ARCHIVE_SHA256}" ]] || \
    fail "Mender Helm chart archive SHA-256 does not match lock"
}

validate_chart_metadata() {
  local chart_package="$1"
  local metadata
  local version
  local app_version

  metadata="$(helm show chart "${chart_package}")" || \
    fail "could not load pinned Mender Helm chart ${CHART_VERSION}"
  version="$(awk '$1 == "version:" { print $2; exit }' <<< "${metadata}" | tr -d '\"\047')"
  app_version="$(awk '$1 == "appVersion:" { print $2; exit }' <<< "${metadata}" | tr -d '\"\047')"
  [[ "${version}" == "${CHART_VERSION}" ]] || fail "unexpected Helm chart version: ${version}"
  [[ "${app_version}" == "${CHART_APP_VERSION}" ]] || \
    fail "unexpected Mender chart appVersion: ${app_version}"
}

validate_rendered_images() {
  local rendered_file="$1"
  local image
  local image_count=0

  while IFS= read -r image; do
    image="${image#\"}"
    image="${image%\"}"
    image="${image#\'}"
    image="${image%\'}"
    ((image_count += 1))
    [[ "${image}" =~ @sha256:[0-9a-f]{64}$ ]] || \
      fail "every rendered container image must be pinned by sha256 digest"
  done < <(awk '$1 == "image:" && NF >= 2 { print $2 }' "${rendered_file}")

  ((image_count > 0)) || fail "rendered chart contains no container images"
}

validate_rendered_storage() {
  local rendered_file="$1"
  local claim_count
  local class_count
  local storage_class

  claim_count="$(awk '
    $1 == "kind:" && $2 == "PersistentVolumeClaim" { count++ }
    $1 == "volumeClaimTemplates:" { count++ }
    END { print count + 0 }
  ' "${rendered_file}")"
  class_count="$(awk '$1 == "storageClassName:" { count++ } END { print count + 0 }' "${rendered_file}")"
  if ((claim_count == 0)); then
    ((class_count == 0)) || fail "rendered chart has storageClassName without a persistent claim"
    return 0
  fi
  ((class_count >= claim_count)) || \
    fail "every rendered persistent claim must set storageClassName explicitly"

  while IFS= read -r storage_class; do
    storage_class="${storage_class#\"}"
    storage_class="${storage_class%\"}"
    storage_class="${storage_class#\'}"
    storage_class="${storage_class%\'}"
    [[ "${storage_class}" == "${STORAGE_CLASS}" ]] || \
      fail "rendered storageClassName does not match approved storage class"
  done < <(awk '$1 == "storageClassName:" { print $2 }' "${rendered_file}")
}

validate_rendered_hostname() {
  local rendered_file="$1"
  local ingress_hosts

  ingress_hosts="$(awk '$1 == "host:" { value=$2; gsub(/^\"|\"$/, "", value); print value }' \
    "${rendered_file}" | sort -u)"
  [[ "${ingress_hosts}" == "${MENDER_HOSTNAME}" ]] || \
    fail "rendered ingress host must exactly match ${MENDER_HOSTNAME}"
  grep -Fq "https://${MENDER_HOSTNAME}" "${rendered_file}" || \
    fail "rendered server URL does not contain approved HTTPS hostname"
}

validate_rendered_ingress_class() {
  local rendered_file="$1"
  local ingress_classes

  ingress_classes="$(awk '
    $1 == "ingressClassName:" {
      value=$2
      gsub(/^\"|\"$/, "", value)
      gsub(/^\047|\047$/, "", value)
      print value
    }
  ' "${rendered_file}" | sort -u)"
  [[ "${ingress_classes}" == "${INGRESS_CLASS}" ]] || \
    fail "rendered ingressClassName must exactly match approved ingress class"
}

validate_rendered_secret_references() {
  local rendered_file="$1"

  python3 - "${rendered_file}" "${S3_WORKLOAD_IDENTITY_SERVICE_ACCOUNT}" <<'PY' || \
    fail "rendered secret references are not wired to expected workloads"
import re
import sys

rendered_path, identity_service_account = sys.argv[1:]
workload_kinds = {"CronJob", "DaemonSet", "Deployment", "Job", "Pod", "StatefulSet"}
required_workload_secrets = {
    "cosmopod-mender-mongodb",
    "cosmopod-mender-s3",
    "cosmopod-mender-smtp",
    "cosmopod-mender-nats",
    "cosmopod-mender-deviceauth-signing",
    "cosmopod-mender-useradm-signing",
}


def scalar(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


documents = []
text = open(rendered_path, encoding="utf-8").read()
for raw_document in re.split(r"(?m)^---[ \t]*$", text):
    kind_match = re.search(r"(?m)^kind:[ \t]*([^# \t\r\n]+)", raw_document)
    if kind_match is None:
        continue
    kind = scalar(kind_match.group(1))
    name = "<unnamed>"
    metadata_match = re.search(
        r"(?ms)^metadata:[ \t]*\n(?:^[ \t]+[^\n]*\n)*?^[ \t]+name:[ \t]*([^#\n]+)",
        raw_document,
    )
    if metadata_match is not None:
        name = scalar(metadata_match.group(1))

    stack = []
    secret_references = set()
    service_accounts = set()
    for raw_line in raw_document.splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        content = raw_line.lstrip(" ")
        match = re.match(r"(?:-[ \t]+)?([A-Za-z0-9_.-]+):(?:[ \t]*(.*))?$", content)
        if match is None:
            continue
        key, value = match.groups()
        while stack and stack[-1][0] >= indent:
            stack.pop()
        ancestors = {entry[1] for entry in stack}
        value = scalar(value or "")
        if key == "name" and value and ancestors.intersection({"secretKeyRef", "secretRef"}):
            secret_references.add(value)
        if key == "secretName" and value and "secret" in ancestors:
            secret_references.add(value)
        if key == "secretName" and value and kind == "Ingress" and "tls" in ancestors:
            secret_references.add(value)
        if key == "serviceAccountName" and value:
            service_accounts.add(value)
        if not value:
            stack.append((indent, key))

    documents.append(
        {
            "kind": kind,
            "name": name,
            "secrets": secret_references,
            "service_accounts": service_accounts,
        }
    )

workloads = [document for document in documents if document["kind"] in workload_kinds]
if not workloads:
    raise SystemExit("no rendered workloads found")

for secret_name in sorted(required_workload_secrets):
    if not any(secret_name in workload["secrets"] for workload in workloads):
        raise SystemExit(f"secret is not structurally referenced by a workload: {secret_name}")

associations = {
    "cosmopod-mender-deviceauth-signing": "device-auth",
    "cosmopod-mender-useradm-signing": "useradm",
    "cosmopod-mender-s3": "deployments",
}
for secret_name, workload_name_fragment in associations.items():
    if not any(
        secret_name in workload["secrets"] and workload_name_fragment in workload["name"]
        for workload in workloads
    ):
        raise SystemExit(
            f"secret {secret_name} is not referenced by expected {workload_name_fragment} workload"
        )

if not any(
    document["kind"] == "Ingress" and "mender-ingress-tls" in document["secrets"]
    for document in documents
):
    raise SystemExit("mender-ingress-tls is not structurally referenced by an Ingress")

if identity_service_account:
    s3_consumers = [
        workload for workload in workloads if "cosmopod-mender-s3" in workload["secrets"]
    ]
    if not s3_consumers or any(
        workload["service_accounts"] != {identity_service_account}
        for workload in s3_consumers
    ):
        raise SystemExit("every S3-consuming workload must use the approved IRSA service account")
PY
}

validate_dns_only_artifact_path() {
  if ! python3 - "${MENDER_HOSTNAME}" <<'PY'
import ipaddress
import socket
import sys
import urllib.request

hostname = sys.argv[1]
try:
    addresses = {
        ipaddress.ip_address(result[4][0].split("%", 1)[0])
        for result in socket.getaddrinfo(hostname, 443, type=socket.SOCK_STREAM)
    }
    if not addresses:
        raise RuntimeError("hostname has no address")
    networks = []
    for url in ("https://www.cloudflare.com/ips-v4", "https://www.cloudflare.com/ips-v6"):
        with urllib.request.urlopen(url, timeout=15) as response:
            networks.extend(
                ipaddress.ip_network(line.strip())
                for line in response.read().decode("ascii").splitlines()
                if line.strip()
            )
except Exception:
    sys.exit(1)

if any(any(address in network for network in networks) for address in addresses):
    sys.exit(2)
PY
  then
    fail "hostname DNS is unresolved or Cloudflare-proxied; 239.6 MiB Artifact delivery requires DNS-only origin addresses"
  fi
}

render_and_validate_chart() {
  local rendered_file="$1"
  local chart_package="$2"

  helm template "${RELEASE_NAME}" "${chart_package}" \
    --namespace "${NAMESPACE}" \
    --include-crds \
    "${HELM_VALUE_ARGS[@]}" \
    "${HELM_HOST_ARGS[@]}" > "${rendered_file}" || fail "Helm render failed"

  validate_rendered_hostname "${rendered_file}"
  validate_rendered_ingress_class "${rendered_file}"
  validate_rendered_storage "${rendered_file}"
  validate_rendered_secret_references "${rendered_file}"
  validate_rendered_images "${rendered_file}"
}

require_production_commands() {
  local command

  for command in helm kubectl jq openssl base64 sha256sum awk grep sort tr mktemp rm rmdir python3; do
    need_command "${command}"
  done
}

build_preflight_arguments() {
  local values_file

  PREFLIGHT_ARGS=(
    --context "${KUBE_CONTEXT}"
    --hostname "${MENDER_HOSTNAME}"
    --namespace "${NAMESPACE}"
    --ingress-class "${INGRESS_CLASS}"
    --storage-class "${STORAGE_CLASS}"
    --release "${RELEASE_NAME}"
    --timeout "${HELM_TIMEOUT}"
  )
  for values_file in "${EXTRA_VALUES_FILES[@]}"; do
    PREFLIGHT_ARGS+=(--values "${values_file}")
  done
  if [[ -n "${S3_WORKLOAD_IDENTITY_SERVICE_ACCOUNT}" ]]; then
    PREFLIGHT_ARGS+=(--s3-workload-identity "${S3_WORKLOAD_IDENTITY_SERVICE_ACCOUNT}")
  fi
}
