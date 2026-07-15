# Restore from an offsite backup (data migration)

How to load a PlexTrac-provided encrypted backup into a Helm deployment. The
intended use is a **customer data migration**: you stand up a fresh PlexTrac
deployment with this chart in your own environment, confirm it is healthy, then
restore your data into it with [`scripts/restore-from-backup.sh`](../../scripts/restore-from-backup.sh).

Restore is a **manual, one-time, destructive** operation. It is deliberately not
part of `helm install`/`helm upgrade`.

## What the backup contains

PlexTrac provides a single file named like `yourdomain_2026.07.14-11.30.00.tar.gz.aes-256-ctr`.
It is a gzipped tar encrypted with `openssl enc -aes-256-ctr -pbkdf2`, and it
holds one archive per data store:

| Store | Restored into | Notes |
|---|---|---|
| Couchbase (`reportMe`) | pod `plextracdb-0` | reports, findings, most application data |
| Postgres | deployment `postgres` | databases `core`, `runbooks`, `ckeditor` only |
| Uploads | `plextracapi` PVC at `/usr/src/plextrac-api/uploads` | report images and attachments |
| MinIO bucket `cloud` | object storage | asset-import files; restored **only if present** in the backup |

**Not migrated** (re-provisioned in the new environment instead):

- **Keycloak / Synqly** — SSO and integrations are set up fresh in the target: re-run the Keycloak realm-setup Job and reconnect your IdP; re-add integrations. They are not in the backup.
- **Redis** — cache only. The restore clears the cached license so the restored license is re-read.

## Prerequisites

1. **A running PlexTrac deployment** installed with this chart, reporting healthy (`plextracapi` pods Ready). See [docs/user-guide.md](../user-guide.md).
2. **Version parity.** The deployed app version should match the version the backup was taken from. A cross-version restore can leave the database needing migrations.
3. **The backup file and its passphrase**, delivered by PlexTrac over a secure channel.
4. **`kubectl`** pointed at the target cluster, plus `openssl` and `tar` on the machine running the script. Install **`mc`** (the MinIO client) only if the backup includes MinIO objects.

> **Pause GitOps sync during the restore.** If the deployment is managed by ArgoCD or a Helm auto-sync, pause it first. The Postgres step temporarily patches the `postgres` Deployment, and an auto-sync can revert that mid-restore.

## Encryption keys: nothing to carry

No value in `application-secrets` needs to travel with the data:

- **Datastore credentials** (`PG_*`, `CB_*`, `POSTGRES_*`, `REDIS_PASSWORD`, `MINIO_*`, `CLOUD_STORAGE_*`) only need the app and its datastore to agree. The restore recreates database users from the target's secrets, so freshly generated values are fine.
- **Session and service keys** (`JWT_KEY`, `COOKIE_KEY`, `PROVIDER_CODE_KEY`, `INTERNAL_API_KEY_SHARED`, `CKEDITOR_ENVIRONMENT_SECRET_KEY`) sign short-lived tokens or authenticate services. Regenerate them freely; at worst, users log in again.
- Your actual data — including **MFA enrollments** — travels inside the couchbase and postgres dumps. It does not depend on carrying any `application-secrets` value.

PlexTrac's codebase does contain an optional field-level (column) encryption feature
rooted in an `ENCRYPTION_KEYS` value, which *would* be data-at-rest key material. It is
not wired into this chart and, as of this writing, has never been enabled in any
deployment (the installers never set it, and it is unset on inspected instances), so it
is out of scope here. If that ever changes, carrying `ENCRYPTION_KEYS` from the source
would become a prerequisite — confirm current status with the InfoSec team first.

## Restore

Always dry-run first. It reports health, verifies the passphrase, and prints what
it would do without changing anything.

```bash
# 1. Dry run
./scripts/restore-from-backup.sh \
  --file /path/to/yourdomain_2026.07.14.tar.gz.aes-256-ctr \
  --namespace plextrac \
  --dry-run

# 2. Real run (prompts for the passphrase; asks you to type the namespace to confirm)
./scripts/restore-from-backup.sh \
  --file /path/to/yourdomain_2026.07.14.tar.gz.aes-256-ctr \
  --namespace plextrac
```

Passphrase handling (never pass it as a plain argument):

- Default: the script prompts interactively.
- `--passphrase-file <path>`: read from a `600`-permission file.
- `PLEXTRAC_BACKUP_PASSPHRASE` env var: honored if set (for controlled automation).

Useful options:

- `--components couchbase,postgres` — restore only some stores.
- `--legacy` — only if PlexTrac tells you the couchbase backup was taken with the deprecated `cbbackup` tool.
- `-y, --yes` — skip the confirmation prompt.

### What it does, and what to expect

- Verifies the passphrase, then reports application health and asks you to confirm.
- **Couchbase:** flushes the `reportMe` bucket, then restores (destructive replace).
- **Postgres:** patches the `postgres` Deployment to block writes (the app cannot reach the database for a minute or two), drops and recreates `core`/`runbooks`/`ckeditor`, restores each, then restores normal networking.
- **Uploads:** extracts into the `plextracapi` PVC.
- **MinIO:** restores the `cloud` bucket if the backup contains it; otherwise warns.
- **License:** clears the cached license.

The application will be degraded while Postgres is isolated. That is expected.

## Validation

The script prints a couchbase item count and per-database table counts. Then check
manually:

- Log in and confirm reports, findings, and images load.
- Confirm users can authenticate, including **MFA** (its secret travels in the couchbase dump).
- If `plextracapi` stayed degraded after the restore: `kubectl -n plextrac rollout restart deploy/plextracapi`.
- Re-enable GitOps sync if you paused it.

## Troubleshooting

**"could not decrypt/verify the backup"** — wrong passphrase or a corrupt/truncated file. Re-check the passphrase and re-download.

**"could not determine cbbackupmgr archive dir ... re-run with --legacy"** — the couchbase archive was produced by the old `cbbackup` tool. Re-run with `--legacy`.

**Postgres left unreachable after an interruption** — the script's cleanup restores the container port automatically on exit. If you killed it hard, restore it manually:

```bash
kubectl -n plextrac patch deployment postgres --type json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/ports/0/containerPort","value":5432}]'
```

**Partial restore** — the per-store steps are independent and idempotent. Re-run with `--components` limited to the store that failed.

**"no MinIO objects in this backup"** — expected with current backups (see below). Asset-import files under `cloud/uploads` are not yet captured.

## For the backup owners: making a migration complete

For a fully reference-intact migration, the backup produced by `pt-ansible`
(`k3s_backup.sh` / `k3s_offsite_backup.sh`) needs one addition, which the restore
script already consumes when present:

1. **MinIO bucket.** The `cloud` bucket (asset-import files, keyed by database record
   ID) is not captured today. Add an `mc mirror` of the bucket to the backup as a
   `*-minio-*.tar.gz` containing a `cloud/` tree. Without it, restored records can
   reference objects that do not exist.

No `application-secrets` key needs carrying: datastore credentials and session/service
keys are regenerated in the target, and all data (including MFA enrollments) travels in
the database dumps. The only theoretical exception is `ENCRYPTION_KEYS` (optional
field-level encryption), which is not enabled anywhere today; confirm with the InfoSec
team if that ever changes.
