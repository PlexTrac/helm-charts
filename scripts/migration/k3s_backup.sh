#!/usr/bin/env bash
## Script: k3s_backup.sh
## Version: 2026-07-06
## Description:  Backup a k3s cluster to a tarball compatible with docker compose backup process.
## Usage: ./k3s_backup.sh [options]

## Options:
## --- Select backup procedure
##   -c, --couchbase     Only backup couchbase
##   -p, --postgres      Only backup postgres
##   -u, --uploads       Only backup uploads
## ---
##   --legacy            Use the deprecated cbbackup tool for couchbase instead
##                       of cbbackupmgr (break-glass fallback)
##   -n, --dry-run       Show what would be backed up
##   -v, --verbose       Enable verbose output
##   -h, --help          Display this help message and exit

set -eo pipefail

# Default configuration
VERBOSE=false
DRY_RUN=false
COUCHBASE_ONLY=false
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
  local POD_NAME

  # 1. Get the name of the ABSOLUTE NEWEST pod matching the label
  POD_NAME=$(kubectl get pods -n "$NAMESPACE" -l app="$APP" \
    --sort-by='.metadata.creationTimestamp' \
    -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null)

  if [ -z "$POD_NAME" ]; then
    echo "Error: No pods found matching selector app=$APP" >&2
    exit 1
  fi

  # 2. Wait specifically for THAT exact pod to become ready
  if kubectl wait --for=condition=Ready pod/"$POD_NAME" \
    --namespace "$NAMESPACE" \
    --timeout="$TIMEOUT" > /dev/null 2>&1; then
    
    echo "$POD_NAME"
    return 0
  else
    echo "Error: Pod $POD_NAME failed to become ready within $TIMEOUT" >&2
    exit 1
  fi
}

get_plextrac_version() {
  local PLEXTRAC_VERSION
  local PLEXTRAC_CONTAINER

  PLEXTRAC_CONTAINER=$(find_container "plextracapi" "plextrac")
  if PLEXTRAC_VERSION=$(kubectl -n plextrac get po $PLEXTRAC_CONTAINER -o 'jsonpath={.spec.containers[?(@.name=="plextracapi")].image}' | awk -Fbackend: '{ print $2 }'); then
    echo "$PLEXTRAC_VERSION"
    return 0
  else
    error "Failed to get version of plextracapi deployment"
    exit 1
  fi
}

backup_couchbase() {
  local couchbase_pod_name
  couchbase_pod_name=$(find_container "plextracdb" "plextrac")

  log "******************"
  log "[BEGIN] Backing up couchbase"
  log "******************"

  if [[ "${LEGACY}" == true ]]; then
    backup_couchbase_legacy "$couchbase_pod_name"
  else
    backup_couchbase_cbbackupmgr "$couchbase_pod_name"
  fi
}

