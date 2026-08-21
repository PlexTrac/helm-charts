#!/usr/bin/env bash
## Script: k3s_restore.sh
## Version: 02-02-2026
## Description:
##   Restore a k3s cluster from a tarball compatible with docker compose
##   backup process. This script expects tar.gz files to exist in
##   /opt/plextrac/backups/{couchbase,postgres,uploads}/. It will restore the
##   latest file found for each type of restore.
## ---
## Usage: ./k3s_restore.sh [options]

## Options:
## --- Select restore procedure
##   -c, --couchbase     Only restore couchbase
##   -l, --license       Only delete license key cache
##   -p, --postgres      Only restore postgres
##   -u, --uploads       Only restore uploads
## ---
##   --legacy            Use the deprecated cbrestore tool for couchbase instead
##                       of cbbackupmgr (break-glass fallback; also required if
##                       the latest couchbase backup was taken with --legacy)
##   -n, --dry-run       Show what would be backed up
##   -v, --verbose       Enable verbose output
##   -h, --help          Display this help message and exit

set -eo pipefail

# Default configuration
VERBOSE=false
DRY_RUN=false
COUCHBASE_ONLY=false
LICENSE_ONLY=false
POSTGRES_ONLY=false
UPLOADS_ONLY=false
LEGACY=false

# Logging functions
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

debug() {
  if [[ "${VERBOSE}" == true ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $*"
  fi
}

error() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

usage() {
  grep '^##' "$0" | grep -v '#!/usr/bin/env' | sed 's/^## //'
  exit 0
}

# Parse command line arguments
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--couchbase)
        COUCHBASE_ONLY=true
        shift
        ;;
      -l|--license)
        LICENSE_ONLY=true
        shift
        ;;
      -p|--postgres)
        POSTGRES_ONLY=true
        shift
        ;;
      -u|--uploads)
        UPLOADS_ONLY=true
        shift
        ;;
      --legacy)
        LEGACY=true
        shift
        ;;
      -n|--dry-run)
        DRY_RUN=true
        shift
        ;;
      -v|--verbose)
        VERBOSE=true
        shift
        ;;
      -h|--help)
        usage
        ;;
      *)
        error "Unknown option: $1"
        usage
        ;;
    esac
  done
}

find_container() {
  local APP="$1"
  local NAMESPACE="$2"
  local TIMEOUT="${3:-120s}"
  local TIMEOUT_SECONDS="${TIMEOUT%s}"
  local POD_NAME=""
  local elapsed=0
  local interval=3

  while (( elapsed < TIMEOUT_SECONDS )); do
    POD_NAME=$(kubectl -n "$NAMESPACE" get pods -l app="$APP" \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}' \
      2>/dev/null | awk '$2=="Running" && $3=="true" {print $1; exit}')
    if [[ -n "$POD_NAME" ]]; then
      echo "$POD_NAME"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  error "Failed to find pod for app:$APP, namespace:$NAMESPACE in ${TIMEOUT}"
  exit 1
}

restore_couchbase() {
  local couchbase_pod_name
  local latestBackup

  log "******************"
  log "[BEGIN] Restoring couchbase"
  log "******************"

  couchbase_pod_name=$(find_container "plextracdb" "plextrac")
  # find latest tar.gz file in /opt/plextrac/backups/couchbase
  latestBackup="$(find /opt/plextrac/backups/couchbase -maxdepth 1 -name '*.tar.gz' -type f  -print0 | xargs -0 stat -c"%Y %y %n" | sort -rn | head -n 1 | awk '{print $5}')"
  debug "Latest backup: $latestBackup"

  if [[ "${DRY_RUN}" == true ]]; then
    log "DRY-RUN: Would copy $latestBackup to $couchbase_pod_name:/backups/couchbase_backup.tar.gz"
    return
  fi

  debug "Copying $latestBackup to $couchbase_pod_name:/backups/couchbase_backup.tar.gz..."
  if kubectl -n plextrac cp "$latestBackup" "$couchbase_pod_name":/backups/couchbase_backup.tar.gz -c plextracdb; then
    debug "Copied $latestBackup to $couchbase_pod_name:/backups/couchbase_backup.tar.gz"
  else
    error "Failed to copy $latestBackup to $couchbase_pod_name:/backups/couchbase_backup.tar.gz"
    exit 1
  fi

  if [[ "${LEGACY}" == true ]]; then
    restore_couchbase_legacy "$couchbase_pod_name"
  else
    restore_couchbase_cbbackupmgr "$couchbase_pod_name"
  fi
}

