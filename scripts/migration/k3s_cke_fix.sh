#!/bin/bash
## Script: k3s_cke_fix.sh
## Source: vendored from the pt-ansible repo (roles/plextrac/files); that repo is
##         canonical. Keep this copy in sync with upstream. The one change from
##         upstream: recovery_script.js is resolved from this script's own
##         directory rather than a fixed install path.
## Description:
##   Re-point CKEditor after a data migration/restore. Runs recovery_script.js
##   inside the CKEditor (CS) pod to regenerate CKEDITOR_SERVER_CONFIG so the
##   pod authenticates to the existing per-tenant CKE environments. Assumes the
##   app is deployed in the "plextrac" namespace.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CKEDITOR_POD_NAME=$(kubectl -n plextrac get pod -l app=ckeditor-backend -o=name | cut -d / -f 2)
kubectl -n plextrac cp "$SCRIPT_DIR/recovery_script.js" "$CKEDITOR_POD_NAME":/usr/src/cs

kv=$(kubectl -n plextrac exec "$CKEDITOR_POD_NAME" -- /bin/sh -c 'echo "$CKEDITOR_SERVER_CONFIG"' | base64 -d | jq -r 'to_entries | "\(.[0].key)=\(.[0].value.environment_id)"')
kubectl -n plextrac exec "$CKEDITOR_POD_NAME" -- /bin/sh -c 'node recovery_script.js $kv'
