#!/usr/bin/env bash
## Script: restore-from-backup.sh
## Version: 2026-07-15
## Description:
##   Restore a PlexTrac Helm deployment from an offsite backup produced by the
##   pt-ansible backup tooling (k3s_backup.sh + k3s_offsite_backup.sh). Intended
##   for customer data migrations: stand up a fresh deployment with this chart,
##   confirm it is healthy, then run this script to load a provided backup.
##
##   The backup is a single AES-256-CTR encrypted tarball. This script decrypts
##   it, locates the per-component archives inside, and restores each into the
##   running cluster:
##     - couchbase -> plextracdb-0 (bucket reportMe) via cbbackupmgr (or --legacy cbrestore)
##     - postgres  -> postgres deployment, databases core/runbooks/ckeditor only
##     - uploads   -> plextracapi PVC (/usr/src/plextrac-api/uploads)
##     - minio     -> object storage bucket "cloud" (only if the backup contains it)
##
##   This is destructive: the couchbase bucket is flushed and the core/runbooks/
##   ckeditor databases are dropped and recreated before data is loaded.
## ---
## Usage:
##   ./scripts/restore-from-backup.sh --file <backup.tar.gz.aes-256-ctr> [options]
##
## Passphrase (choose one; never pass the passphrase as a plain argument):
##   --passphrase-file <path>        Read the passphrase from a file (perms checked)
##   env PLEXTRAC_BACKUP_PASSPHRASE  Honored if set (use for controlled automation)
##   (interactive prompt)            Default when neither is provided
##
## Options:
##   --file <path>          Encrypted backup file on this machine (required)
##   -n, --namespace <ns>   Target namespace (default: plextrac)
##   --components <list>    Comma/space list of couchbase,postgres,uploads,minio,license
##                          (default: all)
##   --legacy               Restore couchbase with the deprecated cbrestore tool
##                          (required only if the backup was taken with --legacy)
##   --dry-run              Show what would happen; make no cluster changes
##   -y, --yes              Skip the interactive confirmation prompt
##   -v, --verbose          Verbose output
##   -h, --help             Show this help and exit

set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
NAMESPACE="plextrac"
BACKUP_FILE=""
PASSPHRASE_FILE=""
COMPONENTS="couchbase postgres uploads minio license"
LEGACY=false
DRY_RUN=false
ASSUME_YES=false
VERBOSE=false

# Databases this migration restores. Deliberately excludes keycloak/synqly: those
# are re-provisioned in the target environment, not migrated (see the runbook).
PG_DATABASES="core runbooks ckeditor"

WORKDIR=""
PF_PID=""
PG_PORT_PATCHED=false

# ── Logging ──────────────────────────────────────────────────────────────────
log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
debug() { [[ "$VERBOSE" == true ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $*" >&2 || true; }
error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

usage() { grep '^##' "$0" | grep -v '#!/usr/bin/env' | sed 's/^## \{0,1\}//'; exit 0; }

# ── Cleanup (runs on every exit) ─────────────────────────────────────────────
cleanup() {
  local rc=$?
  if [[ -n "$PF_PID" ]] && kill -0 "$PF_PID" 2>/dev/null; then
    kill "$PF_PID" 2>/dev/null || true
  fi
  # If we interrupted postgres while it was isolated, put its port back so the
  # app can reach the database again.
  if [[ "$PG_PORT_PATCHED" == true ]]; then
    error "Restoring postgres containerPort to 5432 after an interrupted restore..."
    kubectl -n "$NAMESPACE" patch deployment postgres --type json \
      -p='[{"op":"replace","path":"/spec/template/spec/containers/0/ports/0/containerPort","value":5432}]' >/dev/null 2>&1 || true
    PG_PORT_PATCHED=false
  fi
  if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    find "$WORKDIR" -type f -exec shred -u {} + 2>/dev/null || true
    rm -rf "$WORKDIR" 2>/dev/null || true
  fi
  unset PT_RESTORE_PASS 2>/dev/null || true
  [[ $rc -ne 0 ]] && error "Script exited with status $rc"
  return $rc
}
trap cleanup EXIT

# ── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file)            BACKUP_FILE="$2"; shift 2 ;;
      -n|--namespace)    NAMESPACE="$2"; shift 2 ;;
      --components)      COMPONENTS="${2//,/ }"; shift 2 ;;
      --passphrase-file) PASSPHRASE_FILE="$2"; shift 2 ;;
      --legacy)          LEGACY=true; shift ;;
      --dry-run)         DRY_RUN=true; shift ;;
      -y|--yes)          ASSUME_YES=true; shift ;;
      -v|--verbose)      VERBOSE=true; shift ;;
      -h|--help)         usage ;;
      *) error "Unknown argument: $1"; usage ;;
    esac
  done
}

