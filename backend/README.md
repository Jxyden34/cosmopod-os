# Cosmopod Mender backend

Two deliberately separate deployment paths live here:

- `scripts/`: disposable local evaluation using upstream Docker Compose.
- `production/`: Kubernetes Helm template for a reviewed production platform.

Docker Compose is **lab-only**. Upstream Mender explicitly directs production
operators to its Helm chart.

## Evaluation lab

Run inside Linux or WSL2 with Git, Docker Engine, and Docker Compose v2.24.4+
available to the current user.

```bash
cd cosmopod-os/backend
cp .env.example .env
bash scripts/bootstrap-evaluation.sh
bash scripts/start.sh
bash scripts/status.sh
```

Bootstrap initializes `backend/.state/mender-server`, fetches only official
Mender Server commit
`c5edfdb18b05e7f623580a53c2180fc45ae5f157` (`v4.1.1`), checks the exact
checkout, validates Compose configuration, and refuses unexpected remotes or
dirty checkout replacement. It does not edit `/etc/hosts`, create users, or
write secrets.

Review and add this lab-only host mapping yourself if status reports it
missing:

```text
127.0.0.1 docker.mender.io s3.docker.mender.io
```

Open <https://docker.mender.io>. Evaluation TLS is local and not production
trust material.

The override binds ports 80/443 to `127.0.0.1` by default and requires Compose
2.24.4's `!override` merge tag. Setting `MENDER_BIND_ADDRESS=0.0.0.0` is an
explicit trusted-LAN decision; apply a host firewall and never expose this lab
composition to the public Internet.

Create the first lab administrator without putting its password in a file or
shell history:

```bash
read -r -p 'Admin email: ' MENDER_USERNAME
read -r -s -p 'Admin password: ' MENDER_PASSWORD
printf '\n'
docker compose \
  --project-name cosmopod-mender-eval \
  --project-directory .state/mender-server \
  exec -T useradm useradm create-user \
  --username "$MENDER_USERNAME" \
  --password "$MENDER_PASSWORD"
unset MENDER_USERNAME MENDER_PASSWORD
```

Use a disposable strong password. This official evaluation command passes it
to `useradm`; do not use this Compose lab for real devices or Internet access.

Stop while retaining lab data:

```bash
bash scripts/stop.sh
```

No script runs `docker compose down --volumes`; deleting lab data remains an
explicit operator action.

## Production and releases

Read [production/README.md](production/README.md) before adapting the pinned
Helm values. Read [RELEASES.md](RELEASES.md) for signed Artifact upload,
canary deployment, promotion, monitoring, and rollback guidance.

Version pins:

| Component | Pin |
| --- | --- |
| Mender Server source | `c5edfdb18b05e7f623580a53c2180fc45ae5f157` |
| Mender Server image | `v4.1.1` |
| Mender Helm chart | `7.7.4` |

Official source: <https://github.com/mendersoftware/mender-server/tree/c5edfdb18b05e7f623580a53c2180fc45ae5f157>
