# Migration scripts (docker-compose to k3s)

Scripts for migrating PlexTrac **application data** from a docker-compose
deployment to a single-node k3s deployment. The full procedure is in
[docs/runbooks/docker-compose_to_k3s_guide.md](../../docs/runbooks/docker-compose_to_k3s_guide.md).

## Contents

| File | Runs on | Purpose |
|---|---|---|
| `k3s_restore.sh` | k3s host | Restore the latest archive found in each of `/opt/plextrac/backups/{couchbase,postgres,uploads}/` into the cluster. |
| `k3s_backup.sh` | k3s host | Back up a running k3s deployment (couchbase, postgres, uploads) to per-component archives under `/opt/plextrac/backups/`. Not used during the migration itself; use it for routine backups of the new deployment afterwards. The docker-compose source is backed up with the `plextrac backup` utility instead. |

## Prerequisites (on the k3s host)

- `kubectl` configured for the target cluster (`export KUBECONFIG=...`) — verify with `kubectl -n plextrac get pods`.
- `bash`, `jq`, and `tar` available — verify with `command -v bash jq tar`.
- The app already deployed and healthy in the `plextrac` namespace.
- For a restore: the archives staged under `/opt/plextrac/backups/{couchbase,postgres,uploads}/`.

## Usage

Each script takes `-h` for options. Both accept `-c`/`-p`/`-u` to limit to a
single component (couchbase/postgres/uploads), `-n` for a dry run, and `-v` for
verbose output. If a couchbase backup was taken with the deprecated `cbbackup`
tool, pass `--legacy` to both the backup and the restore.

```bash
# restore the archives already staged under /opt/plextrac/backups/
./k3s_restore.sh

# back up the k3s deployment (after the migration)
./k3s_backup.sh
```

## Notes

- The scripts assume the chart's default namespace (`plextrac`) and pod labels.
- The restore replaces the data in place: it flushes the couchbase bucket and
  drops/recreates the postgres databases before loading the archives. Run it
  only against a deployment whose data you intend to overwrite.