# ── Helpers ──────────────────────────────────────────────────────────────────
kc() { kubectl -n "$NAMESPACE" "$@"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { error "required command not found: $1"; exit 1; }; }

want() { case " $COMPONENTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Newest Ready pod name for an app label (empty + non-zero on failure).
find_pod() {
  local app="$1" timeout="${2:-120s}" pod
  pod=$(kc get pods -l "app=$app" --sort-by='.metadata.creationTimestamp' \
        -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)
  [[ -z "$pod" ]] && { error "no pod found for app=$app in namespace $NAMESPACE"; return 1; }
  kc wait --for=condition=Ready "pod/$pod" --timeout="$timeout" >/dev/null 2>&1 \
    || { error "pod $pod did not become Ready within $timeout"; return 1; }
  debug "app=$app -> pod $pod (namespace $NAMESPACE)"
  echo "$pod"
}

confirm() {
  [[ "$ASSUME_YES" == true ]] && return 0
  local answer
  read -r -p "$1 " answer
  [[ "$answer" == "$2" ]]
}

# openssl reads the passphrase from the environment, never from argv.
decrypt_stream() { openssl enc -d -aes-256-ctr -pbkdf2 -pass env:PT_RESTORE_PASS -in "$BACKUP_FILE"; }

# Newest *.tar.gz whose path contains the given keyword. Matches both the legacy
# per-component directory layout and the newer component-tagged filenames.
locate_latest() {
  find "$WORKDIR" -type f -name '*.tar.gz' -path "*$1*" 2>/dev/null | LC_ALL=C sort | tail -n1
}

# ── Passphrase acquisition ───────────────────────────────────────────────────
acquire_passphrase() {
  if [[ -n "$PASSPHRASE_FILE" ]]; then
    [[ -f "$PASSPHRASE_FILE" ]] || { error "passphrase file not found: $PASSPHRASE_FILE"; exit 1; }
    local perms
    perms=$(stat -f '%Lp' "$PASSPHRASE_FILE" 2>/dev/null || stat -c '%a' "$PASSPHRASE_FILE" 2>/dev/null || echo "")
    if [[ -n "$perms" && "$perms" != "600" && "$perms" != "400" ]]; then
      log "WARNING: $PASSPHRASE_FILE perms are $perms; tighten to 600 so the passphrase is not group/world-readable."
    fi
    PT_RESTORE_PASS="$(cat "$PASSPHRASE_FILE")"
  elif [[ -n "${PLEXTRAC_BACKUP_PASSPHRASE:-}" ]]; then
    PT_RESTORE_PASS="$PLEXTRAC_BACKUP_PASSPHRASE"
  else
    read -r -s -p "Backup decryption passphrase: " PT_RESTORE_PASS; echo
  fi
  [[ -n "${PT_RESTORE_PASS:-}" ]] || { error "no passphrase provided"; exit 1; }
  export PT_RESTORE_PASS
}

# ── Preflight ────────────────────────────────────────────────────────────────
preflight() {
  need_cmd kubectl; need_cmd openssl; need_cmd tar; need_cmd find
  [[ -n "$BACKUP_FILE" ]] || { error "--file is required"; usage; }
  [[ -f "$BACKUP_FILE" ]] || { error "backup file not found: $BACKUP_FILE"; exit 1; }

  local ctx; ctx=$(kubectl config current-context 2>/dev/null || echo "unknown")
  kubectl get ns "$NAMESPACE" >/dev/null 2>&1 \
    || { error "namespace $NAMESPACE not found (context: $ctx)"; exit 1; }

  log "Cluster context : $ctx"
  log "Namespace       : $NAMESPACE"
  log "Backup file     : $BACKUP_FILE ($(du -h "$BACKUP_FILE" | cut -f1))"
  log "Components      : $COMPONENTS"
  [[ "$DRY_RUN" == true ]] && log "Mode            : DRY-RUN (no cluster changes)"

  # The data stores for the requested components must exist and be Ready.
  want couchbase && { find_pod plextracdb   >/dev/null || exit 1; }
  want postgres  && { find_pod postgres     >/dev/null || exit 1; }
  want uploads   && { find_pod plextracapi  >/dev/null || exit 1; }
}

# ── Application-health gate ──────────────────────────────────────────────────
health_gate() {
  local ready total
  ready=$(kc get deploy plextracapi -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
  total=$(kc get deploy plextracapi -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)
  ready=${ready:-0}
  log "plextracapi readiness: ${ready}/${total} pods Ready (readiness probe = /api/v2/health/full)"
  if [[ "${ready:-0}" -lt 1 ]]; then
    log "WARNING: no plextracapi pods are Ready. The application does not appear healthy."
  else
    log "Application health check: PASS"
  fi
  [[ "$DRY_RUN" == true ]] && { log "DRY-RUN: skipping confirmation gate."; return; }
  if ! confirm "Proceed with a DESTRUCTIVE restore into '$NAMESPACE' on context '$(kubectl config current-context)'? Type the namespace to continue:" "$NAMESPACE"; then
    log "Aborted at confirmation gate."
    exit 0
  fi
}

# ── Decrypt + extract ────────────────────────────────────────────────────────
verify_decrypt() {
  log "Verifying passphrase and archive integrity..."
  if ! decrypt_stream | tar -tz >/dev/null 2>&1; then
    error "could not decrypt/verify the backup. Wrong passphrase or corrupt file."
    exit 1
  fi
  log "Decryption verified."
}

extract_backup() {
  WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/plextrac-restore.XXXXXX")
  chmod 700 "$WORKDIR"
  log "Extracting backup to $WORKDIR ..."
  decrypt_stream | tar -xz -C "$WORKDIR"
}

# ── Couchbase ────────────────────────────────────────────────────────────────
restore_couchbase() {
  local tarball pod
  tarball=$(locate_latest couchbase)
  [[ -z "$tarball" ]] && { log "No couchbase archive in backup; skipping."; return; }
  log "[couchbase] restoring from $(basename "$tarball")"
  if [[ "$DRY_RUN" == true ]]; then log "DRY-RUN: would flush bucket reportMe and restore into plextracdb-0"; return; fi

  pod=$(find_pod plextracdb) || exit 1
  kc exec "$pod" -c plextracdb -- /bin/bash -c 'mkdir -p /backups'
  kc cp "$tarball" "$pod:/backups/couchbase_backup.tar.gz" -c plextracdb

  # Flush the bucket first so the restore is a clean replace, not a merge.
  # shellcheck disable=SC2016
  kc exec "$pod" -c plextracdb -- /bin/bash -c \
    'set -e
     couchbase-cli bucket-edit --enable-flush 1 -c http://127.0.0.1:8091 -u $CB_ADMIN_USER -p "$CB_ADMIN_PASS" --bucket reportMe >/dev/null
     couchbase-cli bucket-flush -c http://127.0.0.1:8091 -u $CB_ADMIN_USER -p "$CB_ADMIN_PASS" --bucket reportMe <<< y >/dev/null
     couchbase-cli bucket-edit --enable-flush 0 -c http://127.0.0.1:8091 -u $CB_ADMIN_USER -p "$CB_ADMIN_PASS" --bucket reportMe >/dev/null'

  if [[ "$LEGACY" == true ]]; then
    # shellcheck disable=SC2016
    kc exec "$pod" -c plextracdb -- /bin/bash -c \
      'tar -C /backups/ -xzf /backups/couchbase_backup.tar.gz
       cbrestore /backups/ http://127.0.0.1:8091 -u $CB_ADMIN_USER -p "$CB_ADMIN_PASS" --from-date 2022-01-01 -x conflict_resolve=0,data_only=1'
  else
    # cbbackupmgr: the archive directory is the top-level entry in the tarball.
    local archive out
    archive=$(kc exec "$pod" -c plextracdb -- /bin/bash -c 'tar -tzf /backups/couchbase_backup.tar.gz | head -n1 | cut -d/ -f1')
    [[ -z "$archive" ]] && { error "could not determine cbbackupmgr archive dir; if this backup used --legacy, re-run with --legacy"; exit 1; }
    debug "cbbackupmgr archive dir: $archive"
    kc exec "$pod" -c plextracdb -- /bin/bash -c "tar -C /backups/ -xzf /backups/couchbase_backup.tar.gz"
    # shellcheck disable=SC2016
    out=$(kc exec "$pod" -c plextracdb -- /bin/bash -c \
      "cbbackupmgr restore -a /backups/$archive -r plextrac -c http://127.0.0.1:8091 -u \$CB_ADMIN_USER -p \$CB_ADMIN_PASS --force-updates --no-progress-bar 2>&1") || {
        error "cbbackupmgr restore failed:"; echo "$out" >&2; exit 1; }
    echo "$out" | grep -q "Restore completed successfully" || { error "cbbackupmgr did not report success:"; echo "$out" >&2; exit 1; }
  fi

  kc exec "$pod" -c plextracdb -- /bin/bash -c 'rm -rf /backups/*' || true
  log "[couchbase] done."
}

# ── Postgres ─────────────────────────────────────────────────────────────────
restore_postgres() {
  local tarball pod
  tarball=$(locate_latest postgres)
  [[ -z "$tarball" ]] && { log "No postgres archive in backup; skipping."; return; }
  log "[postgres] restoring databases: $PG_DATABASES"
  if [[ "$DRY_RUN" == true ]]; then log "DRY-RUN: would drop+recreate $PG_DATABASES and pg_restore into the postgres deployment"; return; fi

  # Block application writes during the restore by pointing the Service's named
  # target port (pg-port) at a port postgres is not listening on. The Deployment
  # uses the Recreate strategy, so this rolls the pod. Restored to 5432 at the end
  # (and by cleanup() if we are interrupted).
  log "[postgres] isolating postgres (containerPort -> 5444) to block writes..."
  kc patch deployment postgres --type json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/ports/0/containerPort","value":5444}]' >/dev/null
  PG_PORT_PATCHED=true
  sleep 5
  pod=$(find_pod postgres) || exit 1
  debug "postgres isolated on containerPort 5444; restoring via pod $pod"

  log "[postgres] dropping $PG_DATABASES and re-running initdb..."
  # shellcheck disable=SC2016
  kc exec -i "$pod" -c postgres -- /bin/bash <<'EOF'
set -e
export PGPASSWORD="$POSTGRES_PASSWORD"
mkdir -p /backups
for db in core runbooks ckeditor; do
  psql -U "$POSTGRES_USER" -c "DROP DATABASE IF EXISTS $db;"
done
bash /docker-entrypoint-initdb.d/initdb.sh
EOF

  kc cp "$tarball" "$pod:/backups/postgres_backup.tar.gz" -c postgres
  kc exec "$pod" -c postgres -- /bin/bash -c 'tar -C /backups/ -xzf /backups/postgres_backup.tar.gz'

  # Restore each allowlisted database. The dump nests files under a timestamp dir,
  # so resolve the real path with find instead of assuming /backups/<db>.psql.
  # shellcheck disable=SC2016
  kc exec -i "$pod" -c postgres -- /bin/bash <<'EOF'
set -e
export PGPASSWORD="$POSTGRES_PASSWORD"
for db in core runbooks ckeditor; do
  dump=$(find /backups -type f -name "${db}.psql" | head -n1)
  if [ -z "$dump" ]; then echo "  (no dump for $db, skipping)"; continue; fi
  echo "Restoring $db from $dump"
  if [ "$db" = "core" ]; then
    psql -U "$POSTGRES_USER" -d "$PG_CORE_DB" -c "ALTER ROLE $PG_CORE_ADMIN_USER WITH SUPERUSER;"
    psql -U "$POSTGRES_USER" -d "$PG_CORE_DB" -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
    psql -U "$POSTGRES_USER" -d "$PG_CORE_DB" -c "SELECT timescaledb_pre_restore();"
  fi
  admin_var="PG_${db^^}_ADMIN_USER"
  admin_role=$(eval echo "\$$admin_var")
  pg_restore -U "$POSTGRES_USER" -d "$db" --no-privileges --no-owner --role="$admin_role" --disable-triggers --verbose "$dump"
  if [ "$db" = "core" ]; then
    psql -U "$POSTGRES_USER" -d "$PG_CORE_DB" -c "SELECT timescaledb_post_restore();"
    psql -U "$POSTGRES_USER" -d "$PG_CORE_DB" -c "ALTER ROLE $PG_CORE_ADMIN_USER WITH NOSUPERUSER;"
  fi
done
EOF

  kc exec "$pod" -c postgres -- /bin/bash -c 'rm -rf /backups/*' || true

  log "[postgres] restoring containerPort -> 5432..."
  kc patch deployment postgres --type json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/ports/0/containerPort","value":5432}]' >/dev/null
  PG_PORT_PATCHED=false
  log "[postgres] done."
}

# ── Uploads (plextracapi filesystem PVC) ─────────────────────────────────────
restore_uploads() {
  local tarball pod
  tarball=$(locate_latest uploads)
  [[ -z "$tarball" ]] && { log "No uploads archive in backup; skipping."; return; }
  log "[uploads] restoring into plextracapi:/usr/src/plextrac-api/uploads"
  if [[ "$DRY_RUN" == true ]]; then log "DRY-RUN: would extract uploads into the plextracapi PVC"; return; fi

  pod=$(find_pod plextracapi) || exit 1
  kc cp "$tarball" "$pod:/tmp/uploads_backup.tar.gz" -c plextracapi
  kc exec -i "$pod" -c plextracapi -- /bin/sh -c \
    'cd /usr/src/plextrac-api/uploads && tar --strip-components=1 -xzf /tmp/uploads_backup.tar.gz && rm -f /tmp/uploads_backup.tar.gz'
  log "[uploads] done."
}

# ── MinIO object storage (bucket "cloud") ────────────────────────────────────
# The current pt-ansible backup does NOT yet capture MinIO. This restores the
# bucket when the backup contains it (a "*minio*.tar.gz" holding a cloud/ tree),
# using the operator's local `mc` over a port-forward. Otherwise it warns loudly.
restore_minio() {
  local tarball
  tarball=$(locate_latest minio)
  if [[ -z "$tarball" ]]; then
    log "WARNING: no MinIO objects in this backup. Asset-import files under cloud/uploads will NOT be restored."
    log "         (The backup tooling does not yet capture MinIO; see the runbook.)"
    return
  fi
  if ! command -v mc >/dev/null 2>&1; then
    log "WARNING: MinIO objects present in backup but 'mc' (MinIO client) is not installed locally; skipping."
    return
  fi
  log "[minio] restoring bucket 'cloud' from $(basename "$tarball")"
  if [[ "$DRY_RUN" == true ]]; then log "DRY-RUN: would mc mirror the cloud bucket into the minio service"; return; fi

  local dir src user pass
  dir="$WORKDIR/minio-extract"; mkdir -p "$dir"
  tar -xzf "$tarball" -C "$dir"
  src=$(find "$dir" -type d -name cloud | head -n1)
  [[ -z "$src" ]] && { error "MinIO archive did not contain a 'cloud' bucket tree"; exit 1; }

  user=$(kc get secret application-secrets -o jsonpath='{.data.MINIO_ROOT_USER}' | base64 --decode)
  pass=$(kc get secret application-secrets -o jsonpath='{.data.MINIO_ROOT_PASSWORD}' | base64 --decode)

  kc port-forward svc/minio 19000:9000 >/dev/null 2>&1 &
  PF_PID=$!
  sleep 3
  MC_HOST_ptrestore="http://${user}:${pass}@127.0.0.1:19000" \
    mc mirror --overwrite "$src" "ptrestore/cloud"
  kill "$PF_PID" 2>/dev/null || true; PF_PID=""
  log "[minio] done."
}

# ── License cache (redis) ────────────────────────────────────────────────────
delete_license_cache() {
  log "[license] clearing cached license so the restored license is re-read"
  if [[ "$DRY_RUN" == true ]]; then log "DRY-RUN: would delete the license cache key in redis"; return; fi
  local pass
  pass=$(kc get secret application-secrets -o jsonpath='{.data.REDIS_PASSWORD}' | base64 --decode)
  local key='{"cacheDomain":"License","method":"getTenantLicense","params":0,"tenantId":0}'
  kc exec -i redis-0 -c redis -- redis-cli --no-auth-warning -a "$pass" DEL "$key" >/dev/null 2>&1 || true
  log "[license] done."
}

# ── Validation ───────────────────────────────────────────────────────────────
validate() {
  [[ "$DRY_RUN" == true ]] && return
  log "── Post-restore validation ──"
  if want couchbase; then
    local pod cnt
    pod=$(find_pod plextracdb 2>/dev/null) || true
    if [[ -n "$pod" ]]; then
      # shellcheck disable=SC2016
      cnt=$(kc exec "$pod" -c plextracdb -- /bin/bash -c \
        'curl -s -u $CB_ADMIN_USER:$CB_ADMIN_PASS http://127.0.0.1:8091/pools/default/buckets/reportMe 2>/dev/null | grep -o "\"itemCount\":[0-9]*" | head -n1' 2>/dev/null || true)
      log "couchbase reportMe ${cnt:-(count unavailable)}"
    fi
  fi
  if want postgres; then
    local pod
    pod=$(find_pod postgres 2>/dev/null) || true
    # shellcheck disable=SC2016
    [[ -n "$pod" ]] && kc exec -i "$pod" -c postgres -- /bin/bash -c \
      'export PGPASSWORD=$POSTGRES_PASSWORD; for db in core runbooks ckeditor; do
         n=$(psql -tA -U $POSTGRES_USER -d $db -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='"'"'public'"'"';" 2>/dev/null);
         echo "  postgres/$db: ${n:-?} public tables"; done' 2>/dev/null || true
  fi
  log "Restore complete. Recommended manual checks:"
  log "  - Log into the app and confirm reports, findings, and images load."
  log "  - Confirm users can authenticate, including MFA (its secret travels in the couchbase dump)."
  log "  - If plextracapi was degraded during the restore: kubectl -n $NAMESPACE rollout restart deploy/plextracapi"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  preflight
  acquire_passphrase
  verify_decrypt
  health_gate
  extract_backup

  log "Starting restore..."
  want couchbase && restore_couchbase
  want postgres  && restore_postgres
  want uploads   && restore_uploads
  want minio     && restore_minio
  want license   && delete_license_cache
  validate
  log "Done."
}

main "$@"