# Legacy path using the deprecated cbrestore tool. Only usable if the backup
# being restored was also taken with --legacy (cbrestore-format archive).
restore_couchbase_legacy() {
  local couchbase_pod_name="$1"

  debug "Extracting /backups/couchbase_backup.tar.gz..."
  if kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c 'tar -C /backups/ -xzvf /backups/couchbase_backup.tar.gz'; then
    debug "Extracted /backups/couchbase_backup.tar.gz"
  else
    error "Failed to extract /backups/couchbase_backup.tar.gz"
    exit 1
  fi

  debug "Running cbrestore..."
  # Single quotes work here
  # shellcheck disable=SC2016
  debug "Beginning bucket flush"
  kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c 'couchbase-cli bucket-edit --enable-flush 1 -c http://127.0.0.1:8091 -u $CB_ADMIN_USER -p "$CB_ADMIN_PASS" --bucket reportMe'

  kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c 'couchbase-cli bucket-flush -c http://127.0.0.1:8091 -u $CB_ADMIN_USER -p "$CB_ADMIN_PASS" --bucket reportMe --force' || true

  itemCount="unknown"
  for i in $(seq 1 40); do
    itemCount=$(kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/sh -c 'cbstats 127.0.0.1:11210 all -u "$CB_ADMIN_USER" -p "$CB_ADMIN_PASS" -b reportMe 2>/dev/null | awk "/curr_items:/{print \$2}"')
    debug "Post-flush curr_items: ${itemCount:-unknown} (check $i/40)"
    [[ "$itemCount" == "0" ]] && break
    sleep 3
  done

  if [[ "$itemCount" != "0" ]]; then
    debug "WARNING: bucket did not reach 0 items after flush (last seen: $itemCount). Proceeding anyway; cbrestore below will overwrite matching keys."
  fi

  kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c 'couchbase-cli bucket-edit --enable-flush 0 -c http://127.0.0.1:8091 -u $CB_ADMIN_USER -p "$CB_ADMIN_PASS" --bucket reportMe'
  debug "Flush complete"

  if kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c 'cbrestore /backups/ http://127.0.0.1:8091 -u $CB_ADMIN_USER -p "$CB_ADMIN_PASS" --from-date 2022-01-01 -x conflict_resolve=0,data_only=1'; then
    debug "Completed running cbrestore"
  else
    error "Failed to run cbrestore"
    exit 1
  fi

  debug "Removing /backups/* in $couchbase_pod_name..."
  if kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c 'rm -rf /backups/*'; then
    debug "Removed /backups/* in $couchbase_pod_name"
  else
    error "Failed to remove /backups/* in $couchbase_pod_name"
    exit 1
  fi

  log "******************"
  log "[DONE] Restoring couchbase"
  log "******************"
}

