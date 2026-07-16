# docker-compose to k3s migration guide

Guide to migrate your **application data** from a running production
**docker-compose** deployment to a production **single-node k3s** deployment.

Backup and restore are performed by the scripts in
[`scripts/migration/`](../../scripts/migration/) (vendored from the pt-ansible
repo, which stays canonical). The backup method produces local per-component
archives on your host. You take a fresh backup as part of the cutover; retaining
backups the rest of the time is your own responsibility.

## What moves

The backup creates a **separate archive per data component**. There is no single
combined tarball, and the restore consumes the latest archive found in each
directory independently:

| Component | Archive directory (on the host) | Restored into (k3s) |
|---|---|---|
| Couchbase (`reportMe`) | `/opt/plextrac/backups/couchbase/*.tar.gz` | `plextracdb-0` |
| Postgres (`core`, `runbooks`, `ckeditor`) | `/opt/plextrac/backups/postgres/*.tar.gz` | `postgres` |
| Uploads | `/opt/plextrac/backups/uploads/*.tar.gz` | `plextracapi` PVC |

**Not migrated:**
- **MinIO** is transit-only. Its contents are temporary and idempotent; no persistent files live there and no backup process captures it.
- **Keycloak / Synqly** are not part of the docker-compose stack; set them up on k3s separately if you use them.

## Scripts

The scripts live in [`scripts/migration/`](../../scripts/migration/) in this
repo (vendored from pt-ansible, which stays canonical). Copy them onto the host
that runs each step; see that directory's [README](../../scripts/migration/README.md)
for prerequisites and options.

- **Backup**, compose source: the `plextrac backup` management utility that ships with the docker-compose install. (`scripts/migration/k3s_backup.sh` produces the same per-component layout from a k3s cluster, for backing up the new deployment later.)
- **Restore**, k3s target: `scripts/migration/k3s_restore.sh` restores archives **already present** under `/opt/plextrac/backups/{couchbase,postgres,uploads}/`.
- **CKEditor re-point**: `scripts/migration/k3s_cke_fix.sh` (uses `recovery_script.js` from the same directory).

## Before you start

- The target **single-node k3s cluster is running with the PlexTrac app deployed and healthy** (`plextracapi` Ready, `/api/v2/health/full` passing). Standing up the cluster is a separate, prior activity.
- The source **docker-compose instance is healthy** and reachable; note its PlexTrac version and match it on the target.
- The scripts from [`scripts/migration/`](../../scripts/migration/) are copied onto the k3s host, and on that host you have `kubectl` pointed at the target cluster (`export KUBECONFIG=...`) plus `jq`, `tar`, and `bash`.
- Schedule a maintenance window. The compose instance stays authoritative until cutover.

## Steps

### 1. Back up the compose source
```bash
# on the docker-compose host, as the plextrac user
plextrac backup -y -v
```
Writes the per-component archives to `/opt/plextrac/backups/{couchbase,postgres,uploads}/` on the source host.

### 2. Transfer the archives to the k3s host
Copy the newest archive from **each** of `/opt/plextrac/backups/{couchbase,postgres,uploads}/` on the source into the same directories on the k3s host. Use any direct transfer (scp, or a bucket the ops team controls). The restore picks the latest file in each directory on its own.

### 3. Restore into k3s
```bash
# on the k3s host, with kubectl pointed at the target cluster
./k3s_restore.sh
```
`k3s_restore.sh` restores each component in place: Couchbase (flush `reportMe`, then `cbbackupmgr restore`), Postgres (block writes, drop and re-run `initdb.sh`, `pg_restore` of `core`/`runbooks`/`ckeditor`), Uploads (into the plextracapi PVC), and clears the cached license. If the source Couchbase archive was taken with the deprecated `cbbackup`, add `--legacy`.

### 4. Re-point CKEditor
```bash
# on the k3s host, with kubectl pointed at the target cluster
./k3s_cke_fix.sh
```
Regenerates `CKEDITOR_SERVER_CONFIG` so migrated reports open in the editor. This rotates live secrets against CKEditor's cloud, so run it only during the migration.

### 5. Validate
- Couchbase `reportMe` item count matches the source.
- Postgres row counts (for example `finding`, `public.user`, `tenant`) match the source.
- Log in and confirm reports, findings, and images load, and that MFA works.

### 6. Cut over
Point your DNS/traffic at the k3s ingress. Keep the compose instance intact (powered off is fine) until you have confirmed everything works, then decommission it.

## Notes

- **Per-component archives:** the restore operates on the individual couchbase/postgres/uploads archives present on the host. It never assumes a single combined file.
- **Chart dependency:** the restore re-runs the chart's `initdb.sh`, which requires `PG_METRICS_USER`/`PG_METRICS_PASSWORD` in `application-secrets` (the chart generates these in `manual` mode; supply them via your store in `externalSecrets`/`csi`, see [secrets-modes.md](secrets-modes.md)).
