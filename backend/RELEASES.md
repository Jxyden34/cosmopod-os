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

For a guarded production upload, place a short-lived Personal Access Token in
a mode-0600 file supplied by the secret manager. First run a local-only plan:

```bash
backend/production/release.sh \
  --action upload \
  --version 0.37.0 \
  --board pi4 \
  --approve-artifact-sha256 <independently-approved-signed-sha256>
```

After reviewing every verified identity, repeat with `--apply --token-file
/secure/mender-release-manager.token`. The script uses the standard Open Source
multipart API, not Enterprise direct upload. It verifies the authenticated
release index, Artifact signature, signing record, internal name, device type,
server URL, and approved digest before reading the token. Successful upload
creates a non-secret receipt under `backend/.runtime/release-records/`.

## 3. Deploy safely

Create the four static groups named `ring-0-lab`, `ring-1-canary`,
`ring-2-beta`, and `ring-3-stable`. First deployment example:

```bash
backend/production/release.sh \
  --action deploy \
  --version 0.37.0 \
  --board pi4 \
  --approve-artifact-sha256 <independently-approved-signed-sha256> \
  --ring ring-0-lab \
  --approve-ring ring-0-lab \
  --deployment-name cosmopod-0.37.0-pi4-ring-0 \
  --upload-record backend/.runtime/release-records/upload-....record
```

Review plan, then repeat with `--apply --token-file ...`. A higher ring requires
`--previous-record` from exact preceding ring. Stable additionally requires
`--approve-stable`. Receipt proves API accepted operation; it does not prove
devices succeeded. Inspect deployment results and acceptance evidence before
promoting. Archive receipts in immutable release ledger.

Automation uses this management API shape:

```http
POST /api/management/v1/deployments/deployments/group/ring-0-lab
Authorization: Bearer <injected-at-runtime>
Content-Type: application/json

{
  "name": "cosmopod-0.37.0-pi4-ring-0",
  "artifact_name": "cosmopod-os-0.37.0-pi4",
  "phases": [
    {"batch_size": 1},
    {"batch_size": 5},
    {}
  ],
  "retries": 3
}
```

Use unique deployment name. Token never appears in curl arguments. Monitor
deployment status after every ring; stop rollout on boot, health-check,
connectivity, or rollback failures.

Promote exact signed Artifact through `ring-0-lab`, `ring-1-canary`,
`ring-2-beta`, then `ring-3-stable`. Do not rebuild between rings. Fleet
rollback is new deployment of last known-good Artifact; client-side A/B health
checks remain first recovery line.

Official references:

- <https://docs.mender.io/server-integration/using-the-apis>
- <https://docs.mender.io/artifact-creation/ci-cd>
- <https://docs.mender.io/api/3.0/>