# Default path using cbbackupmgr. Only usable if the backup being restored
# was also taken with cbbackupmgr (the default, non --legacy, backup path).
restore_couchbase_cbbackupmgr() {
  local couchbase_pod_name="$1"
  local repoName="plextrac"
  local archivePath

  debug "Determining archive directory name from tarball contents..."
  archivePath="/backups/$(kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c 'tar -tzf /backups/couchbase_backup.tar.gz | head -n1 | cut -d/ -f1')"
  if [[ -z "$archivePath" || "$archivePath" == "/backups/" ]]; then
    error "Could not determine cbbackupmgr archive directory from /backups/couchbase_backup.tar.gz. If this backup was taken with --legacy, re-run this restore with --legacy too."
    exit 1
  fi
  debug "Archive path: $archivePath"

  debug "Extracting /backups/couchbase_backup.tar.gz..."
  if kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c 'tar -C /backups/ -xzvf /backups/couchbase_backup.tar.gz'; then
    debug "Extracted /backups/couchbase_backup.tar.gz"
  else
    error "Failed to extract /backups/couchbase_backup.tar.gz"
    exit 1
  fi

  debug "Beginning bucket flush"
  kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c 'couchbase-cli bucket-edit --enable-flush 1 -c http://127.0.0.1:8091 -u $CB_ADMIN_USER -p "$CB_ADMIN_PASS" --bucket reportMe'

  kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c 'couchbase-cli bucket-flush -c http://127.0.0.1:8091 -u $CB_ADMIN_USER -p "$CB_ADMIN_PASS" --bucket reportMe --force' || true

  itemCount="unknown"
  for i in $(seq 1 40); do
    itemCount=$(kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/sh -c 'cbstats 127.0.0.1:11210 all -u "$CB_ADMIN_USER" -p "$CB_ADMIN_PASS" -b reportMe 2>/dev/null | awk "/curr_items:/{print \$2}"')
    debug "Post-flush curr_items: ${itemCount:-unknown} (check $i/40)"
    [[ "$itemCount" == "0" ]] && break
    sleep 3
  done

  if [[ "$itemCount" != "0" ]]; then
    debug "WARNING: bucket did not reach 0 items after flush (last seen: $itemCount). Proceeding anyway since restore runs with --force-updates; any leftover documents not present in the backup archive will remain post-restore."
  fi

  kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c 'couchbase-cli bucket-edit --enable-flush 0 -c http://127.0.0.1:8091 -u $CB_ADMIN_USER -p "$CB_ADMIN_PASS" --bucket reportMe'
  debug "Flush step complete"

  debug "Running cbbackupmgr restore..."
  local cbbackupmgrOutput
  local cbbackupmgrExit=0
  # shellcheck disable=SC2016
  cbbackupmgrOutput=$(kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c "cbbackupmgr restore -a $archivePath -r $repoName -c http://127.0.0.1:8091 -u \$CB_ADMIN_USER -p \$CB_ADMIN_PASS --force-updates --no-progress-bar 2>&1") || cbbackupmgrExit=$?
  debug "$cbbackupmgrOutput"

  if [[ $cbbackupmgrExit -ne 0 ]]; then
    error "cbbackupmgr restore exited with status $cbbackupmgrExit"
    echo "$cbbackupmgrOutput"
    exit 1
  fi

  if ! echo "$cbbackupmgrOutput" | grep -q "Restore completed successfully"; then
    error "cbbackupmgr restore did not report successful completion"
    echo "$cbbackupmgrOutput"
    exit 1
  fi

  if echo "$cbbackupmgrOutput" | grep -qi "Failed"; then
    error "cbbackupmgr restore reported a failure"
    echo "$cbbackupmgrOutput"
    exit 1
  fi

  log "Couchbase restore completed via cbbackupmgr"

  debug "Removing /backups/* in $couchbase_pod_name..."
  if kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c 'rm -rf /backups/*'; then
    debug "Removed /backups/* in $couchbase_pod_name"
  else
    error "Failed to remove /backups/* in $couchbase_pod_name"
    exit 1
  fi

  log "******************"
  log "[DONE] Restoring couchbase"
  log "******************"
}