# Legacy path using the deprecated cbbackup tool.
# NOTE: cbbackup silently abandons DCP streams that go quiet for 30s and
# still exits 0 - exit code alone can't be trusted, so we validate its own
# transfer accounting (transferred vs. estimated msg count) before treating
# this as a good backup.
backup_couchbase_legacy() {
  local couchbase_pod_name="$1"
  local latestTarFile
  local latestTarPath
  local localTarFile

  if [[ "${DRY_RUN}" == true ]]; then
    log "Would run kubectl -n plextrac exec \"$couchbase_pod_name\" -- /bin/bash -c 'mkdir -p /backups; cbbackup -m full \"http://127.0.0.1:8091\" /backups -u ${CB_ADMIN_USER} -p ${CB_ADMIN_PASS} 2>&1'"
    return
  fi

  debug "Running cbbackup..."
  local cbbackupOutput
  local cbbackupExit=0
  # Single quotes work here
  # shellcheck disable=SC2016
  cbbackupOutput=$(kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c 'mkdir -p /backups; cbbackup -m full "http://127.0.0.1:8091" /backups -u ${CB_ADMIN_USER} -p ${CB_ADMIN_PASS} 2>&1') || cbbackupExit=$?
  debug "$cbbackupOutput"

  if [[ $cbbackupExit -ne 0 ]]; then
    error "cbbackup exited with status $cbbackupExit"
    echo "$cbbackupOutput"
    exit 1
  fi

  if echo "$cbbackupOutput" | grep -q "no response for"; then
    error "Couchbase backup incomplete: DCP stream(s) stalled and were abandoned mid-backup."
    echo "$cbbackupOutput" | grep "no response for"
    exit 1
  fi

  local transferLine
  transferLine=$(echo "$cbbackupOutput" | grep -Eo '\([0-9]+/estimated [0-9]+ msgs\)' | tail -n1)
  if [[ -z "$transferLine" ]]; then
    error "Couchbase backup validation failed: no transfer summary found in cbbackup output."
    echo "$cbbackupOutput"
    exit 1
  fi

  local transferNumbers
  transferNumbers=($(echo "$transferLine" | grep -Eo '[0-9]+'))
  if [[ "${transferNumbers[0]}" != "${transferNumbers[1]}" ]]; then
    error "Couchbase backup incomplete: transferred ${transferNumbers[0]} of estimated ${transferNumbers[1]} messages."
    exit 1
  fi

  log "Couchbase backup verified complete: ${transferNumbers[0]}/${transferNumbers[1]} messages transferred"

  debug "Compressing couchbase backup..."
  # Single quotes work here
  # shellcheck disable=SC2016
  # Find latest directory in /backups directory inside plextracdb container
  # and compress to tarball
  if kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c 'latestBackup=$(find /backups -maxdepth 1 -type d -print0 | xargs -0 stat -c"%Y %n" | sort -n | cut -d" " -f2- | tail -n1) && \
    backupDir=$(basename $latestBackup) && \
    tar -C /backups --remove-files -czvf ${latestBackup}.tar.gz $backupDir 2>&1'; then
    log "Completed compressing couchbase backup"
  else
    error "Failed to compress couchbase backup"
    exit 1
  fi

  latestTarPath=$(kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c 'find /backups -maxdepth 1 -name "*.tar.gz" -type f -print0 | xargs -0 stat -c"%Y %n" | sort -n | cut -d" " -f2- | tail -n1')
  latestTarFile=$(basename "$latestTarPath")
  localTarFile=${latestTarFile//.tar.gz/-couchbase-v$PLEXTRAC_VERSION.tar.gz}

  debug "Copying $couchbase_pod_name:$latestTarPath to local /opt/plextrac/backups/couchbase/${localTarFile}..."
  if kubectl -n plextrac cp --retries 3 "$couchbase_pod_name":"$latestTarPath" "/opt/plextrac/backups/couchbase/$localTarFile"; then
    debug "Completed copying $couchbase_pod_name:$latestTarPath to local /opt/plextrac/backups/couchbase/${localTarFile}"
  else
    error "Failed to copy $couchbase_pod_name:$latestTarPath to local /opt/plextrac/backups/couchbase/${localTarFile}"
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
  log "[DONE] Backing up couchbase"
  log "******************"
}

# Default path using cbbackupmgr, the actively-maintained replacement for
# cbbackup. Available on Community Edition for basic backup/restore (only
# `merge`/`examine` are Enterprise-gated). Each run gets its own fresh
# archive+repo under /backups so the resulting tarball mirrors exactly what
# the legacy path produces: one self-contained artifact per backup run.
backup_couchbase_cbbackupmgr() {
  local couchbase_pod_name="$1"
  local archivePath="/backups/cbbackupmgr-archive-$(date -u "+%Y%m%dT%H%M%Sz")"
  local repoName="plextrac"
  local latestTarPath
  local latestTarFile
  local localTarFile

  if [[ "${DRY_RUN}" == true ]]; then
    log "Would run kubectl -n plextrac exec \"$couchbase_pod_name\" -- /bin/bash -c 'cbbackupmgr config -a $archivePath -r $repoName && cbbackupmgr backup -a $archivePath -r $repoName -c http://127.0.0.1:8091 -u \$CB_ADMIN_USER -p \$CB_ADMIN_PASS --full-backup --no-progress-bar'"
    return
  fi

  debug "Configuring cbbackupmgr archive at $archivePath..."
  if ! kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c "cbbackupmgr config -a $archivePath -r $repoName 2>&1"; then
    error "Failed to configure cbbackupmgr archive"
    exit 1
  fi

  debug "Running cbbackupmgr backup..."
  local cbbackupmgrOutput
  local cbbackupmgrExit=0
  # shellcheck disable=SC2016
  cbbackupmgrOutput=$(kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c "cbbackupmgr backup -a $archivePath -r $repoName -c http://127.0.0.1:8091 -u \$CB_ADMIN_USER -p \$CB_ADMIN_PASS --full-backup --no-progress-bar 2>&1") || cbbackupmgrExit=$?
  debug "$cbbackupmgrOutput"

  if [[ $cbbackupmgrExit -ne 0 ]]; then
    error "cbbackupmgr backup exited with status $cbbackupmgrExit"
    echo "$cbbackupmgrOutput"
    exit 1
  fi

  if ! echo "$cbbackupmgrOutput" | grep -q "Backup completed successfully"; then
    error "cbbackupmgr backup did not report successful completion"
    echo "$cbbackupmgrOutput"
    exit 1
  fi

  if echo "$cbbackupmgrOutput" | grep -qi "Failed"; then
    error "cbbackupmgr backup reported a failure"
    echo "$cbbackupmgrOutput"
    exit 1
  fi

  log "Couchbase backup completed via cbbackupmgr"

  debug "Compressing cbbackupmgr archive..."
  if kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c "tar -C $(dirname "$archivePath") --remove-files -czvf ${archivePath}.tar.gz $(basename "$archivePath") 2>&1"; then
    log "Completed compressing couchbase backup"
  else
    error "Failed to compress couchbase backup"
    exit 1
  fi

  latestTarPath="${archivePath}.tar.gz"
  latestTarFile=$(basename "$latestTarPath")
  localTarFile=${latestTarFile//.tar.gz/-couchbase-v$PLEXTRAC_VERSION.tar.gz}

  debug "Copying $couchbase_pod_name:$latestTarPath to local /opt/plextrac/backups/couchbase/${localTarFile}..."
  if kubectl -n plextrac cp --retries 3 "$couchbase_pod_name":"$latestTarPath" "/opt/plextrac/backups/couchbase/$localTarFile"; then
    debug "Completed copying $couchbase_pod_name:$latestTarPath to local /opt/plextrac/backups/couchbase/${localTarFile}"
  else
    error "Failed to copy $couchbase_pod_name:$latestTarPath to local /opt/plextrac/backups/couchbase/${localTarFile}"
    exit 1
  fi

  debug "Removing $latestTarPath in $couchbase_pod_name..."
  if kubectl -n plextrac exec "$couchbase_pod_name" -- /bin/bash -c "rm -rf $latestTarPath"; then
    debug "Removed $latestTarPath in $couchbase_pod_name"
  else
    error "Failed to remove $latestTarPath in $couchbase_pod_name"
    exit 1
  fi

  log "******************"
  log "[DONE] Backing up couchbase"
  log "******************"
}

backup_postgres() {
  # get a list of current databases created for postgres by the init script by looking at the admin users
  # this command has been moved into the HEREDOC
  # postgresDatabases=`kubectl -n plextrac exec $postgres_pod_name -- /bin/bash -c 'PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -c "\du" --csv | awk -F, \'/[a-z]_admin/ {print $1}\' | sed "s/_admin//"`
  local postgres_pod_name
  local latestTarFile
  local latestTarPath
  local localTarFile

  postgres_pod_name=$(find_container "postgres" "plextrac")

  log "******************"
  log "[BEGIN] Backing up postgres"
  log "******************"

  if [[ "${DRY_RUN}" == true ]]; then
    log "Would run pg_dump command"
  else
    log "Postgres backup with group of commands in a HEREDOC"
    debug "Running pg_dump..."
    if kubectl -n plextrac exec -i --tty=false "$postgres_pod_name" -- /bin/bash << 'EOF'; then debug "Completed running pg_dump"; else error "Failed running pg_dump"; fi
postgresDatabases=`PGPASSWORD=$POSTGRES_PASSWORD psql -U $POSTGRES_USER -c "\du" --csv | awk -F, '/[a-z]_admin/ {print $1}' | sed "s/_admin//"`
backupTimestamp=$(date -u "+%Y-%m-%dT%H%M%Sz")
targetPath=/backups/$backupTimestamp
mkdir -p $targetPath
pgBackupFlags='--format=custom --compress=1 --verbose'
for db in ${postgresDatabases}; do
  echo "Backing up $db to $targetPath"
  PGPASSWORD=$POSTGRES_PASSWORD pg_dump -U $POSTGRES_USER $db $pgBackupFlags --file=$targetPath/$db.psql
done
EOF
  fi

  if [[ "${DRY_RUN}" == true ]]; then
    log "Would compress postgres backup inside $postgres_pod_name container"
  else
    debug "Compressing postgres backup..."
    # Single quotes work here
    # shellcheck disable=SC2016
    if kubectl -n plextrac exec "$postgres_pod_name" -- /bin/bash -c 'latestBackup=$(find /backups -maxdepth 1 -type d -print0 | xargs -0 stat -c"%Y %n" | sort -n | cut -d" " -f2- | tail -n1) && \
      tar -czvf ${latestBackup}.tar.gz $latestBackup 2>&1 && \
      rm -r $latestBackup'; then
      log "Completed compressing postgres backup"
    else
      error "Failed to compress postgres backup"
      exit 1
    fi
  fi


  if [[ "${DRY_RUN}" == true ]]; then
    log "Would copy backup file from $postgres_pod_name container to local host"
  else
    latestTarPath=$(kubectl -n plextrac exec "$postgres_pod_name" -- /bin/bash -c 'find /backups -maxdepth 1 -name "*.tar.gz" -type f -print0 | xargs -0 stat -c"%Y %n" | sort -n | cut -d" " -f2- | tail -n1')
    latestTarFile=$(basename "$latestTarPath")
    localTarFile=${latestTarFile//.tar.gz/-postgres-v$PLEXTRAC_VERSION.tar.gz}

    debug "Copying $postgres_pod_name:$latestTarPath to local /opt/plextrac/backups/postgres/${localTarFile}..."
    if kubectl -n plextrac cp --retries 3 "$postgres_pod_name":"$latestTarPath" "/opt/plextrac/backups/postgres/$localTarFile"; then
      debug "Completed copying $postgres_pod_name:$latestTarPath to local /opt/plextrac/backups/postgres/${localTarFile}"
    else
      error "Failed to copy $postgres_pod_name:$latestTarPath to local /opt/plextrac/backups/postgres/${localTarFile}"
      exit 1
    fi

    debug "Removing /backups/* in $postgres_pod_name..."
    if kubectl -n plextrac exec "$postgres_pod_name" -- /bin/bash -c 'rm -rf /backups/*'; then
      debug "Removed /backups/* in $postgres_pod_name"
    else
      error "Failed to remove /backups/* in $postgres_pod_name"
      exit 1
    fi
  fi

  log "******************"
  log "[DONE] Backing up postgres"
  log "******************"
}

backup_uploads() {
  local plextracapi_pod_name
  plextracapi_pod_name=$(find_container "plextracapi" "plextrac")

  log "******************"
  log "[BEGIN] Backing up uploads"
  log "******************"

  if [[ "${DRY_RUN}" == true ]]; then
    log "Would run kubectl -n plextrac exec -i \"$plextracapi_pod_name\" -- /bin/sh -c 'cd /usr/src/plextrac-api && tar -czf - uploads' > \"/opt/plextrac/backups/uploads/$(date -u "+%Y-%m-%dT%H%M%Sz")-uploads-v$PLEXTRAC_VERSION.tar.gz\""
  else
    debug "Compressing uploads backup..."
    mkdir -p /opt/plextrac/backups/uploads
    # tar with kubectl exec and stream redirection avoids base64 encoding
    # overhead used in kubectl cp
    if kubectl -n plextrac exec -i "$plextracapi_pod_name" -- /bin/sh -c 'cd /usr/src/plextrac-api && tar -czf - uploads' > "/opt/plextrac/backups/uploads/$(date -u "+%Y-%m-%dT%H%M%Sz")-uploads-v$PLEXTRAC_VERSION.tar.gz"; then
      debug "Completed compressing uploads backup"
    else
      error "Failed to backup uploads"
      exit 1
    fi
  fi

  log "******************"
  log "[DONE] Backing up uploads"
  log "******************"
}

fix_perms() {
  # Change the ownership of the backups so they can be maintained and copied offsite by the plextrac user
  log "******************"
  log "[BEGIN] Fixing permissions in /opt/plextrac/backups..."
  log "******************"

  debug "Running chown -R plextrac:plextrac /opt/plextrac/backups"
  if chown -R plextrac:plextrac /opt/plextrac/backups; then
    log "******************"
    log "[DONE] Fixed permissions in /opt/plextrac/backups"
    log "******************"
  else
    error "Failed to fix permissions in /opt/plextrac/backups"
    exit 1
  fi
}

# Main function
main() {
  parse_args "$@"

  log "******************"
  log "[BEGIN] Starting backup..."
  log "******************"

  if [[ "${DRY_RUN}" == true ]]; then
    log "Running in DRY-RUN mode - no changes will be made"
  fi

  for backupDir in couchbase postgres uploads offsite; do
    mkdir -p /opt/plextrac/backups/$backupDir
  done

  PLEXTRAC_VERSION=$(get_plextrac_version)
  debug "PLEXTRAC_VERSION is ${PLEXTRAC_VERSION}"

  if [[ "${COUCHBASE_ONLY}" == true ]]; then
    log "Running only couchbase backup..."
    backup_couchbase
  elif [[ "${POSTGRES_ONLY}" == true ]]; then
    log "Running only postgres backup..."
    backup_postgres
  elif [[ "${UPLOADS_ONLY}" == true ]]; then
    log "Running only uploads backup..."
    backup_uploads
  else
    log "Backing up couchbase, postgres, and uploads..."
    backup_couchbase
    backup_postgres
    backup_uploads
    fix_perms
  fi

  if [[ "${DRY_RUN}" == true ]]; then
    log "Dry run completed - no changes were made"
  else
    log "******************"
    log "[DONE] Backup completed successfully"
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
