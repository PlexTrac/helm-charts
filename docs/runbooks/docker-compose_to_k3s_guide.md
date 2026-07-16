# docker-compose to k3s migration guide

Guide to migrate your **application data** from a running production
**docker-compose** deployment to a production **single-node k3s** deployment.

The backup produces local per-component archives on your own hosts. You take a
fresh backup as part of this procedure; retaining routine backups outside of a
migration is your own responsibility.

Throughout this guide, replace `plextrac.mycompany.com` with your PlexTrac
hostname.

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

- **Backup (compose source):** the `plextrac backup` management utility already
  installed on your docker-compose host at `/opt/plextrac/.local/bin/plextrac`.
- **Restore (k3s target):** [`scripts/migration/k3s_restore.sh`](../../scripts/migration/k3s_restore.sh)
  from this repo. It restores the archives **already present** under
  `/opt/plextrac/backups/{couchbase,postgres,uploads}/` on the k3s host.
- **Backups after the migration:** [`scripts/migration/k3s_backup.sh`](../../scripts/migration/k3s_backup.sh)
  produces the same per-component archives from the k3s deployment. It is not
  part of the migration itself.

See [scripts/migration/README.md](../../scripts/migration/README.md) for options
and prerequisites.

## Before you start

Work through this checklist. Every command shown should succeed before you
continue.

**1. The target k3s cluster is running with the PlexTrac app deployed and healthy.**
Standing up the cluster and installing the chart is a separate, prior activity —
see the [user guide](../user-guide.md).

```bash
# on the k3s host: every pod Running and READY (e.g. 1/1)
kubectl -n plextrac get pods

# the API answers. DNS still points at your compose instance at this stage,
# so resolve the hostname to the k3s node explicitly:
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -sk --resolve plextrac.mycompany.com:443:$NODE_IP \
  https://plextrac.mycompany.com/api/v2/health/full
```

**2. The source docker-compose instance is healthy.**

```bash
# on the docker-compose host: every container Up
docker ps --format 'table {{.Names}}\t{{.Status}}'

curl -sk https://plextrac.mycompany.com/api/v2/health/full
```

**3. Source and target run the same PlexTrac version.**
Backup and restore across different versions is not supported. The running
application reports its own version in the health endpoint — compare the two
values and, if they differ, upgrade the older side first:

```bash
# on the docker-compose host
curl -sk https://plextrac.mycompany.com/api/v2/health/full | jq -r .data.version

# or, from the backend image label (from the install directory, /opt/plextrac):
docker image inspect $(docker compose images -q plextracapi | head -n1) \
  --format '{{ index .Config.Labels "org.opencontainers.image.version" }}'
```

```bash
# on the k3s host — DNS still points at compose, so pin the hostname to the k3s node
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -sk --resolve plextrac.mycompany.com:443:$NODE_IP \
  https://plextrac.mycompany.com/api/v2/health/full | jq -r .data.version
```

**4. The restore script and its tools are ready on the k3s host.**

```bash
# copy scripts/migration/k3s_restore.sh from this repo onto the k3s host, then:
chmod +x k3s_restore.sh
command -v bash jq tar        # all three must resolve
kubectl -n plextrac get pods  # kubectl must reach the cluster
```

**5. A maintenance window is scheduled.**
The backup process on compose involves downtime, as does the restore. Anything
users change **after the backup is taken** will not be migrated, so keep users
off the system from the moment you start step 1 until the cutover in step 7.

## Steps

### 1. Update the manager utility to v0.8.0

```bash
# on the docker-compose host, as the plextrac user
plextrac util-update
```

This updates the manager util to v0.8.0, which uses a new couchbase backup
binary, solving a few edge cases where full backups aren't taken.

### 2. Back up the compose source

```bash
# on the docker-compose host, as the plextrac user
plextrac backup -y -v   # full path: /opt/plextrac/.local/bin/plextrac
```

