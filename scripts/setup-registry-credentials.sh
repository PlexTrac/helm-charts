#!/usr/bin/env bash
# setup-registry-credentials.sh
#
# Sources .env.local and creates Kubernetes image pull secrets for the PlexTrac
# registry and (optionally) the CKEditor registry, then prints the
# global.imagePullSecrets snippet to add to my-values.yaml.
#
# Usage:
#   ./scripts/setup-registry-credentials.sh [--namespace <ns>] [--release-name <name>] [--dry-run]
#
# Prerequisites:
#   - kubectl configured and pointing at your target cluster
#   - jq installed (used to safely build the dockerconfigjson blob)
# Fill in DOCKER_REGISTRY, DOCKER_USERNAME, DOCKER_PASSWORD in .env.local first.

set -euo pipefail

NAMESPACE="plextrac"
RELEASE_NAME="plextrac"
DRY_RUN=false
ENV_FILE=".env.local"

# ── Argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace|-n)    NAMESPACE="$2"; shift 2 ;;
    --release-name)    RELEASE_NAME="$2"; shift 2 ;;
    --dry-run)         DRY_RUN=true; shift ;;
    --env-file)        ENV_FILE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Preflight checks ────────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed."
  echo "       Install it (e.g. brew install jq) and retry."
  exit 1
fi

# ── Load .env.local ─────────────────────────────────────────────────────────
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found."
  echo "       Run: cp .env.example .env.local  and fill in your registry credentials."
  exit 1
fi

# shellcheck source=/dev/null
set -o allexport
source "$ENV_FILE"
set +o allexport

# ── Helpers ─────────────────────────────────────────────────────────────────
make_dockerconfigjson() {
  local server="$1" user="$2" pass="$3"
  local auth
  auth=$(printf '%s:%s' "$user" "$pass" | base64 | tr -d '\n')
  # jq handles proper JSON escaping for passwords containing quotes or backslashes.
  jq -cn \
    --arg server "$server" \
    --arg user   "$user"   \
    --arg pass   "$pass"   \
    --arg auth   "$auth"   \
    '{"auths":{($server):{"username":$user,"password":$pass,"auth":$auth}}}'
}

create_or_replace_secret() {
  local name="$1" json="$2"
  if [[ "$DRY_RUN" == true ]]; then
    echo "[dry-run] Would create secret '$name' in namespace '$NAMESPACE'"
    return
  fi
  kubectl create secret generic "$name" \
    --type=kubernetes.io/dockerconfigjson \
    --from-literal=.dockerconfigjson="$json" \
    --namespace "$NAMESPACE" \
    --dry-run=client -o yaml \
    | kubectl apply -f -
  kubectl label secret "$name" \
    --namespace "$NAMESPACE" \
    app.kubernetes.io/managed-by=Helm \
    --overwrite
  kubectl annotate secret "$name" \
    --namespace "$NAMESPACE" \
    meta.helm.sh/release-name="$RELEASE_NAME" \
    meta.helm.sh/release-namespace="$NAMESPACE" \
    --overwrite
  echo "Secret '$name' applied in namespace '$NAMESPACE'."
}

# ── Ensure namespace exists with Helm ownership labels ───────────────────────
# Labels and annotations allow `helm upgrade --install --create-namespace` to
# adopt the namespace rather than rejecting it as unmanaged.
if [[ "$DRY_RUN" == true ]]; then
  echo "[dry-run] Would ensure namespace '$NAMESPACE' exists with Helm labels"
else
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace "$NAMESPACE" \
    app.kubernetes.io/managed-by=Helm \
    --overwrite
  kubectl annotate namespace "$NAMESPACE" \
    meta.helm.sh/release-name="$RELEASE_NAME" \
    meta.helm.sh/release-namespace="$NAMESPACE" \
    --overwrite
fi

# ── PlexTrac registry ────────────────────────────────────────────────────────
if [[ -z "${DOCKER_REGISTRY:-}" || -z "${DOCKER_USERNAME:-}" || -z "${DOCKER_PASSWORD:-}" ]]; then
  echo "ERROR: DOCKER_REGISTRY, DOCKER_USERNAME, and DOCKER_PASSWORD must be set in $ENV_FILE"
  exit 1
fi

PLEXTRAC_JSON=$(make_dockerconfigjson "$DOCKER_REGISTRY" "$DOCKER_USERNAME" "$DOCKER_PASSWORD")
create_or_replace_secret "internal-registry-creds" "$PLEXTRAC_JSON"

# ── CKEditor registry (optional) ────────────────────────────────────────────
CKEDITOR_SECRET_NAME=""
CKEDITOR_JSON=""

if [[ -n "${CKEDITOR_DOCKER_USERNAME:-}" && -n "${CKEDITOR_DOCKER_PASSWORD:-}" ]]; then
  CKEDITOR_SERVER="${CKEDITOR_DOCKER_SERVER:-docker.cke-cs.com}"
  CKEDITOR_JSON=$(make_dockerconfigjson "$CKEDITOR_SERVER" "$CKEDITOR_DOCKER_USERNAME" "$CKEDITOR_DOCKER_PASSWORD")
  CKEDITOR_SECRET_NAME="ckeditor-registry-creds"
  create_or_replace_secret "$CKEDITOR_SECRET_NAME" "$CKEDITOR_JSON"
else
  echo "CKEditor credentials not set — skipping ckeditor-registry-creds secret."
fi

# ── Print my-values.yaml snippet ────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
echo "Registry secrets created in namespace '$NAMESPACE'."
echo "Add the following to your my-values.yaml:"
echo "────────────────────────────────────────────────────────────────────────────"
echo ""
echo "global:"
echo "  imagePullSecrets:"
echo "    - name: internal-registry-creds"
if [[ -n "$CKEDITOR_SECRET_NAME" ]]; then
  echo "    - name: ckeditor-registry-creds"
fi
echo ""
echo "# Secrets have been created directly in the cluster — do not set"
echo "# secrets.manual.generatedSecrets.registryCredentials.enabled: true."
echo ""
echo "────────────────────────────────────────────────────────────────────────────"
