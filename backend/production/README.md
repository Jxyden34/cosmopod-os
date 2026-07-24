# Production Mender deployment

This template pins Helm chart `mender/mender` to `7.7.4` and defaults Mender
service images to release tag `v4.1.1`. Production preflight rejects every
rendered workload image that is not pinned with `@sha256:<digest>`. Supply a
reviewed, non-secret digest overlay with `--values`; base values alone are
intentionally not deployable. This remains a platform template, not a turn-key
production cluster.

This chart has been rendered locally for validation only. It has not been
installed to a cluster, and `https://kys.dpdns.org` will not serve Mender until
an origin, DNS/TLS, external services, and secrets are provisioned.

## Required platform services

Provide these before installing the chart:

- Kubernetes, ingress controller, TLS automation, monitoring, alerting, and
  tested backup/restore.
- External highly available MongoDB over SRV TLS or an explicitly TLS-enabled
  MongoDB URI. Chart-bundled MongoDB is disabled.
- S3-compatible private artifact storage with TLS, versioning, lifecycle
  policy, encryption, and least-privilege credentials.
- External authenticated, persistent, monitored NATS over `tls://`. Integrated
  unauthenticated NATS is disabled.
- CNI-enforced operator-owned NetworkPolicies named `cosmopod-default-deny`
  and `cosmopod-mender-allow`. Default deny must select every pod and deny both
  directions. Allow policy must select `app.kubernetes.io/instance:
  cosmopod-mender`; every rule must define nonempty selectors or bounded IP
  blocks and explicit single ports; `endPort` ranges are rejected. Each
  direction is capped at one `/8` equivalent for IPv4 and one `/32` equivalent
  for IPv6, including aggregate ranges. Any additional policy whose selector
  could match this Helm release is rejected because NetworkPolicies are
  additive.

Do not store secret values in this repository. Have External Secrets,
Sealed Secrets, SOPS, or the platform secret manager create these objects:

| Secret | Required data keys |
| --- | --- |
| `cosmopod-mender-mongodb` | `MONGO`, `MONGO_URL`; both must use `mongodb+srv://` without TLS disablement or `mongodb://` with `tls=true`; TLS insecure and invalid-certificate/hostname flags are rejected |
| `cosmopod-mender-s3` | `AWS_URI` over HTTPS, `AWS_BUCKET`, `STORAGE_BUCKET`, `AWS_REGION`, `AWS_FORCE_PATH_STYLE`, plus `AWS_AUTH_KEY` and `AWS_AUTH_SECRET` when workload identity is not used; optional `AWS_EXTERNAL_URI` must use HTTPS |
| `cosmopod-mender-smtp` | `EMAIL_SENDER`, `SMTP_HOST`, `SMTP_AUTH_MECHANISM`, `SMTP_USERNAME`, `SMTP_PASSWORD`, and `SMTP_SSL=true` |
| `cosmopod-mender-nats` | `NATS_URL`, using `tls://` and authenticated userinfo |
| `cosmopod-mender-deviceauth-signing` | `private.pem`, a unique Ed25519 private key for device authentication tokens |
| `cosmopod-mender-useradm-signing` | `private.pem`, a different unique Ed25519 private key for user tokens |
| `mender-ingress-tls` | Standard `kubernetes.io/tls` keys, normally managed by cert-manager |

Redis is used by Mender Enterprise features in chart `7.7.4`, not by this Open
Source configuration. The chart's convenience Redis deployment remains
disabled; do not create a Redis secret that no rendered workload consumes.

Use separate MongoDB users and S3 credentials per environment. Restrict
secret read access to Mender service accounts. Generate both signing keys with
`openssl genpkey -algorithm ED25519`; never reuse one key for both services.
Never paste secret values into `values.yaml` or command history. Back up the
signing keys securely: replacing either one invalidates issued tokens.

## Guarded production workflow

The template endpoint is `https://kys.dpdns.org`. It currently resolves to
Cloudflare proxy addresses. Current release Artifact is about 239.6 MiB, so
production preflight requires DNS-only delivery and rejects Cloudflare proxy
addresses. Review storage class, resource, replica, ingress, and network-policy
choices first.