restore_postgres() {
  local postgres_pod_name
  local latestBackup

  log "******************"
  log "[BEGIN] Restoring postgres"
  log "******************"

  postgres_pod_name=$(find_container "postgres" "plextrac" "300s")
  # find latest file in /opt/plextrac/backups/postgres
  latestBackup="$(find /opt/plextrac/backups/postgres -maxdepth 1 -name '*.tar.gz' -type f  -print0 | xargs -0 stat -c"%Y %y %n" | sort -rn | head -n 1 | awk '{print $5}')"

  if [[ "${DRY_RUN}" == true ]]; then
    log "DRY-RUN: Would copy $latestBackup to $postgres_pod_name:/backups/postgres_backup.tar.gz"
    return
  else
    # Change the postgres port to something unused to avoid any writes while we do the restore
    debug "Patching postgres deployment containerPort to 5444..."
    # Single quotes work here
    # shellcheck disable=SC2026
    if kubectl -n plextrac patch deployment postgres --type json -p='[{"op": "replace", 'path': '/spec/template/spec/containers/0/ports/0/containerPort', "value":5444}]'; then
      debug "Patched postgres deployment containerPort to 5444"
    else
      error "Failed to patch postgres deployment"
      exit 1
    fi

    # The postgres container name probably changed after doing this, so lets get the new name
    # Sleep for a bit to make sure the container is up
    sleep 5
    postgres_pod_name=$(find_container "postgres" "plextrac" "300s")

    debug "Waiting for postgres to actually accept connections..."
    for i in $(seq 1 30); do
      kubectl -n plextrac exec "$postgres_pod_name" -- pg_isready -q && break
      sleep 2
    done

    # Drop the databases, then run the initdb script again to recreate them
    debug "Dropping databases and running initdb..."
    kubectl -n plextrac exec -i --tty=false "$postgres_pod_name" -- /bin/bash << 'EOF'
mkdir -p /backups
export PGPASSWORD=$POSTGRES_PASSWORD
psql -U $POSTGRES_USER -c "DROP DATABASE core;"
psql -U $POSTGRES_USER -c "DROP DATABASE runbooks;"
psql -U $POSTGRES_USER -c "DROP DATABASE ckeditor;"
./docker-entrypoint-initdb.d/initdb.sh
EOF

    # Copy the backup files and begin the restore
    debug "Copying $latestBackup to $postgres_pod_name:postgres_backup.tar.gz..."
    if kubectl -n plextrac cp "$latestBackup" "$postgres_pod_name":/backups/postgres_backup.tar.gz; then
      debug "Copied $latestBackup to $postgres_pod_name:/backups/postgres_backup.tar.gz"
    else
      error "Failed to copy $latestBackup to $postgres_pod_name:/backups/postgres_backup.tar.gz"
      exit 1
    fi

    debug "Extracting postgres_backup.tar.gz..."
    if kubectl -n plextrac exec -i --tty=false "$postgres_pod_name" -- /bin/bash << 'EOF'; then debug "Extracted postgres_backup.tar.gz"; fi
databaseBackups=$(basename -s .psql $(tar -tf /backups/postgres_backup.tar.gz | awk '/.psql/{print $1}'))
tar -C /backups/ -tf /backups/postgres_backup.tar.gz
tar -C /backups/ -xvzf /backups/postgres_backup.tar.gz
EOF

    debug "Performing pg_restore operations..."
    if kubectl -n plextrac exec -i --tty=false "$postgres_pod_name" -- /bin/bash << 'EOF'; then debug "Completed pg_restore operations"; fi
databaseBackups=$(basename -s .psql $(tar -tf /backups/postgres_backup.tar.gz | awk '/.psql/{print $1}'))

echo "Running pg_restore..."
export PGPASSWORD=$POSTGRES_PASSWORD
for db in $databaseBackups; do
  if [ $db = "core" ]; then
    echo "Temporarily grant superuser priveleges to the core_admin user"
    psql -U $POSTGRES_USER -d $PG_CORE_DB -c "ALTER ROLE $PG_CORE_ADMIN_USER WITH SUPERUSER;"

    echo "Create the timescaledb extension for the core database"
    psql -U $POSTGRES_USER -d $PG_CORE_DB -c "CREATE EXTENSION timescaledb;"

    echo "Run the timescaledb pre_restore command"
    psql -U $POSTGRES_USER -d $PG_CORE_DB -c "SELECT timescaledb_pre_restore();"
  fi

  dbAdminEnvvar="PG_${db^^}_ADMIN_USER"
  dbAdminRole=$(eval echo "\$$dbAdminEnvvar")
  dbRestoreFlags="-d $db --no-privileges --no-owner --role=$dbAdminRole  --disable-triggers --verbose"
  echo "Running pg_restore for /backups/$db.psql..."
  pg_restore -U $POSTGRES_USER $dbRestoreFlags /backups/$db.psql

  if [ $db = "core" ]; then
    echo "Run the timescaledb post_restore command"
    psql -U $POSTGRES_USER -d $PG_CORE_DB -c "SELECT timescaledb_post_restore();"

    echo "Revoke the temporarily granted superuser privileges from core_admin"
    psql -U $POSTGRES_USER -d $PG_CORE_DB -c "ALTER ROLE $PG_CORE_ADMIN_USER WITH NOSUPERUSER;"
  fi
done
EOF

    # debug "Removing postgres_backup.tar.gz in $postgres_pod_name..."
    if kubectl -n plextrac exec "$postgres_pod_name" -- /bin/bash -c 'rm /backups/postgres_backup.tar.gz'; then
      debug "Removed /backups/postgres_backup.tar.gz in $postgres_pod_name"
    else
      error "Failed to remove /backups/postgres_backup.tar.gz in $postgres_pod_name"
      exit 1
    fi

    # Set the postgres port back to the valid value
    debug "Patching postgres deployment containerPort to original 5432 value..."
    # Single quotes work here
    # shellcheck disable=SC2026
    if kubectl -n plextrac patch deployment postgres --type json -p='[{"op": "replace", 'path': '/spec/template/spec/containers/0/ports/0/containerPort', "value":5432}]'; then
      debug "Patched postgres deployment containerPort to 5432"
    else
      error "Failed to patch postgres deployment to original containerPort"
      exit 1
    fi

    log "******************"
    log "[DONE] Restoring postgres"
    log "******************"
  fi
}