This writes one archive per component to
`/opt/plextrac/backups/{couchbase,postgres,uploads}/` on the compose host.

### 3. Transfer the archives to the k3s host

Create the directories on the k3s host, then copy the **newest** archive from
each component directory into the matching directory:

```bash
# on the k3s host
sudo mkdir -p /opt/plextrac/backups/{couchbase,postgres,uploads}
sudo chown -R $(whoami) /opt/plextrac/backups

# from the compose host (one archive per component)
scp /opt/plextrac/backups/couchbase/<newest>.tar.gz  <user>@<k3s-host>:/opt/plextrac/backups/couchbase/
scp /opt/plextrac/backups/postgres/<newest>.tar.gz   <user>@<k3s-host>:/opt/plextrac/backups/postgres/
scp /opt/plextrac/backups/uploads/<newest>.tar.gz    <user>@<k3s-host>:/opt/plextrac/backups/uploads/
```

Any transfer method you control works (scp, rsync, a storage bucket you own).
The restore picks the latest file in each directory on its own.

### 4. Verify the postgres metrics credentials exist (required)

The restore re-runs the chart's database init script inside the postgres pod.
That script requires `PG_METRICS_USER` and `PG_METRICS_PASSWORD` to exist in
the `application-secrets` Secret — **if either is missing, the restore fails**.

```bash
# on the k3s host — both commands must print a value (not an empty line)
kubectl -n plextrac get secret application-secrets \
  -o jsonpath='{.data.PG_METRICS_USER}' | base64 -d; echo
kubectl -n plextrac get secret application-secrets \
  -o jsonpath='{.data.PG_METRICS_PASSWORD}' | wc -c   # must be > 1
```

If either is empty:

- **`secrets.mode: manual`** — upgrade to the latest chart release and re-run
  your usual `helm upgrade` command. The chart adds any missing generated keys
  and preserves all existing values.
- **`secrets.mode: externalSecrets` or `csi`** — add both keys to your external
  secret store, then let the secret sync. See
  [secrets-modes.md](secrets-modes.md).

### 5. Restore into k3s

```bash
# on the k3s host
./k3s_restore.sh
```

The script restores each component in place: Couchbase (flush `reportMe`, then
`cbbackupmgr restore`), Postgres (block writes, drop and re-create the
databases, `pg_restore` of `core`/`runbooks`/`ckeditor`), uploads (into the
`plextracapi` volume), and clears the cached license. **This replaces the data
in the target cluster** — run it only against a deployment whose data you
intend to overwrite.

If the couchbase archive was taken with the deprecated `cbbackup` tool, add
`--legacy`.

### 6. Validate

Compare source and target with the same commands on both sides.

**Couchbase item count** — the two numbers must match:

```bash
# on the docker-compose host
docker exec $(docker ps -qf name=plextracdb | head -n1) /bin/bash -c \
  'cbstats 127.0.0.1:11210 all -u "$CB_ADMIN_USER" -p "$CB_ADMIN_PASS" -b reportMe | grep -w curr_items'

# on the k3s host
kubectl -n plextrac exec plextracdb-0 -- /bin/bash -c \
  'cbstats 127.0.0.1:11210 all -u "$CB_ADMIN_USER" -p "$CB_ADMIN_PASS" -b reportMe | grep -w curr_items'
```

**Postgres row counts** — exact per-table counts for all three databases, no
schema knowledge needed. On the compose host:

```bash
# on the docker-compose host
for db in core runbooks ckeditor; do
  echo "== $db =="
  docker exec -i $(docker ps -qf name=postgres | head -n1) /bin/bash -c \
    "PGPASSWORD=\$POSTGRES_PASSWORD psql -U \$POSTGRES_USER -d $db -t -A" <<'EOF'
SELECT table_name || '=' ||
       (xpath('/row/cnt/text()',
              query_to_xml(format('SELECT count(*) AS cnt FROM %I.%I', table_schema, table_name),
                           false, true, '')))[1]::text
FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
ORDER BY table_name;
EOF
done > /tmp/rowcounts-source.txt
```