Confirm that this hostname is dedicated to Mender before changing DNS or its
origin virtual host. If it already serves another application, move Mender to
a dedicated update hostname instead of silently replacing that service. The
deployment command requires an exact hostname approval but cannot decide
whether replacing existing content is acceptable.

Run tooling from Linux with Bash, Helm, the Helm diff plugin, kubectl, jq,
OpenSSL, curl, GNU base64, and sha256sum. Configure the pinned chart repository:

```bash
helm repo add mender https://charts.mender.io
helm repo update
helm show chart mender/mender --version 7.7.4
```

Expected `helm show chart` fields:

```text
appVersion: v4.1.1
version: 7.7.4
```

Create namespace, required secrets, TLS certificate, ingress class, and storage
class, external NATS, and both required NetworkPolicies before using these
scripts. Scripts never create namespace, secret, or policy objects. Keep digest
overlays free of credentials; secret values belong only in the platform secret
manager. Files matching private values, kubeconfig,
Terraform state, plans, and rendered output are ignored by Git.

Preflight is read-only against Kubernetes. It checks exact context and
hostname, Active namespace, ingress/storage classes, required NetworkPolicies,
required secret data-key
names without printing values, Kubernetes secret types, distinct Ed25519 token
keys, authenticated external NATS, TLS hostname/expiry/key match, chart version,
chart archive SHA-256 `1ed0eb4bf3d3af5108483bbbdab37c17090eb49b1e3010eefe3174a26fdefc40`,
rendered host/ingress/storage and structural per-workload secret references,
digest-pinned images, and a public DNS-only artifact path. Rendered manifests
remain inside a private
temporary directory and are deleted; Helm diff suppresses Secret content. DNS
addresses inside current official Cloudflare ranges are rejected for the 239.6
MiB release Artifact:

```bash
backend/production/preflight.sh \
  --context cosmopod-production \
  --hostname kys.dpdns.org \
  --namespace mender \
  --ingress-class nginx \
  --storage-class encrypted-rwo \
  --values /secure/non-secret/mender-image-digests.yaml
```

For S3 workload identity, add
`--s3-workload-identity <service-account-name>`. Service account must already
exist with a valid AWS EKS IRSA `eks.amazonaws.com/role-arn` annotation. Every
rendered workload consuming the S3 secret must use that service account. GKE
workload-identity annotations are not accepted for AWS SigV4 access. Otherwise
preflight requires `AWS_AUTH_KEY` and `AWS_AUTH_SECRET` keys in
`cosmopod-mender-s3`.

Deployment reruns preflight, requires three independent gates, shows a
secret-suppressed Helm diff, and uses atomic Helm install/upgrade. Backup
reference must identify a tested, restorable snapshot; `yes` is not accepted.
Namespace must already exist:

```bash
backend/production/deploy.sh \
  --context cosmopod-production \
  --hostname kys.dpdns.org \
  --namespace mender \
  --ingress-class nginx \
  --storage-class encrypted-rwo \
  --values /secure/non-secret/mender-image-digests.yaml \
  --apply \
  --approve-hostname kys.dpdns.org \
  --confirm-backup mongodb-snapshot-2026-07-16T120000Z
```

Run postflight after deployment. It waits for release-labelled Deployments and
StatefulSets, runs Helm tests, then probes Mender user-administration and device
authentication APIs. A generic website response cannot pass:

```bash
backend/production/postflight.sh \
  --context cosmopod-production \
  --hostname kys.dpdns.org \
  --namespace mender
```

Then verify MongoDB migrations, authenticated artifact upload/download, device
authentication, backup restoration, and a real canary A/B update before
admitting production devices. These require credentials or hardware and are
not claimed by postflight.

Chart rollback does not guarantee database downgrade safety. Back up first,
read release notes, and test upgrades and rollback in staging.

Official references:

- <https://docs.mender.io/server-installation/production-installation-with-kubernetes>
- <https://docs.mender.io/server-installation/production-installation-with-kubernetes/mender-server>
- <https://github.com/mendersoftware/mender-helm/releases/tag/mender-7.7.4>
