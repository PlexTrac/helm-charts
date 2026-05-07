# PlexTrac Helm Chart — User Guide

This guide covers everything you need to install, configure, and upgrade PlexTrac on Kubernetes using the `plextrac` Helm chart.

---

## Table of contents

1. [Prerequisites](#prerequisites)
2. [Chart overview](#chart-overview)
3. [Installation](#installation)
4. [Setting the ingress hostname](#setting-the-ingress-hostname)
5. [Overriding values](#overriding-values)
6. [Secrets configuration](#secrets-configuration)
7. [TLS configuration](#tls-configuration)
8. [Image overrides](#image-overrides)
9. [Replica counts](#replica-counts)
10. [Upgrading](#upgrading)
11. [Verifying the installation](#verifying-the-installation)
12. [Troubleshooting](#troubleshooting)

---

## Prerequisites

- **Kubernetes** >= 1.25
- **Helm** >= 3.10
- A running **Ingress controller** (nginx-ingress or equivalent)
- **Persistent storage** — a default StorageClass that can provision ReadWriteOnce PVCs
- DNS or `/etc/hosts` entry pointing your chosen hostname to the cluster ingress IP

Optional, depending on your secrets strategy:

- [External Secrets Operator](https://external-secrets.io/) for `externalSecrets` mode
- [Secrets Store CSI Driver](https://secrets-store-csi-driver.sigs.k8s.io/) for `csi` mode
- [cert-manager](https://cert-manager.io/) if you want automatic TLS certificate provisioning

---

## Chart overview

The `plextrac` chart deploys the full PlexTrac platform as a set of Kubernetes workloads:

| Workload | Kind | Default replicas |
|---|---|---|
| plextracapi | Deployment | 3 |
| plextracnginx | Deployment | 1 |
| ckeditor-backend | Deployment | 3 |
| notification-engine | Deployment | 1 |
| notification-sender | Deployment | 1 |
| event-orchestrator | Deployment | 1 |
| contextual-scoring-service | Deployment | 1 |
| integration-worker | Deployment | 1 |
| datalake-maintainer | Deployment | 0 (disabled) |
| plextracdb (Couchbase) | StatefulSet | 1 |
| redis | StatefulSet | 1 |
| postgres | Deployment | 1 |
| minio | Deployment | 1 |
| minio-bootstrap | Job | — |
| migrations-and-etl | Job | — |

Chart defaults use public DockerHub images, `secrets.mode: manual` with `createKubernetesSecrets: true`, and auto-generate any secrets not explicitly provided. This means a standard install produces a working deployment without requiring any external secrets infrastructure.

---

## Installation

### Step 1 — Copy the starter values file

```bash
cp charts/plextrac/examples/values-self-hosted.yaml my-values.yaml
```

This file is the recommended starting point for self-hosted deployments. All comments explain what each field does.

### Step 2 — Set required values

Open `my-values.yaml` and set at minimum:

```yaml
global:
  ingress:
    host: plextrac.mycompany.com   # Your domain

secrets:
  manual:
    generatedSecrets:
      application:
        stringData:
          ADMIN_EMAIL: admin@mycompany.com   # Initial admin account email
```

If you have a CKEditor license, also set:

```yaml
secrets:
  manual:
    generatedSecrets:
      shared:
        stringData:
          CKEDITOR_SERVER_LICENSE_KEY: "your-license-key"
```

### Step 3 — Install

```bash
helm upgrade --install plextrac ./charts/plextrac \
  -f my-values.yaml \
  --namespace plextrac \
  --create-namespace
```

`helm upgrade --install` is idempotent — it installs on first run and upgrades on subsequent runs. You can safely re-run the same command to apply configuration changes.

---

## Setting the ingress hostname

The ingress hostname controls how PlexTrac is exposed externally. It is templated into:

- All four `Ingress` resources (nginx, CKEditor, GraphQL, MinIO)
- The `CLIENT_DOMAIN_NAME` key in the `env-config` ConfigMap, which is read by the backend API and nginx

### In your values file

```yaml
global:
  ingress:
    host: plextrac.mycompany.com
```

### As a `--set` flag

```bash
helm upgrade --install plextrac ./charts/plextrac \
  -f my-values.yaml \
  --set global.ingress.host=plextrac.mycompany.com
```

### Changing the hostname after install

Update the value and re-run `helm upgrade`. The ConfigMap and all Ingress objects are updated in place:

```bash
helm upgrade plextrac ./charts/plextrac \
  -f my-values.yaml \
  --set global.ingress.host=new-hostname.mycompany.com
```

> **Note:** Changing the hostname does not restart pods automatically. After the upgrade completes, restart the nginx and API pods to pick up the new `CLIENT_DOMAIN_NAME`:
> ```bash
> kubectl -n plextrac rollout restart deployment/plextracnginx deployment/plextracapi
> ```

---

## Overriding values

Helm provides several ways to override default values. They can be combined and the last value wins when the same key appears multiple times.

### Method 1 — Values file (`-f`)

The recommended approach. Create a file with only the values you want to change:

```yaml
# my-values.yaml
global:
  ingress:
    host: plextrac.mycompany.com

replicaCounts:
  plextracapi: 5
```

```bash
helm upgrade --install plextrac ./charts/plextrac -f my-values.yaml
```

You can layer multiple files. They are applied left to right, with later files taking precedence:

```bash
helm upgrade --install plextrac ./charts/plextrac \
  -f charts/plextrac/examples/values-self-hosted.yaml \
  -f my-overrides.yaml
```

### Method 2 — Inline `--set`

For single values, especially in CI pipelines or quick tests:

```bash
helm upgrade --install plextrac ./charts/plextrac \
  -f my-values.yaml \
  --set global.ingress.host=plextrac.mycompany.com \
  --set replicaCounts.plextracapi=5
```

For nested keys, use dot notation. For array values, use index notation:

```bash
# Set a nested value
--set secrets.manual.createKubernetesSecrets=true

# Set an array element (e.g., imagePullSecrets)
--set 'global.imagePullSecrets[0].name=my-registry-secret'
```

### Method 3 — `--set-string`

Forces the value to be treated as a string, which is useful for values that look like numbers or booleans:

```bash
--set-string images.plextracdb.tag=6.5.1
```

### Precedence order (lowest to highest)

1. `charts/plextrac/values.yaml` (chart defaults)
2. `-f file1.yaml`
3. `-f file2.yaml` (overwrites file1 for same keys)
4. `--set` / `--set-string` flags

### Previewing the rendered output

Before applying changes, see exactly what Helm will generate:

```bash
helm template plextrac ./charts/plextrac -f my-values.yaml | less
```

To filter for a specific resource:

```bash
helm template plextrac ./charts/plextrac -f my-values.yaml \
  | grep -A 30 "name: env-config"
```

### Viewing current values on a live release

```bash
# Values you supplied (user-supplied only)
helm get values plextrac -n plextrac

# All values including chart defaults
helm get values plextrac -n plextrac --all
```

---

## Secrets configuration

The chart supports three secrets modes. Set `secrets.mode` to choose one.

### Manual mode (default — recommended for self-hosted)

The chart auto-generates all required secrets on first install and preserves existing values on upgrade. You only need to provide values that can't be auto-generated (like email addresses and license keys).

```yaml
secrets:
  mode: manual
  manual:
    createKubernetesSecrets: true
    generatedSecrets:
      application:
        stringData:
          ADMIN_EMAIL: admin@mycompany.com
      shared:
        stringData:
          CKEDITOR_SERVER_LICENSE_KEY: "your-key"
```

**How auto-generation works:**
- On install: any required key not present in `stringData` or `data` is filled with a random 40-character alphanumeric value
- On upgrade: Helm looks up the existing secret in the cluster and reuses its current value — passwords are never rotated automatically

**Providing your own values for auto-generated keys:**

Any key in `stringData` takes precedence over auto-generation. To pin a specific password rather than letting the chart generate one:

```yaml
secrets:
  manual:
    generatedSecrets:
      application:
        stringData:
          ADMIN_EMAIL: admin@mycompany.com
          REDIS_PASSWORD: "my-specific-redis-password"
          CB_ADMIN_PASS: "my-couchbase-admin-password"
```

**Static username/database defaults:**

The following keys have static defaults (matching the `docker-compose.yml` reference deployment) and are pre-populated in `stringData`. You can override any of them:

| Key | Default |
|---|---|
| `CB_ADMIN_USER` | `ptadminuser` |
| `CB_API_USER` | `ptapiuser` |
| `CB_BACKUP_USER` | `ptbackupuser` |
| `CB_BUCKET` | `reportMe` |
| `POSTGRES_USER` | `postgres` |
| `PG_CORE_DB` | `core` |
| `PG_CORE_ADMIN_USER` | `core_admin` |
| `PG_CORE_RO_USER` | `core_ro` |
| `PG_CORE_RW_USER` | `core_rw` |
| `MINIO_ROOT_USER` | `admin` |
| `MINIO_LOCAL_USER` | `localadmin` |

### External Secrets Operator mode

Use when you have ESO installed and a `ClusterSecretStore` connected to your secret backend (AWS Secrets Manager, GCP Secret Manager, HashiCorp Vault, etc.).

```yaml
secrets:
  mode: externalSecrets
  externalSecrets:
    refreshInterval: 1h
    secretStoreRef:
      kind: ClusterSecretStore
      name: my-cluster-secret-store
    application:
      targetSecretName: application-secrets
      remoteKey: plextrac/application-secrets
    shared:
      targetSecretName: shared-secrets
      remoteKey: plextrac/shared-secrets
```

See `charts/plextrac/examples/values-external-secrets.yaml` for a complete example.

### CSI Secrets Store mode

Use when Secrets Store CSI Driver is installed with a provider (AWS, GCP, Azure, Vault).

```yaml
secrets:
  mode: csi
  csi:
    secretProviderClass:
      enabled: true
      name: plextrac-secrets-provider
      provider: aws
      parameters:
        objects: |
          - objectName: "plextrac/application-secrets"
            objectType: "secretsmanager"
      secretObjects:
        - secretName: application-secrets
          type: Opaque
          data:
            - objectName: "plextrac/application-secrets"
              key: application-secrets
```

See `charts/plextrac/examples/values-csi-aws.yaml` and `values-csi-gcp.yaml` for provider-specific examples.

For full details on all three modes, see [docs/runbooks/secrets-modes.md](runbooks/secrets-modes.md).

---

## TLS configuration

### Option A — cert-manager (recommended)

If cert-manager is installed, set your `ClusterIssuer` name. The chart's Ingress resources include the appropriate annotation and the TLS stanza is populated automatically.

```yaml
global:
  ingress:
    host: plextrac.mycompany.com
    tlsSecretName: plextrac-com-tls
    certManagerClusterIssuer: letsencrypt-prod
```

### Option B — Provide your own certificate via Helm

Set the TLS secret values directly. The chart creates the `kubernetes.io/tls` Secret from the provided PEM content:

```yaml
secrets:
  manual:
    generatedSecrets:
      tls:
        enabled: true
        name: plextrac-com-tls
        crt: |
          -----BEGIN CERTIFICATE-----
          ...
        key: |
          -----BEGIN PRIVATE KEY-----
          ...
```

> **Security note:** Storing certificates in a values file means they end up in Helm release history. If this is a concern, use cert-manager or manage the TLS secret externally (create it with `kubectl` before installing) and set `tls.enabled: false`.

### Option C — Pre-create the TLS secret manually

Create the secret before installing, and reference it by name:

```bash
kubectl -n plextrac create secret tls plextrac-com-tls \
  --cert=./fullchain.pem \
  --key=./privkey.pem
```

Then in your values:

```yaml
global:
  ingress:
    tlsSecretName: plextrac-com-tls
secrets:
  manual:
    generatedSecrets:
      tls:
        enabled: false   # Chart won't try to create it
```

### Option D — No TLS (development/testing only)

Leave `certManagerClusterIssuer` empty and `tls.enabled: false`. The Ingress objects are still created; traffic arrives unencrypted.

---

## Image overrides

All images are configurable. The defaults point to public DockerHub repositories.

### Pinning a specific version

```yaml
images:
  backend:
    tag: "2.28.0"
  nginx:
    tag: "2.28.0"
```

### Using a private registry mirror

If you pull images through an internal mirror or proxy, override the repository for each image:

```yaml
images:
  backend:
    repository: registry.mycompany.com/plextrac/plextracapi
    tag: stable
  nginx:
    repository: registry.mycompany.com/plextrac/plextracnginx
    tag: stable
  plextracdb:
    repository: registry.mycompany.com/plextrac/plextracdb
    tag: 6.5.1
  postgres:
    repository: registry.mycompany.com/plextrac/plextracpostgres
    tag: stable
  minio:
    repository: registry.mycompany.com/plextrac/minio
    tag: latest
  minioBootstrap:
    repository: registry.mycompany.com/plextrac/plextrac-minio-bootstrap
    tag: stable
  ckeditor:
    repository: registry.mycompany.com/cke-cs/cs
    tag: latest
  redis:
    repository: registry.mycompany.com/redis
    tag: 8.4.0-alpine
  redisExporter:
    repository: registry.mycompany.com/oliver006/redis_exporter
    tag: latest
```

### Using a private registry (imagePullSecrets)

If your registry requires authentication, every workload needs an `imagePullSecrets` reference pointing to a `kubernetes.io/dockerconfigjson` Secret. The chart wires this up automatically — you just have to make the Secret exist and tell the chart its name via `global.imagePullSecrets`.

There are three ways to provide the Secret. Pick the one that matches your secrets workflow.

#### Option 1 — Let the chart create the Secret from values (simplest)

Use this when you're already using `secrets.mode: manual` (the default). The chart will create a `kubernetes.io/dockerconfigjson` Secret in the release namespace from a `dockerconfigjson` blob you supply in your values file.

**Step 1 — generate the dockerconfigjson blob.** The easiest way is to have `kubectl` build it for you and print the contents:

```bash
kubectl create secret docker-registry tmp \
  --docker-server=registry.mycompany.com \
  --docker-username=myuser \
  --docker-password=mypassword \
  --dry-run=client -o json \
  | jq -r '.data[".dockerconfigjson"]' \
  | base64 -d
```

This prints a single-line JSON blob that looks like:

```json
{"auths":{"registry.mycompany.com":{"username":"myuser","password":"mypassword","auth":"bXl1c2VyOm15cGFzc3dvcmQ="}}}
```

**Step 2 — paste it into your values file:**

```yaml
secrets:
  mode: manual
  manual:
    generatedSecrets:
      registryCredentials:
        enabled: true
        name: regcred-dorf
        dockerconfigjson: '{"auths":{"registry.mycompany.com":{"username":"myuser","password":"mypassword","auth":"bXl1c2VyOm15cGFzc3dvcmQ="}}}'

global:
  imagePullSecrets:
    - name: regcred-dorf   # must match the name above
```

**Step 3 — install or upgrade as usual.** The chart creates the Secret and every Deployment / StatefulSet / Job picks it up.

> **Security note:** The `dockerconfigjson` value contains a base64-encoded (not encrypted) password and ends up in Helm release history. Treat your values file like a credential. If this is a concern, use Option 2 or Option 3 instead, or keep registry creds in a separate values file (`-f secrets-overrides.yaml`) that is excluded from version control.

#### Option 2 — Pre-create the Secret with `kubectl`

Use this when you'd rather keep registry credentials out of values files entirely.

```bash
kubectl -n plextrac create secret docker-registry my-registry-creds \
  --docker-server=registry.mycompany.com \
  --docker-username=myuser \
  --docker-password=mypassword
```

Then in your values, just point at it by name:

```yaml
global:
  imagePullSecrets:
    - name: my-registry-creds

secrets:
  manual:
    generatedSecrets:
      registryCredentials:
        enabled: false   # chart won't try to create it
```

You can list multiple if you pull from more than one registry:

```yaml
global:
  imagePullSecrets:
    - name: my-registry-creds
    - name: ckeditor-registry-creds
```

#### Option 3 — Sync the Secret from External Secrets Operator

Use this when you're already running ESO and storing registry credentials in AWS Secrets Manager / GCP Secret Manager / Vault / etc. The chart includes an `ExternalSecret` template that pulls a `dockerconfigjson` value from your secret store and materializes it as a `kubernetes.io/dockerconfigjson` Secret.

The remote secret value must already be a valid dockerconfigjson string (build it the same way as Step 1 of Option 1, then store the JSON blob in your secret backend).

```yaml
secrets:
  mode: externalSecrets
  externalSecrets:
    refreshInterval: 1h
    secretStoreRef:
      kind: ClusterSecretStore
      name: my-cluster-secret-store
    registryCredentials:
      enabled: true
      targetSecretName: regcred-dorf
      remoteKey: plextrac/registry-credentials   # key in your secret backend

global:
  imagePullSecrets:
    - name: regcred-dorf   # must match targetSecretName above
```

#### Verification

After installing, confirm the secret is attached to a pod:

```bash
kubectl -n plextrac get pod <pod-name> -o jsonpath='{.spec.imagePullSecrets}'
```

If you see `ImagePullBackOff` on a pod, describe it to see the registry response:

```bash
kubectl -n plextrac describe pod <pod-name> | grep -A 5 Events
```

Common causes: the secret name in `global.imagePullSecrets` doesn't match the Secret that was created, the credentials are wrong, or the image repository overrides under `images:` still point at the public DockerHub path instead of your private registry.

Leave `global.imagePullSecrets` empty (`[]`) when using public images.

---

## Replica counts

Control the number of replicas for each scalable service:

```yaml
replicaCounts:
  plextracapi: 3              # Core API — increase for higher throughput
  ckeditor: 3                 # CKEditor backend
  eventOrchestrator: 1        # Must be 1 (not horizontally scalable)
  notificationEngine: 1       # Must be 1 (not horizontally scalable)
  notificationSender: 1       # Must be 1 (not horizontally scalable)
  integrationWorker: 1
  contextualScoringService: 1
  datalakeMaintainer: 0       # Disabled by default — set to 1 to enable
```

For minimal resource usage (development/staging):

```yaml
replicaCounts:
  plextracapi: 1
  ckeditor: 1
  eventOrchestrator: 1
  notificationEngine: 1
  notificationSender: 1
  integrationWorker: 1
  contextualScoringService: 1
  datalakeMaintainer: 0
```

---

## Upgrading

Upgrades use the same command as install:

```bash
helm upgrade --install plextrac ./charts/plextrac \
  -f my-values.yaml \
  --namespace plextrac
```

**What happens during upgrade:**

- Deployments and StatefulSets with changed specs are updated with the configured rolling-update strategy
- The `migrations-and-etl` and `bootstrap-minio` Jobs are managed as Helm hooks (`post-install,post-upgrade` with `before-hook-creation` delete policy). Helm deletes the previous Job and creates a fresh one on every `helm upgrade`, which is required because `Job.spec.template` is immutable
- Secrets in `manual` mode are preserved: the chart looks up existing secret values and reuses them for any key not explicitly set in `stringData`

**Checking what would change before applying:**

```bash
helm diff upgrade plextrac ./charts/plextrac -f my-values.yaml -n plextrac
```

`helm diff` is a plugin. Install it with `helm plugin install https://github.com/databus23/helm-diff` if not already present.

**Rolling back:**

```bash
# List available revisions
helm history plextrac -n plextrac

# Roll back to a previous revision
helm rollback plextrac <revision-number> -n plextrac
```

---

## Verifying the installation

### Check Helm release status

```bash
helm status plextrac -n plextrac
```

### Check that all pods are running

```bash
kubectl -n plextrac get pods
```

All pods should reach `Running` or `Completed` state. Common startup order: plextracdb → postgres → redis → minio → migrations-and-etl → plextracapi → everything else.

### Check secrets are present

```bash
kubectl -n plextrac get secrets
```

In manual mode you should see at minimum:
- `application-secrets`
- `shared-secrets`

### Check ingress

```bash
kubectl -n plextrac get ingress
```

The `ADDRESS` field should be populated with your ingress controller's IP once DNS propagates.

### Check logs for a specific service

```bash
kubectl -n plextrac logs deployment/plextracapi --tail=50
kubectl -n plextrac logs deployment/plextracnginx --tail=50
```

### Quick end-to-end smoke test

```bash
curl -I https://plextrac.mycompany.com/api/v2/health/full
```

Expected response: `HTTP/2 200`

---

## Troubleshooting

### Pods stuck in `Pending`

Usually a PVC issue. Check:

```bash
kubectl -n plextrac get pvc
kubectl -n plextrac describe pvc <pvc-name>
```

Pending PVCs mean no StorageClass can fulfill the claim. Verify your cluster has a default StorageClass:

```bash
kubectl get storageclass
```

### Pods stuck in `Init:Error` or `Init:CrashLoopBackOff`

Check init container logs:

```bash
kubectl -n plextrac logs <pod-name> -c <init-container-name>
```

### Pods stuck in `CrashLoopBackOff`

Fetch logs including previous container run:

```bash
kubectl -n plextrac logs <pod-name> --previous
```

### `application-secrets` or `shared-secrets` not found

In manual mode with `createKubernetesSecrets: true`, secrets are created by the Helm release. If they're missing, check that the release completed without errors:

```bash
helm status plextrac -n plextrac
helm get manifest plextrac -n plextrac | grep "kind: Secret"
```

If using `createKubernetesSecrets: false`, you must create the secrets manually before installing. See [docs/runbooks/secrets-modes.md](runbooks/secrets-modes.md).

### `Error: INSTALLATION FAILED: values don't meet the specifications of the schema`

Your values file has a type or structure error. The error message includes the specific field. Check it against `charts/plextrac/values.schema.json` or run:

```bash
helm lint ./charts/plextrac -f my-values.yaml
```

### Ingress not routing traffic

1. Confirm the ingress controller is running: `kubectl -n ingress-nginx get pods`
2. Confirm the `ADDRESS` is set: `kubectl -n plextrac get ingress`
3. Confirm DNS resolves to the ingress IP: `nslookup plextrac.mycompany.com`
4. Check ingress controller logs: `kubectl -n ingress-nginx logs -l app.kubernetes.io/name=ingress-nginx --tail=100`

### PlexTrac API returns 502 Bad Gateway

Nginx is up but cannot reach `plextracapi`. Check:

```bash
kubectl -n plextrac get pods -l app=plextracapi
kubectl -n plextrac logs deployment/plextracapi --tail=100
```

The API performs a readiness probe at `/api/v2/health/full`. If Couchbase, Redis, or Postgres are not ready, the probe will fail and the pod will not receive traffic.

### Running `helm template` locally for debugging

Render the full manifest without contacting the cluster:

```bash
helm template plextrac ./charts/plextrac \
  -f my-values.yaml \
  --set global.ingress.host=plextrac.mycompany.com \
  > rendered.yaml

# Inspect a specific resource
grep -A 50 "name: env-config" rendered.yaml
```

This is also useful for validating your values file changes before a real upgrade.