The same on the k3s host, with the `docker exec` line swapped for `kubectl exec`:

```bash
# on the k3s host
for db in core runbooks ckeditor; do
  echo "== $db =="
  kubectl -n plextrac exec -i deploy/postgres -- /bin/bash -c \
    "PGPASSWORD=\$POSTGRES_PASSWORD psql -U \$POSTGRES_USER -d $db -t -A" <<'EOF'
SELECT table_name || '=' ||
       (xpath('/row/cnt/text()',
              query_to_xml(format('SELECT count(*) AS cnt FROM %I.%I', table_schema, table_name),
                           false, true, '')))[1]::text
FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
ORDER BY table_name;
EOF
done > /tmp/rowcounts-target.txt
```

Copy one file next to the other and compare — no output means they match:

```bash
# on the k3s host
scp <user>@<compose-host>:/tmp/rowcounts-source.txt /tmp/
diff /tmp/rowcounts-source.txt /tmp/rowcounts-target.txt && echo "row counts match"
```

**Uploads file count** — the two numbers should match. A small surplus on the
target can come from files the fresh install created before the restore;
investigate any large gap:

```bash
# on the docker-compose host
docker exec $(docker ps -qf name=plextracapi | head -n1) sh -c \
  'find /usr/src/plextrac-api/uploads -type f | wc -l'

# on the k3s host
kubectl -n plextrac exec deploy/plextracapi -- sh -c \
  'find /usr/src/plextrac-api/uploads -type f | wc -l'
```

**Application checks** — browse the target (use the `--resolve` trick from
"Before you start", or a hosts-file entry, since DNS still points at compose):

- Log in with an existing (migrated) account; MFA prompts work.
- Open an existing report and confirm the document editor loads it.
- Images and attachments in findings display.
- Runbooks content is present.

### 7. Move user traffic to the new deployment

Keep the application hostname **exactly the same** — only where it points
changes.

1. **Stop the application on the compose host** so nothing new is written to it:
   ```bash
   # on the docker-compose host, as the plextrac user
   plextrac stop
   ```
2. **Update your DNS record** (or load balancer / firewall rule) for
   `plextrac.mycompany.com` from the compose host's IP to the k3s host's IP.
   Lowering the record's TTL a day ahead of the window makes the change take
   effect faster.
3. **Verify:** `dig +short plextrac.mycompany.com` returns the k3s host's IP,
   and you can log in at `https://plextrac.mycompany.com`.
4. **Keep the compose host intact** (powered off is fine) as a rollback path
   until you are satisfied with the new deployment — rollback is
   `plextrac start` plus reverting the DNS change. Decommission it after
   sign-off.

## Troubleshooting

- **The postgres pod fails to start during the restore** complaining about
  `PG_METRICS_USER`/`PG_METRICS_PASSWORD`: the metrics credentials are missing —
  go back to step 4.
- **The couchbase restore cannot determine the archive directory**: the backup
  was taken with the deprecated `cbbackup` tool — re-run
  `./k3s_restore.sh --legacy`.
- **Reports fail to open in the document editor after the restore**: re-run the
  application migrations, which re-pair the editor credentials with the restored
  data. Run the exact `helm upgrade` command you deployed with (unchanged
  values); each upgrade creates a fresh `migrations-and-etl-<revision>` Job.
  Watch it complete:
  ```bash
  kubectl -n plextrac get jobs
  kubectl -n plextrac logs -f job/migrations-and-etl-<revision>
  ```

## Notes

- **Per-component archives:** the restore operates on the individual
  couchbase/postgres/uploads archives present on the host. It never assumes a
  single combined file.
- **The restore is destructive on the target:** it flushes the couchbase bucket
  and drops/recreates the postgres databases before loading the archives.
