# PlexTrac Helm Chart — Installation & Configuration Guide

---

## Table of contents

1. [Before you begin](#before-you-begin)
2. [Phase 1 — Set up your cluster](#phase-1--set-up-your-cluster)
3. [Phase 2 — Gather credentials and secrets](#phase-2--gather-credentials-and-secrets)
4. [Phase 3 — Configure your values file](#phase-3--configure-your-values-file)
5. [Phase 4 — Install](#phase-4--install)
6. [Phase 5 — Verify](#phase-5--verify)
7. [Reference: Secrets configuration](#reference-secrets-configuration)
8. [Reference: Storage configuration](#reference-storage-configuration)
9. [Reference: TLS configuration](#reference-tls-configuration)
10. [Reference: Image overrides](#reference-image-overrides)
11. [Reference: Replica counts](#reference-replica-counts)
12. [Reference: Overriding values](#reference-overriding-values)
13. [Upgrading](#upgrading)
14. [Troubleshooting](#troubleshooting)

---

## Before you begin

Read through this checklist before touching any `helm` command. Installing the chart before cluster infrastructure and credentials are in place is the most common source of failed installs.

### What the chart deploys

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
| bootstrap-minio | Job | — |
| migrations-and-etl | Job | — |

> `datalake-maintainer` ships **disabled** (0 replicas) by default — seeing it with no pods is expected and does not block startup. `migrations-and-etl` runs as a normal Job during install (its name includes the release revision, e.g. `migrations-and-etl-1`) and migrates the database before the API reports healthy. `bootstrap-minio` is a Helm **post-install/post-upgrade hook**, so it appears only *after* the main workloads are running. See [Phase 4](#phase-4--install).

**Minimum cluster resources:** ~1.6 CPU cores and ~4.3 GiB RAM in requests at default replica counts; ~41 GiB persistent storage.

### Software requirements

| Tool | Minimum version |
|---|---|
| Kubernetes | 1.25 |
| Helm | 3.10 |
| NGINX Ingress Controller | any current release |

> All Ingress resources use `ingressClassName: nginx`. Other ingress controllers are not supported without changes to annotations and ingress class values.

### Install Helm

The chart requires Helm 3.10 or newer. If Helm is not already on the machine you run installs from, install it before Phase 1. (`kubectl` is bundled with K3s; on managed clusters install it through your provider's flow.)

```bash
# Official installer (Linux/macOS)
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

helm version   # confirm v3.10.0 or newer
```

Distribution packages (`apt install helm`, `dnf install helm`, `brew install helm`) also work as long as they provide 3.10+.

### What the chart auto-generates

These secrets are generated automatically on first install and **preserved on every upgrade** — you do not need to provide them:

- Database passwords (Couchbase, PostgreSQL)
- Redis password
- MinIO credentials
- JWT signing keys
- MFA and cookie encryption keys
- Internal API keys

**What you must provide yourself** is covered in [Phase 2](#phase-2--gather-credentials-and-secrets).

---

## Phase 1 — Set up your cluster

Complete all steps in this phase before moving to Phase 2.

### Step 1.1 — Provision a Kubernetes cluster

#### K3s (recommended for self-hosted / on-prem)

K3s bundles containerd, CoreDNS, metrics-server, and the `local-path` StorageClass. No extra OS packages or container runtime needed.

**OS requirements:**
- Linux: Ubuntu 20.04+, Debian 11+, RHEL/Rocky/AlmaLinux 8+
- Kernel ≥ 5.4
- Ports 6443 (API), 80 and 443 (ingress) open
- **Minimum node sizing:** 4 vCPU, 16 GiB RAM, 100 GiB disk

**Before installing K3s:**

- **Run the install as a dedicated non-root user**, not as `root`. Create one and give it `sudo` for the few privileged steps:
  ```bash
  sudo useradd -m -s /bin/bash plextrac
  sudo usermod -aG sudo plextrac      # use the 'wheel' group on RHEL/Rocky/AlmaLinux
  su - plextrac
  ```
  Run every `kubectl` and `helm` command as this user; only the `cp`, `chown`, and `hostnamectl` steps need `sudo`.
- **Set a short, stable hostname first.** K3s derives the Kubernetes node name from the machine's hostname. Long cloud-assigned names (for example the default instance names on GCP/AWS) can exceed the 63-character node-name limit and stop the node from registering. Set a short hostname and make it durable so it survives reboots:
  ```bash
  sudo hostnamectl set-hostname plextrac-node
  # hostnamectl alone is not always durable on cloud images. Also stop the cloud
  # agent from rewriting the hostname on boot:
  #   cloud-init:  set 'preserve_hostname: true' in /etc/cloud/cloud.cfg
  #   GCP:         set 'set-hostname: false' under [Instance] in /etc/default/instance_configs.cfg
  ```
  If K3s is already installed under the wrong name, set the hostname and then `sudo systemctl restart k3s` so the node re-registers.

```bash
# Install K3s and disable the built-in Traefik ingress controller.
# PlexTrac uses NGINX — running both causes conflicts.
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -

# Copy the kubeconfig so kubectl and helm can reach the cluster as your user.
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config

# Point kubectl/helm at this kubeconfig. The K3s-bundled kubectl defaults to the
# root-only /etc/rancher/k3s/k3s.yaml, so without KUBECONFIG you would have to run
# every command with sudo and the copy above would have no effect.
export KUBECONFIG=$HOME/.kube/config
echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.bashrc

# Confirm the node is Ready (no sudo needed)
kubectl get nodes
```

#### GKE, AKS, EKS

Use your cloud provider's console or CLI to create a cluster (Kubernetes ≥ 1.25). Configure `kubectl` access with your provider's standard flow (`gcloud container clusters get-credentials`, `az aks get-credentials`, `aws eks update-kubeconfig`).

Set the storage class in your values file after cluster creation — see the table in [Reference: Storage configuration](#reference-storage-configuration).

For EKS, enable the **EBS CSI driver** add-on before installing, or PVCs will not provision.

---

### Step 1.2 — Install NGINX Ingress Controller

Run this on every platform (K3s, GKE, AKS, EKS):

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --wait
```

Confirm it is running:

```bash
kubectl -n ingress-nginx get pods
kubectl -n ingress-nginx get svc ingress-nginx-controller
```

The `ingress-nginx-controller` Service will have an `EXTERNAL-IP` once the LoadBalancer is provisioned. **Note this IP — you need it for DNS in the next step.**

---

### Step 1.3 — Create a DNS record

Create an A record pointing your chosen hostname to the ingress LoadBalancer IP:

```
plextrac.mycompany.com  →  <EXTERNAL-IP from Step 1.2>
```

For local/lab installs without DNS, add an entry to `/etc/hosts` on any machine that needs to reach PlexTrac:

```
<EXTERNAL-IP>  plextrac.mycompany.com
```

> DNS propagation can take minutes to hours depending on your provider. You can proceed with configuration while waiting, but the final smoke test requires DNS to resolve.

---

## Phase 2 — Gather credentials and secrets

**Do not run `helm install` until you have completed this phase.**

Copy `.env.example` from the repo root and fill it in:

```bash
cp .env.example .env.local
# Edit .env.local with your domain, credentials, and any optional integration keys
```

`.env.local` is **not** read by Helm. Only `scripts/setup-registry-credentials.sh` reads it, and only the `DOCKER_*` / `CKEDITOR_DOCKER_*` variables. Every other variable — your domain, TLS, storage class, admin email, integrations — is a reference checklist that you copy into `my-values.yaml` yourself in [Phase 3](#phase-3--configure-your-values-file); each variable includes a comment showing the exact `my-values.yaml` field it maps to. Setting `PLEXTRAC_DOMAIN` in `.env.local`, for example, does **not** configure the chart — you must also set `global.ingress.host` in `my-values.yaml`.

### 2.1 — Required: domain

| What | Where it goes |
|---|---|
| Your hostname (from Step 1.3) | `global.ingress.host` |
| Admin notification email (optional) | `secrets.manual.generatedSecrets.application.stringData.ADMIN_EMAIL` |

### 2.2 — Docker registry credentials

PlexTrac images require authentication. Fill in your registry credentials in `.env.local`, then run the setup script — it creates the Kubernetes pull secrets and prints the `my-values.yaml` snippet to paste in:

```bash
# Fill in DOCKER_REGISTRY, DOCKER_USERNAME, DOCKER_PASSWORD in .env.local first
./scripts/setup-registry-credentials.sh
```

Options:

```bash
./scripts/setup-registry-credentials.sh --namespace plextrac   # default namespace
./scripts/setup-registry-credentials.sh --dry-run              # preview without creating
./scripts/setup-registry-credentials.sh --env-file /path/to/other.env
```

The script creates `plextrac-registry-creds` (and `ckeditor-registry-creds` if CKEditor credentials are set), then prints the exact `global.imagePullSecrets` and `registryCredentials` block to add to `my-values.yaml`.

> **Security note:** The `dockerconfigjson` blob is base64-encoded (not encrypted). Treat your values file like a credential, or supply registry creds via a separate `-f secrets.yaml` file excluded from version control.

### 2.3 — Optional integrations

These can be left blank — the chart installs without them. Add them any time via `helm upgrade`.

| Key | Purpose |
|---|---|
| `CKEDITOR_SERVER_LICENSE_KEY` | Enables collaborative editing features |
| `LAUNCH_DARKLY_SDK_KEY` | Feature flag service |
| `PENDO_API_KEY` | Product analytics |
| `SENTRY_DSN_BACKEND` | Error tracking |

### 2.4 — TLS strategy

Decide which TLS option you will use before configuring values. Full details are in [Reference: TLS configuration](#reference-tls-configuration).

| Option | Best for | Requires |
|---|---|---|
| cert-manager (recommended) | Any public-facing install | cert-manager installed, DNS resolving |
| Pre-create TLS secret | Bring-your-own certs | Your PEM files |
| Inline cert in values | Lab/testing only | Your PEM files (ends up in Helm history) |
| No TLS | Dev/testing only | Nothing |

If using cert-manager, install it now:

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait
```

Then create a `ClusterIssuer` for Let's Encrypt:

```yaml
# letsencrypt-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@mycompany.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
```

```bash
kubectl apply -f letsencrypt-issuer.yaml
```

---

## Phase 3 — Configure your values file

With your `.env.local` filled in, use it as a reference while editing your values file. Each variable in `.env.local` has a comment of the form `→ some.values.yaml.path` — those are the fields to set here.

```bash
cp charts/plextrac/examples/values-self-hosted.yaml my-values.yaml
```

Edit `my-values.yaml`. At minimum, set these fields using the values you gathered in Phase 2:

```yaml
global:
  ingress:
    host: plextrac.mycompany.com              # from Step 1.3
    tlsSecretName: plextrac-com-tls
    certManagerClusterIssuer: letsencrypt-prod  # or "" if not using cert-manager

secrets:
  mode: manual
  manual:
    createKubernetesSecrets: true
    generatedSecrets:
      application:
        stringData:
          ADMIN_EMAIL: ""                       # optional: admin notification email
      shared:
        stringData:
          CKEDITOR_SERVER_LICENSE_KEY: ""     # from Step 2.3 — leave blank to disable
          LAUNCH_DARKLY_SDK_KEY: ""
          PENDO_API_KEY: ""
          SENTRY_DSN_BACKEND: ""
      tls:
        enabled: false                        # set to true if providing cert inline
```

If your images require a pull secret, reference it under `global.imagePullSecrets`. This can be the secret created by the setup script in [Step 2.2](#22--docker-registry-credentials) (named `plextrac-registry-creds`), or any existing `kubernetes.io/dockerconfigjson` secret in the namespace — the name just has to match a secret that exists. If you ran the setup script, paste the snippet it printed instead of writing this by hand:

```yaml
global:
  imagePullSecrets:
    - name: plextrac-registry-creds      # must match the secret you created

secrets:
  manual:
    generatedSecrets:
      registryCredentials:
        enabled: true
        name: plextrac-registry-creds
        dockerconfigjson: '<paste your dockerconfigjson blob here>'
```

Preview the rendered output before installing to catch errors early:

```bash
helm template plextrac ./charts/plextrac -f my-values.yaml | less
```

---

## Phase 4 — Install

```bash
helm upgrade --install plextrac ./charts/plextrac \
  --namespace plextrac \
  --create-namespace \
  -f my-values.yaml \
  --wait \
  --timeout 15m
```

`--wait` blocks until all pods are healthy or the timeout is reached. The first install runs the database migration inline (see below), which can take several minutes, so allow a generous `--timeout`. Check progress in another terminal:

```bash
kubectl -n plextrac get pods -w
```

**Startup order:** the core data services come up first (`plextracdb` → `postgres` → `redis` → `minio`). The `migrations-and-etl` Job runs as a normal release resource alongside them — it waits for Postgres, then migrates the database. `plextracapi` starts in parallel but uses a **startup probe**, so it is not marked Ready (and is not restarted) until the migration has completed and `/api/v2/health/full` passes. `bootstrap-minio` is a Helm **post-install hook**, so it runs after the main workloads are Ready.

> **If `--wait` does not complete:** check the migration Job and the pods. On a fresh install the API cannot become Ready until `migrations-and-etl` finishes, so a failed or stuck migration keeps the install waiting:
> ```bash
> kubectl -n plextrac get jobs
> kubectl -n plextrac logs job/migrations-and-etl-<revision> --tail=50
> kubectl -n plextrac get pods
> ```
> The usual causes are an image that cannot be pulled (`ImagePullBackOff` — check your registry and pull-secret name) or a data service that never became Ready. See [Troubleshooting](#troubleshooting).

### Uninstalling

```bash
# Check the release name first
helm list --namespace plextrac

# Uninstall
helm uninstall plextrac --namespace plextrac
```

> `helm uninstall` removes all Kubernetes resources created by the chart but **does not delete PersistentVolumeClaims**. Delete them manually if you want full cleanup:
> ```bash
> kubectl -n plextrac delete pvc --all
> ```

---

## Phase 5 — Verify

### Check release status

```bash
helm status plextrac -n plextrac
```

### Check pods

```bash
kubectl -n plextrac get pods
```

All pods should reach `Running` or `Completed` status.

### Check secrets were created

```bash
kubectl -n plextrac get secrets
```

You should see at minimum `application-secrets` and `shared-secrets`.

### Check ingress

```bash
kubectl -n plextrac get ingress
```

The `ADDRESS` field is populated once the ingress controller assigns an IP.

### Smoke test

```bash
curl -I https://plextrac.mycompany.com/api/v2/health/full
```

Expected: `HTTP/2 200`

---

## Reference: Secrets configuration

The chart supports three secrets modes. Set `secrets.mode` to choose one.

### Manual mode (default — recommended for self-hosted)

The chart auto-generates all required secrets on first install and preserves values on upgrade. You only need to provide values that cannot be auto-generated.

```yaml
secrets:
  mode: manual
  manual:
    createKubernetesSecrets: true
    generatedSecrets:
      application:
        stringData:
          ADMIN_EMAIL: ""   # optional
      shared:
        stringData:
          CKEDITOR_SERVER_LICENSE_KEY: "your-key"
```

**How auto-generation works:**
- On install: any required key not in `stringData` or `data` gets a random 40-character alphanumeric value
- On upgrade: Helm looks up the existing secret in the cluster and reuses its current value — passwords are never rotated automatically

**Static username/database defaults (matching the `docker-compose.yml` reference deployment):**

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

Any of these can be overridden by adding the key to `stringData`.

### External Secrets Operator mode

Use when ESO is installed and a `ClusterSecretStore` is connected to your secret backend.

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

## Reference: Storage configuration

The chart creates 7 PersistentVolumeClaims. All use a single StorageClass:

```yaml
storage:
  storageClassName: local-path   # default — K3s built-in provisioner
```

| Platform | Recommended StorageClass | Notes |
|---|---|---|
| K3s | `local-path` | Built-in, no change needed |
| GKE | `premium-rwo` | SSD-backed; use `standard-rwo` for HDD |
| AKS | `managed-premium` | SSD-backed; use `default` for HDD |
| EKS | `gp3` | Requires EBS CSI driver add-on |

Check what StorageClasses are available:

```bash
kubectl get storageclass
```

> **Important:** Set `storage.storageClassName` **before first install**. Changing it after the initial install does not migrate existing PVCs — PVCs are immutable after creation. Migration requires backing up data, deleting and recreating PVCs, and restoring.

> **This chart targets a single-node K3s cluster.** `plextracapi-pvc` is `ReadWriteOnce` and is shared by all `plextracapi` replicas (default 3) and the `migrations-and-etl` Job — which is fine when everything runs on one node. Multi-node is not a supported topology: a `ReadWriteOnce` volume attaches to a single node, so pods scheduled elsewhere would get stuck `FailedAttachVolume`. If you must run multi-node, switch these claims to a `ReadWriteMany`-capable StorageClass.

---

## Reference: TLS configuration

### Option A — cert-manager (recommended)

```yaml
global:
  ingress:
    host: plextrac.mycompany.com
    tlsSecretName: plextrac-com-tls
    certManagerClusterIssuer: letsencrypt-prod
```

### Option B — Pre-create the TLS secret

Create the secret before installing, then reference it by name:

```bash
kubectl -n plextrac create secret tls plextrac-com-tls \
  --cert=./fullchain.pem \
  --key=./privkey.pem
```

```yaml
global:
  ingress:
    tlsSecretName: plextrac-com-tls
secrets:
  manual:
    generatedSecrets:
      tls:
        enabled: false
```

### Option C — Inline certificate in values

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

> **Security note:** Certificates stored inline end up in Helm release history. Use cert-manager or pre-create the secret if this is a concern.

### Option D — No TLS (dev/testing only)

Leave `certManagerClusterIssuer` blank and `tls.enabled: false`.

---

## Reference: Image overrides

All images are configurable, and the chart can pull from **any Docker Registry HTTP API v2 or OCI-compliant registry** — Docker Hub, Harbor, GHCR, ECR/GCR/ACR, a self-hosted registry, or a pull-through mirror/proxy of one. PlexTrac's application images require credentials to pull (see [Using a private registry (imagePullSecrets)](#using-a-private-registry-imagepullsecrets)).

Each component's image is set independently as `images.<component>.repository` (the full path including the registry host) and `images.<component>.tag`. There is no single global registry switch today, so to move every image to your own registry or mirror you override each `repository` entry individually, as shown below.

### Pinning a specific version

```yaml
images:
  backend:
    tag: "2.28.0"
  nginx:
    tag: "2.28.0"
```

### Using a private registry mirror

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

Every Deployment, StatefulSet, and Job will pick up `global.imagePullSecrets` automatically. Three ways to provide the Secret:

#### Option 1 — Let the chart create the Secret (simplest)

```yaml
global:
  imagePullSecrets:
    - name: plextrac-registry-creds

secrets:
  manual:
    generatedSecrets:
      registryCredentials:
        enabled: true
        name: plextrac-registry-creds
        dockerconfigjson: '{"auths":{"registry.mycompany.com":{"username":"myuser","password":"mypassword","auth":"bXl1c2VyOm15cGFzc3dvcmQ="}}}'
```

Generate the `dockerconfigjson` blob (see [Phase 2.2](#22--docker-registry-credentials)).

#### Option 2 — Pre-create the secret with `kubectl`

```bash
kubectl -n plextrac create secret docker-registry my-registry-creds \
  --docker-server=registry.mycompany.com \
  --docker-username=myuser \
  --docker-password=mypassword
```

```yaml
global:
  imagePullSecrets:
    - name: my-registry-creds

secrets:
  manual:
    generatedSecrets:
      registryCredentials:
        enabled: false
```

#### Option 3 — Sync via External Secrets Operator

```yaml
secrets:
  mode: externalSecrets
  externalSecrets:
    registryCredentials:
      enabled: true
      targetSecretName: plextrac-registry-creds
      remoteKey: plextrac/registry-credentials

global:
  imagePullSecrets:
    - name: plextrac-registry-creds
```

---

## Reference: Replica counts

```yaml
replicaCounts:
  plextracapi: 3              # Core API — scale for throughput
  ckeditor: 3
  eventOrchestrator: 1        # Must be 1 — not horizontally scalable
  notificationEngine: 1       # Must be 1 — not horizontally scalable
  notificationSender: 1       # Must be 1 — not horizontally scalable
  integrationWorker: 1
  contextualScoringService: 1
  datalakeMaintainer: 0       # Disabled by default; set to 1 to enable
```

Minimal footprint for dev/staging:

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

## Reference: Overriding values

### Values file (`-f`)

```bash
helm upgrade --install plextrac ./charts/plextrac -f my-values.yaml
```

Layer multiple files (later files take precedence):

```bash
helm upgrade --install plextrac ./charts/plextrac \
  -f charts/plextrac/examples/values-self-hosted.yaml \
  -f my-overrides.yaml
```

### Inline `--set`

```bash
helm upgrade --install plextrac ./charts/plextrac \
  -f my-values.yaml \
  --set global.ingress.host=plextrac.mycompany.com \
  --set replicaCounts.plextracapi=5
```

### `--set-string`

Forces the value to be treated as a string:

```bash
--set-string images.plextracdb.tag=6.5.1
```

### Precedence order (lowest to highest)

1. `charts/plextrac/values.yaml` (chart defaults)
2. `-f file1.yaml`
3. `-f file2.yaml`
4. `--set` / `--set-string`

### Viewing current values on a live release

```bash
helm get values plextrac -n plextrac          # user-supplied values
helm get values plextrac -n plextrac --all    # all values including defaults
```

### Setting the ingress hostname after install

```bash
helm upgrade plextrac ./charts/plextrac \
  -f my-values.yaml \
  --set global.ingress.host=new-hostname.mycompany.com
```

Then restart the pods that read `CLIENT_DOMAIN_NAME`:

```bash
kubectl -n plextrac rollout restart deployment/plextracnginx deployment/plextracapi
```

---

## Upgrading

```bash
helm upgrade --install plextrac ./charts/plextrac \
  -f my-values.yaml \
  --namespace plextrac
```

**What happens during upgrade:**
- Deployments and StatefulSets with changed specs are updated with rolling-update strategy
- `migrations-and-etl` runs again as a fresh Job each upgrade — its name includes the release revision (e.g. `migrations-and-etl-2`), so migrations re-run before the new API pods report healthy and Helm prunes the previous revision's Job
- `bootstrap-minio` (a post-install hook) is deleted and recreated each release (required because `Job.spec.template` is immutable)
- Secrets in manual mode are preserved — the chart looks up existing values and reuses them for any key not explicitly set in `stringData`

**Preview changes before applying:**

```bash
helm diff upgrade plextrac ./charts/plextrac -f my-values.yaml -n plextrac
```

(`helm diff` is a plugin — install with `helm plugin install https://github.com/databus23/helm-diff`)

**Rolling back:**

```bash
helm history plextrac -n plextrac
helm rollback plextrac <revision-number> -n plextrac
```

> **Note:** a rollback creates a new, higher revision and runs a fresh `migrations-and-etl` Job for the chart version you roll back to — it re-runs that version's migrations *forward*, it does not reverse schema changes. Roll back the database from a backup separately if a migration is not backward-compatible.

---

## Troubleshooting

### `kubectl` fails with `permission denied` / only works with `sudo`

The K3s-bundled `kubectl` defaults to the root-only `/etc/rancher/k3s/k3s.yaml`. Copying it to `~/.kube/config` has no effect until you point `KUBECONFIG` at it:

```bash
export KUBECONFIG=$HOME/.kube/config
echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.bashrc
```

See [Step 1.1](#step-11--provision-a-kubernetes-cluster).

### Node never becomes `Ready` / does not register

K3s derives the node name from the host's hostname; a long cloud-assigned hostname can exceed the 63-character node-name limit. Set a short, durable hostname and restart K3s:

```bash
sudo hostnamectl set-hostname plextrac-node
sudo systemctl restart k3s
kubectl get nodes
```

Make the hostname durable so it survives reboots — see [Step 1.1](#step-11--provision-a-kubernetes-cluster).

### Install does not complete / `plextracapi` stuck not Ready

On a fresh install the `migrations-and-etl` Job migrates the database, and `plextracapi` will not pass its startup probe (so `--wait` will not finish) until that migration completes. If the install does not complete, check the migration Job first, then the pods:

```bash
kubectl -n plextrac get jobs
kubectl -n plextrac logs job/migrations-and-etl-<revision> --tail=50
kubectl -n plextrac get pods
kubectl -n plextrac describe pod <not-ready-pod>
```

Common causes: the migration Job is failing (database not reachable or wrong secrets — the API stays not Ready until it succeeds), an image that cannot be pulled (see the next entry), or a data service (`plextracdb`, `postgres`, `redis`) that is not Ready. `bootstrap-minio` is a post-install hook and only runs once the main workloads are Ready.

### `ImagePullBackOff` / `ErrImagePull`

The image path or the pull secret is wrong:

```bash
kubectl -n plextrac describe pod <pod> | grep -A5 Events
```

- Confirm each `images.<component>.repository` points at a registry you can reach (see [Reference: Image overrides](#reference-image-overrides)).
- Confirm the secret named in `global.imagePullSecrets` exists in the namespace and matches the name you created. The setup script creates `plextrac-registry-creds`; the name in your values file must match it exactly:
  ```bash
  kubectl -n plextrac get secret
  ```

### Pods stuck in `Pending`

Usually a PVC issue:

```bash
kubectl -n plextrac get pvc
kubectl -n plextrac describe pvc <pvc-name>
kubectl get storageclass
```

If the StorageClass doesn't exist, set `storage.storageClassName` to one that does. See [Reference: Storage configuration](#reference-storage-configuration).

### Pods stuck in `Init:Error` or `Init:CrashLoopBackOff`

```bash
kubectl -n plextrac logs <pod-name> -c <init-container-name>
```

### Pods stuck in `CrashLoopBackOff`

```bash
kubectl -n plextrac logs <pod-name> --previous
```

### `application-secrets` or `shared-secrets` not found

In manual mode with `createKubernetesSecrets: true`, secrets are created by the Helm release:

```bash
helm status plextrac -n plextrac
helm get manifest plextrac -n plextrac | grep "kind: Secret"
```

If using `createKubernetesSecrets: false`, you must create the secrets before installing.

### `admission webhook denied: snippet directives are disabled`

Your cluster's ingress-nginx has snippet annotations disabled. The chart does not use `configuration-snippet` annotations — if you see this, you may be on an older version of the chart. Update to the latest chart version.

If you need to enable snippets for other reasons:

```bash
kubectl patch configmap ingress-nginx-controller \
  -n ingress-nginx \
  --type merge \
  -p '{"data":{"allow-snippet-annotations":"true"}}'
```

### `Error: values don't meet the specifications of the schema`

```bash
helm lint ./charts/plextrac -f my-values.yaml
```

### Ingress not routing traffic

```bash
kubectl -n ingress-nginx get pods
kubectl -n plextrac get ingress
nslookup plextrac.mycompany.com
kubectl -n ingress-nginx logs -l app.kubernetes.io/name=ingress-nginx --tail=100
```

### PlexTrac API returns 502 Bad Gateway

nginx is up but cannot reach `plextracapi`. The API readiness probe is at `/api/v2/health/full` and fails if Couchbase, Redis, or Postgres are not ready, or if the `migrations-and-etl` Job has not yet migrated the database:

```bash
kubectl -n plextrac get pods -l app=plextracapi
kubectl -n plextrac logs deployment/plextracapi --tail=100
```

### Rendering templates locally for debugging

```bash
helm template plextrac ./charts/plextrac \
  -f my-values.yaml \
  --set global.ingress.host=plextrac.mycompany.com \
  > rendered.yaml

grep -A 50 "name: env-config" rendered.yaml
```
