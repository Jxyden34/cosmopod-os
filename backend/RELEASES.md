# Uploading and deploying Cosmopod releases

Mender deployments reference an Artifact by its internal Artifact name, not
only its filename. Devices must already be accepted and report a compatible
device type.

## 1. Build and verify

Produce a signed `.mender` Artifact from the OS release pipeline. Keep the
private signing key in an offline or CI secret system; ship only its public
verification key to devices.

```bash
mender-artifact validate cosmopod-release.mender \
  -k meta-cosmopod/recipes-mender/mender/files/artifact-verify-key.pem
mender-artifact read cosmopod-release.mender
```

Confirm Artifact name, compatible device type (`cosmopod-rpi4-64` or
`cosmopod-rpi5`), checksum, signature, partition layout, rollback behavior, and
release notes before upload.

## 2. Upload

Use an individual account or automation identity with minimum release-manager
rights. Interactive login keeps credentials out of repository files:

```bash
mender-cli login --server https://kys.dpdns.org --username operator@example.com
mender-cli artifacts --server https://kys.dpdns.org upload cosmopod-release.mender
```

For CI, inject a short-lived session token or Personal Access Token from its
secret manager. Never commit it, echo it, add it to `.env`, or hard-code it in
a pipeline. Standard upload is used here; direct upload is an Enterprise-only
feature and is disabled in the Open Source production template.

## 3. Deploy safely

Preferred first deployment: Mender UI to a small static `canary` group. Verify
health, reboot, Wayland session, SSH access, application state, and automatic
rollback before expanding.

Automation uses this management API shape:

```http
POST /api/management/v1/deployments/deployments/group/canary
Authorization: Bearer <injected-at-runtime>
Content-Type: application/json

{
  "name": "cosmopod-2026.07.15-canary",
  "artifact_name": "cosmopod-2026.07.15",
  "phases": [
    {"batch_size": 1},
    {"batch_size": 5},
    {}
  ],
  "retries": 3
}
```

Use a unique deployment name. Treat deployment group and Artifact name as
validated input. Inject the bearer token at runtime and redact HTTP headers
from logs. Monitor deployment status after every phase; stop rollout on boot,
health-check, connectivity, or rollback failures.

Promote the exact same signed Artifact from canary to staging to production.
Do not rebuild between rings. A fleet rollback is a new deployment of the last
known-good Artifact; client-side A/B health checks remain the first recovery
line.

Official references:

- <https://docs.mender.io/server-integration/using-the-apis>
- <https://docs.mender.io/artifact-creation/ci-cd>
- <https://docs.mender.io/api/3.0/>
