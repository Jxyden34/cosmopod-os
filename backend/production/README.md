# Production Mender deployment

This template pins Helm chart `mender/mender` to `7.7.4` and Mender service
images to release tag `v4.1.1`. For production, resolve every image to a
reviewed registry digest in a private values overlay. This is a starting point, not a
turn-key production cluster.

This chart has been rendered locally for validation only. It has not been
installed to a cluster, and `https://kys.dpdns.org` will not serve Mender until
an origin, DNS/TLS, external services, and secrets are provisioned.

## Required platform services

Provide these before installing the chart:

- Kubernetes, ingress controller, TLS automation, monitoring, alerting, and
  tested backup/restore.
- External highly available MongoDB. Chart-bundled MongoDB is disabled.
- S3-compatible private artifact storage with TLS, versioning, lifecycle
  policy, encryption, and least-privilege credentials.
- Three-node persistent NATS/JetStream from the pinned chart settings, or a
  separately operated NATS service wired through `global.nats`.

Do not store secret values in this repository. Have External Secrets,
Sealed Secrets, SOPS, or the platform secret manager create these objects:

| Secret | Required data keys |
| --- | --- |
| `cosmopod-mender-mongodb` | `MONGO`, `MONGO_URL` |
| `cosmopod-mender-s3` | `AWS_URI`, `AWS_BUCKET`, `STORAGE_BUCKET`, `AWS_REGION`, `AWS_FORCE_PATH_STYLE`, plus `AWS_AUTH_KEY` and `AWS_AUTH_SECRET` when workload identity is not used; optionally `AWS_EXTERNAL_URI` |
| `cosmopod-mender-smtp` | `EMAIL_SENDER`, `SMTP_HOST`, `SMTP_AUTH_MECHANISM`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_SSL` |
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

## Render, review, install

The template endpoint is `https://kys.dpdns.org`. It currently resolves to
Cloudflare proxy addresses. Large Mender Artifacts may exceed proxy upload or
request-duration limits; use a DNS-only record or explicitly qualify the
selected Cloudflare plan before production. Review storage class, resource,
replica, ingress, and network-policy choices first.

```bash
helm repo add mender https://charts.mender.io
helm repo update

helm show chart mender/mender --version 7.7.4
helm template cosmopod-mender mender/mender \
  --namespace mender \
  --version 7.7.4 \
  --values values.yaml > /tmp/cosmopod-mender-rendered.yaml

helm upgrade --install cosmopod-mender mender/mender \
  --namespace mender \
  --create-namespace \
  --version 7.7.4 \
  --values values.yaml \
  --wait \
  --timeout 20m
```

Expected `helm show chart` fields:

```text
appVersion: v4.1.1
version: 7.7.4
```

Run policy checks against rendered YAML before install. Verify pods, ingress,
TLS, MongoDB migrations, artifact upload/download, device authentication,
backup restoration, and a canary update before admitting production devices.

Chart rollback does not guarantee database downgrade safety. Back up first,
read release notes, and test upgrades and rollback in staging.

Official references:

- <https://docs.mender.io/server-installation/production-installation-with-kubernetes>
- <https://docs.mender.io/server-installation/production-installation-with-kubernetes/mender-server>
- <https://github.com/mendersoftware/mender-helm/releases/tag/mender-7.7.4>
