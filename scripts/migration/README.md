# Migration scripts (docker-compose to k3s)

Scripts for migrating PlexTrac **application data** from a docker-compose
deployment to a single-node k3s deployment. The full procedure is in
[docs/runbooks/docker-compose_to_k3s_guide.md](../../docs/runbooks/docker-compose_to_k3s_guide.md).

These are vendored from the **pt-ansible** repo (`roles/plextrac/files`), which
remains the canonical source. Keep them in sync with upstream.

## Contents

| File | Runs on | Purpose |
|---|---|---|
| `k3s_backup.sh` | k3s host | Back up a running k3s cluster (couchbase, postgres, uploads) to per-component archives under `/opt/plextrac/backups/`. For backing up the k3s deployment itself; the compose source is backed up with the `plextrac backup` utility instead. |
| `k3s_restore.sh` | k3s host | Restore the latest archive found in each of `/opt/plextrac/backups/{couchbase,postgres,uploads}/` into the cluster. |
| `k3s_cke_fix.sh` | k3s host | Re-point CKEditor after a restore. Runs `recovery_script.js` inside the CKEditor pod to regenerate `CKEDITOR_SERVER_CONFIG`. |
| `recovery_script.js` | inside CKEditor pod | Rotates each tenant environment's CKE secrets and prints a fresh `CKEDITOR_SERVER_CONFIG`. Invoked by `k3s_cke_fix.sh`; not run directly. |

## Prerequisites (on the k3s host)

- `kubectl` configured for the target cluster (`export KUBECONFIG=...`).
- `bash`, `jq`, and `tar` available.
- The app already deployed and healthy in the `plextrac` namespace.
- For a restore: the archives staged under `/opt/plextrac/backups/{couchbase,postgres,uploads}/`.

## Usage

Each script takes `-h` for options. `k3s_backup.sh` and `k3s_restore.sh` accept
`-c`/`-p`/`-u` to limit to a single component, `-n` for a dry run, and `-v` for
verbose output. If a couchbase backup was taken with the deprecated `cbbackup`
tool, pass `--legacy` to both the backup and the restore.

```bash
# back up the k3s cluster (the migration backs up the compose source with `plextrac backup`)
./k3s_backup.sh

# restore the archives already staged under /opt/plextrac/backups/
./k3s_restore.sh

# re-point CKEditor
./k3s_cke_fix.sh
```

## Notes

- `k3s_cke_fix.sh` / `recovery_script.js` rotate live secrets against
  CKEditor's cloud. Run them only as part of a controlled migration or recovery.
- The scripts assume the chart's default namespace (`plextrac`) and pod labels.