restore_uploads() {
  local plextracapi_pod_name
  local latestBackup

  log "******************"
  log "[BEGIN] Restoring uploads"
  log "******************"

  plextracapi_pod_name=$(find_container "plextracapi" "plextrac")
  # find latest file in /opt/plextrac/backups/uploads
  latestBackup="$(find /opt/plextrac/backups/uploads -maxdepth 1 -name '*.tar.gz' -type f  -print0 | xargs -0 stat -c"%Y %y %n" | sort -rn | head -n 1 | awk '{print $5}')"
  debug "Latest uploads backup: $latestBackup"

  if [[ "${DRY_RUN}" == true ]]; then
    log "DRY-RUN: Would copy $latestBackup to $plextracapi_pod_name:/usr/src/plextrac-api"
    return
  else
    # Copying the backup file into the pod first, to avoid timeouts with large uploads directories
    debug "Copying $latestBackup $plextracapi_pod_name:/tmp/uploads_backup.tar.gz..."
    if kubectl -n plextrac cp "$latestBackup" "$plextracapi_pod_name":/tmp/uploads_backup.tar.gz; then
      debug "Copied $latestBackup $plextracapi_pod_name:/tmp/uploads_backup.tar.gz"
    else
      error "Failed to copy $latestBackup $plextracapi_pod_name:/tmp/uploads_backup.tar.gz"
      exit 1
    fi

    debug "Extracting /tmp/uploads_backup.tar.gz..."
    if kubectl -n plextrac exec -i "$plextracapi_pod_name" -- /bin/sh -c 'cd /usr/src/plextrac-api/uploads && tar --strip-components=1 -xzf /tmp/uploads_backup.tar.gz'; then
      debug "Completed extracting /tmp/uploads_backup.tar.gz"
    else
      error "Failed to extract /tmp/uploads_backup.tar.gz"
      exit 1
    fi

    debug "Removing /tmp/uploads_backup.tar.gz in $plextracapi_pod_name"
    if kubectl -n plextrac exec -i "$plextracapi_pod_name" -- /bin/sh -c 'cd /usr/src/plextrac-api && rm /tmp/uploads_backup.tar.gz'; then
      debug "Removed /tmp/uploads_backup.tar.gz in $plextracapi_pod_name"
    else
      error "Failed to remove /tmp/uploads_backup.tar.gz in $plextracapi_pod_name"
      exit 1
    fi

    log "******************"
    log "[DONE] Restoring uploads"
    log "******************"
  fi
}

delete_license_cache() {
  debug "Deleting license key cache..."
  # Get redis password from secrets first
  local redis_password
  redis_password=$(kubectl get secret application-secrets -n plextrac -o json | jq -r '.data.REDIS_PASSWORD' | base64 --decode)

  local cache_key_plain='{"cacheDomain":"License","method":"getTenantLicense","params":0,"tenantId":0}'
  local cache_key_single_quoted="'{\"cacheDomain\":\"License\",\"method\":\"getTenantLicense\",\"params\":0,\"tenantId\":0}'"

  for cache_key in "$cache_key_plain" "$cache_key_single_quoted"; do
    if kubectl -n plextrac exec -i --tty=false "redis-0" -c redis -- redis-cli --no-auth-warning -a "${redis_password}" EXISTS "$cache_key" | grep -q '^1$'; then
      if kubectl -n plextrac exec -i --tty=false "redis-0" -c redis -- redis-cli --no-auth-warning -a "${redis_password}" DEL "$cache_key" >/dev/null; then
        debug "Deleted license key cache: $cache_key"
      else
        error "Failed to delete license key cache: $cache_key"
      fi
    else
      debug "License key cache not found: $cache_key"
    fi
  done
}

# Main function
main() {
  parse_args "$@"

  log "******************"
  log "[BEGIN] Starting restore"
  log "******************"

  if [[ "${DRY_RUN}" == true ]]; then
    log "Running in DRY-RUN mode - no changes will be made"
  fi

  if [[ "${COUCHBASE_ONLY}" == true ]]; then
    log "Running only couchbase restore..."
    restore_couchbase
  elif [[ "${POSTGRES_ONLY}" == true ]]; then
    log "Running only postgres restore..."
    restore_postgres
  elif [[ "${UPLOADS_ONLY}" == true ]]; then
    log "Running only uploads restore..."
    restore_uploads
  elif [[ "${LICENSE_ONLY}" == true ]]; then
    log "Running only license cache delete..."
    delete_license_cache
  else
    log "Restoring couchbase, postgres, and uploads and deleting license cache..."
    restore_couchbase
    restore_postgres
    restore_uploads
    delete_license_cache
  fi

  if [[ "${DRY_RUN}" == true ]]; then
    log "Dry run completed - no changes were made"
  else
    log "******************"
    log "[DONE] Restore completed successfully"
    log "******************"
  fi
}

# Handle script errors
cleanup() {
  if [[ $? -ne 0 ]]; then
    error "Script failed with error"
  fi
}

trap cleanup EXIT

# Run main function
main "$@"
