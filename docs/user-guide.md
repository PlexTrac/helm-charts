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
13. [Reference: Synqly (optional)](#reference-synqly-optional)
14. [Reference: Keycloak (optional)](#reference-keycloak-optional)
15. [Reference: MCP (optional)](#reference-mcp-optional)
16. [Upgrading](#upgrading)
17. [Troubleshooting](#troubleshooting)

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
| migrations-and-etl | Job (release resource) | — |
| bootstrap-minio | Job (post-install hook) | — |

> `datalake-maintainer` ships **disabled** (0 replicas) by default — seeing it with no pods is expected and does not block startup. `migrations-and-etl` runs as a normal Job during install (its name includes the release revision, e.g. `migrations-and-etl-1`) and migrates the database before the API reports healthy. `bootstrap-minio` is a Helm **post-install/post-upgrade hook**, so it appears only *after* the main workloads are running. See [Phase 4](#phase-4--install).

**Optional components** — all **disabled by default**; deployed only when you enable them in your values file (1 replica each unless noted):

| Workload | Kind | Enabled by |
|---|---|---|
| synqly-embedded | Deployment | `synqly.enabled` |
| synqly-postgres | Deployment | `synqly.enabled` **and** `synqly.database.dedicated` |
| keycloak | Deployment | `keycloak.enabled` |
| keycloak-postgres | Deployment | `keycloak.enabled` **and** `keycloak.database.dedicated` |
| keycloak-realm-setup | Job | `keycloak.enabled` |
| mcp | Deployment | `mcp.enabled` (requires `keycloak.enabled`) |

> The dedicated-Postgres deployments (`synqly-postgres`, `keycloak-postgres`) appear only when you set the respective `database.dedicated: true`; otherwise those components share the bundled `postgres`. `keycloak-realm-setup` is a revision-keyed Job that re-runs (idempotently) on every upgrade to provision the Keycloak realm. The resource estimate below covers the core stack only — enabling these adds to it. See the reference sections for [Synqly](#reference-synqly-optional), [Keycloak](#reference-keycloak-optional), and [MCP](#reference-mcp-optional).

**Minimum cluster resources:** ~1.6 CPU cores and ~4.3 GiB RAM in requests at default replica counts; ~41 GiB persistent storage.

### Software requirements

| Tool | Minimum version |
|---|---|
| Kubernetes | 1.25 |
| Helm | 3.10 |
| NGINX Ingress Controller | any current release |
| `jq` | any — **required** by `scripts/setup-registry-credentials.sh` (Phase 2.2) |

> All Ingress resources use `ingressClassName: nginx`. Other ingress controllers are not supported without changes to annotations and ingress class values.

> `jq` is not preinstalled on fresh Ubuntu/Debian/RHEL. Install it before Phase 2.2: `apt install jq` / `dnf install jq` / `brew install jq`.

### Install Helm

The chart requires Helm 3.10 or newer. If Helm is not already on the machine you run installs from, install it before Phase 1. (`kubectl` is bundled with K3s; on managed clusters install it through your provider's flow.)

```bash
# Official installer (Linux/macOS). The installer pulls the latest Helm by default;
# pin DESIRED_VERSION to a 3.10+ release you have tested for reproducible installs.
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
  | DESIRED_VERSION=v3.16.4 bash

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

- **Run the application install as a dedicated non-root user**, not as `root`. The K3s installer below is the only step that requires root — run it from your normal admin account. Everything after it (`kubectl`, `helm`, the chart install) needs no privileges at all, because the installer's `--write-kubeconfig-mode 644` makes the kubeconfig readable by any local user. The dedicated user therefore needs no `sudo` access. Create it now, run the K3s install below from your admin account, then switch:
  ```bash
  sudo useradd -m -s /bin/bash plextrac
  # ... run the K3s install below from your admin account, then:
  sudo su plextrac
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
  ```
  Run every `kubectl` and `helm` command from here on as this user.
- **Give K3s an explicit node name** instead of letting it use the OS hostname. K3s derives the node name from the hostname, and a long or non-RFC-1123 cloud hostname (e.g. a GCP/AWS instance name) can exceed the 63-character limit and stop the node from registering. Rather than fighting the cloud agent that rewrites the hostname on every boot, pass `--node-name` to the installer — it is baked into the K3s systemd unit and reused on every start, so the node name survives reboots and hostname changes. The install below derives a valid name from the current hostname and pins it **before** K3s first registers the node.

```bash
# Derive a valid K3s node name from the hostname:
# lowercase, non-alphanumerics -> '-', collapse repeats, trim to the 63-char limit.
NODE_NAME=$(hostname -s | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' \
  | sed -E 's/-+/-/g; s/^-+//; s/-+$//' | cut -c1-63 | sed -E 's/-+$//')
[ -z "$NODE_NAME" ] && NODE_NAME=plextrac-node
echo "K3s node name: $NODE_NAME"

# Install K3s in the SAME shell so $NODE_NAME is set. These args are baked into the K3s
# systemd unit and reused on every start:
#   --node-name             pins the node name, independent of the long/reset-on-boot hostname
#   --disable traefik       PlexTrac uses NGINX; running both conflicts
#   --write-kubeconfig-mode makes /etc/rancher/k3s/k3s.yaml readable by your non-root user
#                           (644 = readable by any local user on this host; fine for a
#                           dedicated single-node appliance)
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644 --node-name $NODE_NAME" sh -

# Point kubectl/helm at the kubeconfig K3s wrote. With --write-kubeconfig-mode above
# it is readable by your user — no sudo, no copy, and no chown needed.
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc

# Confirm the node is Ready and registered under your chosen name (no sudo needed)
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

On a managed cluster (GKE/AKS/EKS) the `ingress-nginx-controller` Service gets a real cloud `EXTERNAL-IP` once the LoadBalancer is provisioned — note it for DNS in the next step.

> **On K3s (single VM), the `EXTERNAL-IP` shown is the node's own IP**, not a public address. K3s's built-in load balancer (ServiceLB) assigns the node address, and on a cloud VM that is the **internal/private** IP — the public IP is attached by the provider via 1:1 NAT and is not visible to the OS. Do **not** use that address for public DNS.

Instead, use the machine's **public IP** (from your cloud provider) and open inbound `tcp:443` (the application) and `tcp:80`. Port 80 is used **only** by Let's Encrypt for the HTTP-01 certificate challenge — nothing else serves on it, so it is needed only with the `letsencrypt` / `letsencrypt-staging` issuer. Note that IP — you need it for DNS in the next step.

---

### Step 1.3 — Create a DNS record

Create an A record pointing your chosen hostname to the ingress LoadBalancer IP:

```
plextrac.mycompany.com  →  <your ingress IP from Step 1.2>
```

> Use the IP Step 1.2 told you to use: on **K3s / single VM** that's the machine's **public** IP (the `EXTERNAL-IP` from `kubectl get svc` is the node's private address); on **GKE/AKS/EKS** it's the LoadBalancer `EXTERNAL-IP`.

For local/lab installs without DNS, add an entry to `/etc/hosts` on any machine that needs to reach PlexTrac:

```
<your ingress IP from Step 1.2>  plextrac.mycompany.com
```

> DNS propagation can take minutes to hours depending on your provider. You can proceed with configuration while waiting, but the final smoke test requires DNS to resolve.

---

## Phase 2 — Gather credentials and secrets

**Do not run `helm install` until you have completed this phase.**

Copy `.env.example` from the repo root and fill in your registry credentials:

```bash
cp .env.example .env.local
# Edit .env.local — set your DOCKER_* (and CKEDITOR_DOCKER_*, if using CKEditor) credentials
```

`.env.local` is **not** read by Helm. It holds only your image-registry credentials, consumed solely by `scripts/setup-registry-credentials.sh` (Step 2.2). Everything else about the deployment — domain, TLS, storage class, secrets, optional integrations — is configured directly in your values file in [Phase 3](#phase-3--configure-your-values-file), using one of the `charts/plextrac/examples/values-*.yaml` files as your starting point.

### 2.1 — Required: domain

| What | Where it goes |
|---|---|
| Your hostname (from Step 1.3) | `global.ingress.host` |
| Admin notification email (optional) | `secrets.manual.generatedSecrets.application.stringData.ADMIN_EMAIL` |

### 2.2 — Docker registry credentials

PlexTrac images require authentication. Fill in your registry credentials in `.env.local`, then run the setup script — it creates the Kubernetes pull secrets and prints the `my-values.yaml` snippet to paste in. **The script requires `jq`** and exits immediately if it is missing (`apt install jq` / `dnf install jq` / `brew install jq`).

```bash
# Fill in DOCKER_REGISTRY, DOCKER_USERNAME, DOCKER_PASSWORD in .env.local first
./scripts/setup-registry-credentials.sh
```

Options:

```bash
./scripts/setup-registry-credentials.sh --namespace plextrac     # default namespace
./scripts/setup-registry-credentials.sh --release-name plextrac  # must match the helm release name (default: plextrac)
./scripts/setup-registry-credentials.sh --dry-run                # preview without creating
./scripts/setup-registry-credentials.sh --env-file /path/to/other.env
```

The script creates `internal-registry-creds` (and `ckeditor-registry-creds` if CKEditor credentials are set), then prints the exact `global.imagePullSecrets` and `registryCredentials` block to add to `my-values.yaml`.

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
| cert-manager — Let's Encrypt (`letsencrypt`) | Public-facing prod/test | cert-manager installed; public DNS pointing at your IP; inbound `:80` reachable |
| cert-manager — self-signed (`selfSigned`) | Local machine / local k3s / dev | cert-manager installed (browser warnings expected) |
| Pre-create TLS secret | Bring-your-own or internal-CA certs | Your PEM files |
| Inline cert in values | Lab/testing only | Your PEM files (ends up in Helm history) |
| No TLS | Dev/testing only | Nothing |

If using cert-manager (either option), install it now:

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true \
  --wait
```

The chart creates the Issuer for you — you do **not** need to hand-write a `ClusterIssuer`. Just set `global.ingress.certManager.issuer` in [Phase 3](#phase-3--configure-your-values-file):

- `selfSigned` — local/dev; no DNS or public reachability needed (cert is untrusted, so browsers warn).
- `letsencrypt` — public-facing; trusted cert. Also set `certManager.email`. Needs public DNS at your IP and inbound `:80`.
- `letsencrypt-staging` — same as `letsencrypt` but against Let's Encrypt **staging**. Use this first when testing: LE production has strict rate limits, and repeated failed HTTP-01 attempts can lock you out for hours. Staging certs are untrusted but prove the flow works; switch to `letsencrypt` once it succeeds.

To use an issuer you manage yourself instead (DNS-01, a private CA, Vault, etc.), leave `certManager.issuer: ""` and set `certManagerClusterIssuer` to its name — see [Reference: TLS configuration](#reference-tls-configuration).

---

## Phase 3 — Configure your values file

Copy the example values file closest to your setup and edit it — this is where the domain, TLS, storage class, secrets, and any optional integrations are configured (the registry credentials from Phase 2 are handled by the setup script and don't go here).

```bash
cp charts/plextrac/examples/values-self-hosted.yaml my-values.yaml
```

Edit `my-values.yaml`. At minimum, set these fields using the values you gathered in Phase 2:

```yaml
global:
  ingress:
    host: plextrac.mycompany.com              # from Step 1.3
    tlsSecretName: internal-tls
    certManager:
      issuer: letsencrypt          # public install. Use "selfSigned" for local, or "" to disable / BYO
      email: admin@mycompany.com   # required for letsencrypt / letsencrypt-staging

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

If your images require a pull secret, reference it under `global.imagePullSecrets`. This can be the secret created by the setup script in [Step 2.2](#22--docker-registry-credentials) (named `internal-registry-creds`), or any existing `kubernetes.io/dockerconfigjson` secret in the namespace — the name just has to match a secret that exists. If you ran the setup script, paste the snippet it printed instead of writing this by hand:

```yaml
global:
  imagePullSecrets:
    - name: internal-registry-creds      # must match the secret you created

secrets:
  manual:
    generatedSecrets:
      registryCredentials:
        enabled: true
        name: internal-registry-creds
        dockerconfigjson: '<paste your dockerconfigjson blob here>'
```

If you pull PlexTrac's images from your own registry or a mirror rather than the defaults, set the registry **before** installing — one value re-homes every component except `ckeditor` (which keeps its own registry):

```yaml
global:
  image:
    registry: registry.mycompany.com   # your registry/mirror; applied to all images except ckeditor
```

The pull secret in `global.imagePullSecrets` (above) must grant access to whatever registry you point at. To mirror CKEditor too, or to override a single component, see [Reference: Image overrides](#reference-image-overrides).

To run the optional in-cluster Synqly integration service, enable it here (disabled by default):

```yaml
synqly:
  enabled: true
  admin:
    username: you@example.com   # REQUIRED — must be an email address
  database:
    dedicated: false            # reuse the bundled Postgres; set true for a dedicated one
```

`admin.username` is **required** when `synqly.enabled: true` and must be an email address. In the default `manual` secrets mode the chart fails fast — even at `helm template` — if it is missing or not an email, so the preview/install below will abort until you set it. Synqly runs internal-only (no ingress) and PlexTrac is wired to it automatically. Its key storage is non-production by default — see [Reference: Synqly](#reference-synqly-optional).

To run the optional in-cluster Keycloak (OIDC/SSO broker), enable it and set a browser-facing auth hostname (disabled by default):

```yaml
keycloak:
  enabled: true
  host: auth.mycompany.com    # REQUIRED — browser-facing auth hostname (its own DNS + TLS)
  certManager:
    issuer: letsencrypt       # or selfSigned / letsencrypt-staging; "" for BYO or a pre-created keycloak-tls
    email: admin@mycompany.com
  database:
    dedicated: false          # reuse the bundled Postgres; set true for a dedicated one
```

Unlike Synqly, Keycloak is **browser-facing** (SSO login redirects), so it gets its own ingress + `keycloak-tls`. See [Reference: Keycloak](#reference-keycloak-optional).

Preview the rendered output before installing to catch errors early:

```bash
helm template plextrac ./charts/plextrac -f my-values.yaml | less
```

---

## Phase 4 — Install

```bash
helm upgrade --install plextrac ./charts/plextrac \
  --namespace plextrac \
  -f my-values.yaml \
  --wait \
  --timeout 15m
```

**Namespace:** `--create-namespace` is intentionally omitted. The setup script in [Step 2.2](#22--docker-registry-credentials) already created the `plextrac` namespace and stamped it with Helm ownership labels, and the chart's `global.createNamespace: true` (default) declares the namespace as a release resource that adopts it. If you skip the setup script or create the namespace another way (e.g. plain `kubectl create namespace`), that adoption fails with `invalid ownership metadata`; in that case either let the script create it, or set `global.createNamespace: false` and create the namespace yourself before installing.

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

All pods should reach `Running` with full readiness (e.g. `plextracapi` shows `1/1`, not just `Running`). On a **fresh install `plextracapi` can take several minutes to become Ready** — its startup probe holds it un-Ready (up to ~10 min) until the database migration finishes, so `Running` but `0/1` early on is expected, not a failure.

### Check the database migration completed

```bash
kubectl -n plextrac get jobs
kubectl -n plextrac logs job/migrations-and-etl-<revision> --tail=20   # <revision> = release revision (e.g. -1 on first install)
```

`migrations-and-etl-<revision>` should show `COMPLETIONS 1/1`. This is the gating, most failure-prone resource — until it completes, `plextracapi` never goes Ready.

### Check secrets were created

```bash
kubectl -n plextrac get secrets
```

You should see at minimum `application-secrets` and `shared-secrets` (in `manual` mode).

### Check ingress

```bash
kubectl -n plextrac get ingress
```

The `ADDRESS` field is populated once the ingress controller assigns an IP.

### Smoke test

Confirm the app is healthy **from inside the cluster** first (independent of DNS/TLS), then test the public endpoint:

```bash
# In-cluster — isolates app health from ingress/DNS/TLS
kubectl -n plextrac port-forward deploy/plextracapi 4350:4350 &
curl -s http://localhost:4350/api/v2/health/full; kill %1

# Public endpoint — requires DNS to resolve and TLS to be valid
curl -I https://plextrac.mycompany.com/api/v2/health/full
```

Expected: the in-cluster check returns a healthy response and the public check returns `HTTP/2 200`. If the in-cluster check is healthy but the public one fails, the problem is ingress/DNS/TLS, not the app — see [Troubleshooting](#troubleshooting).

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

**How auto-generation works (manual mode only):**
- On install: any required key not in `stringData` or `data` gets a random 32-character alphanumeric value (20 characters for `CLOUD_STORAGE_ACCESS_KEY`).
- On upgrade: Helm looks up the existing in-cluster secret and reuses its current value — passwords are never rotated automatically.
- **Caveat:** preservation relies on a live-cluster `lookup`, so it only works for a real `helm upgrade` against the cluster. `helm template`, `--dry-run`, or CI without cluster access cannot see the existing secret and will **regenerate** every auto-generated value in the rendered output (rotating DB/Redis/JWT/MinIO credentials). Don't pipe `helm template` output straight to `kubectl apply` for an existing release.
- This auto-generation/preservation applies to `manual` mode only — in `externalSecrets`/`csi` modes the chart does **not** generate secrets (see those sections).

**Static username/database defaults (matching the `docker-compose.yml` reference deployment):**

| Key | Default |
|---|---|
| `CB_ADMIN_USER` | `ptadminuser` |
| `CB_API_USER` | `ptapiuser` |
| `CB_BACKUP_USER` | `ptbackupuser` |
| `CB_BUCKET` | `reportMe` |
| `POSTGRES_USER` | `internalonly` |
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

> **Required keys:** in ESO mode the chart does **not** generate secrets — your secret store must already contain the full `application-secrets` key set (all keys) **and** the `shared-secrets` keys before install, or pods crash-loop on startup. The authoritative key contract is `secrets.manual.requiredKeys` in `charts/plextrac/values.yaml` (see also [docs/runbooks/secrets-modes.md](runbooks/secrets-modes.md)).

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

> **Required keys:** like ESO mode, CSI mode does **not** generate secrets — your provider store must contain the full `application-secrets` and `shared-secrets` key sets before install. The authoritative key contract is `secrets.manual.requiredKeys` in `charts/plextrac/values.yaml` (see also [docs/runbooks/secrets-modes.md](runbooks/secrets-modes.md)).

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

The chart creates a namespaced `Issuer` for you and wires it to the ingress. Pick it with `global.ingress.certManager.issuer`:

```yaml
global:
  ingress:
    host: plextrac.mycompany.com
    tlsSecretName: internal-tls
    certManager:
      # selfSigned          -> local/dev (untrusted; no DNS or public reachability needed)
      # letsencrypt         -> public-facing; trusted cert via ACME HTTP-01
      # letsencrypt-staging -> public-facing; LE staging (untrusted, rate-limit-safe for testing)
      issuer: letsencrypt
      email: admin@mycompany.com   # required for letsencrypt / letsencrypt-staging
```

`letsencrypt`/`letsencrypt-staging` use the ACME **HTTP-01** challenge, so your host must resolve publicly to the ingress IP with inbound `:80` reachable. For internal hosts that can't meet that, use `selfSigned` (or Option B with an internal-CA cert).

**Bring your own issuer:** leave `certManager.issuer: ""` and point `certManagerClusterIssuer` at an `Issuer`/`ClusterIssuer` you created yourself — any solver (DNS-01, a private CA, Vault, etc.):

```yaml
global:
  ingress:
    certManager:
      issuer: ""
    certManagerClusterIssuer: my-clusterissuer
```

### Option B — Pre-create the TLS secret

Create the secret before installing, then reference it by name:

```bash
kubectl -n plextrac create secret tls internal-tls \
  --cert=./fullchain.pem \
  --key=./privkey.pem
```

```yaml
global:
  ingress:
    tlsSecretName: internal-tls
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
        name: internal-tls
        crt: |
          -----BEGIN CERTIFICATE-----
          ...
        key: |
          -----BEGIN PRIVATE KEY-----
          ...
```

> When `tls.enabled: true`, **both `crt` and `key` are required** — the chart aborts the install (and `helm template`) if either is empty.
>
> **Security note:** Certificates stored inline end up in Helm release history. Use cert-manager or pre-create the secret if this is a concern.

### Option E — TLS via External Secrets (ESO)

In `externalSecrets` mode, enable `secrets.externalSecrets.tls` and point its `remoteKey` at the certificate in your store. The remote value **must be a PKCS#12 bundle** — the chart converts it to `tls.crt`/`tls.key`. A PEM payload yields a broken/empty TLS secret. See [docs/runbooks/secrets-modes.md](runbooks/secrets-modes.md).

### Option D — No managed certificate (dev/testing only)

> **The chart does not support true plaintext-only HTTP today.** The ingress always renders a `tls:` block referencing `global.ingress.tlsSecretName`, regardless of these settings.

Leave `certManager.issuer` and `certManagerClusterIssuer` blank and set `tls.enabled: false`. No TLS secret is created, so **ingress-nginx serves its own default self-signed certificate** for the host (browsers warn; there is no plaintext path). Use Option A/B/C/E for a real cert — this is only for throwaway dev where a self-signed warning is acceptable.

---

## Reference: Image overrides

All images are configurable, and the chart can pull from **any Docker Registry HTTP API v2 or OCI-compliant registry** — Docker Hub, Harbor, GHCR, ECR/GCR/ACR, a self-hosted registry, or a pull-through mirror/proxy of one. PlexTrac's application images require credentials to pull (see [Using a private registry (imagePullSecrets)](#using-a-private-registry-imagepullsecrets)).

Each component image renders as `<registry>/<repository>:<tag>`. The `<registry>` is, in order: the component's own `images.<component>.registry` if set; otherwise `global.image.registry`; otherwise nothing (the `repository` is used as-is, exactly as the defaults ship). So you can re-home every image with one value, override a single component, or leave the defaults alone.

> **`ckeditor` is pinned to its own registry** (`images.ckeditor.registry: docker.cke-cs.com`) and uses separate pull credentials, so `global.image.registry` does **not** move it. To mirror CKEditor too, set `images.ckeditor.registry` explicitly (see below).

### Pinning a specific version

```yaml
images:
  backend:
    tag: "2.28.0"
  nginx:
    tag: "2.28.0"
```

### Re-home all images to one registry

Point every component except `ckeditor` at your registry or mirror with a single value:

```yaml
global:
  image:
    registry: registry.mycompany.com
```

This renders `registry.mycompany.com/plextrac/plextracapi:stable`, `registry.mycompany.com/redis:8.4.0-alpine`, and so on, while `ckeditor` stays on `docker.cke-cs.com/cs`.

### Override a single component's registry

Set `images.<component>.registry` to override the global value for one component — this is also how you re-home `ckeditor`. Keep `repository` as the path **without** the host:

```yaml
global:
  image:
    registry: registry.mycompany.com   # all other components
images:
  ckeditor:
    registry: registry.mycompany.com   # mirror CKEditor here too
    repository: cke-cs/cs
    tag: latest
```

You can also leave `global.image.registry` empty and put a full path (host included) directly in a component's `repository` — that still works for any component with no `registry` value.

### Using a private registry (imagePullSecrets)

Every Deployment, StatefulSet, and Job will pick up `global.imagePullSecrets` automatically. Three ways to provide the Secret:

#### Option 1 — Let the chart create the Secret (simplest)

```yaml
global:
  imagePullSecrets:
    - name: internal-registry-creds

secrets:
  manual:
    generatedSecrets:
      registryCredentials:
        enabled: true
        name: internal-registry-creds
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
      targetSecretName: internal-registry-creds
      remoteKey: plextrac/registry-credentials

global:
  imagePullSecrets:
    - name: internal-registry-creds
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

## Reference: Synqly (optional)

Synqly Embedded is an optional in-cluster integration service, disabled by default. When enabled, the chart deploys it internally (ClusterIP only, no ingress) and points PlexTrac's `SYNQLY_EMBEDDED_*` variables at it automatically.

```yaml
synqly:
  enabled: true
  organizationID: plextrac          # slug only: [a-z0-9_-.], no spaces or "@"
  organizationFullName: PlexTrac
  admin:
    username: you@example.com       # REQUIRED: Synqly's org admin must be an email address
  database:
    dedicated: false          # false = reuse the bundled Postgres; true = chart deploys a dedicated one
```

- **Admin & org name:** `organizationID` must be a slug (`[a-z0-9_-.]`), and `admin.username` must be an **email address** — Synqly rejects a non-email admin and a non-slug org name. In `manual` mode the chart fails fast at install if `admin.username` isn't an email. In `externalSecrets`/`csi` modes the chart does **not** validate it and does **not** create `synqly-admin`/`synqly-root-token` — you provide those secrets yourself, and a non-email admin will instead surface as the Synqly pod failing to start.
- **Key management:** no external KMS is configured, so Synqly uses **AEAD** and stores its encryption keys in the database. Synqly documents this as **non-production only** (keys sit beside the data they encrypt). For production key separation, supply an external issuer/KMS Synqly supports (e.g. HashiCorp Vault Transit) via your own values.
- **Database:** with `dedicated: false`, an init step creates a `synqly` database in the bundled Postgres and Synqly connects with the bundled credentials. With `dedicated: true`, the chart deploys a separate Postgres (`synqly-postgres` + PVC) and generates its own credentials — no further config needed.
- **Secrets:** in `manual` mode the chart generates `synqly-root-token` and `synqly-admin` (and `synqly-db` when dedicated), preserved across upgrades. In `externalSecrets`/`csi` modes, provide those secrets yourself.
- **Images:** `images.synqly` defaults to `quay.io/synqly/embedded` (override `images.synqly.registry` for your quay proxy/mirror); pulls use `synqly.imagePullSecrets` (default `internal-registry-creds`).
- **Resources:** defaults are sized small for testing; raise `resources.synqly` for real workloads.

---

## Reference: Keycloak (optional)

Keycloak is an optional in-cluster **OIDC/SSO identity broker**, disabled by default and independent of Synqly. When enabled the chart deploys a Keycloak dedicated to this instance and wires PlexTrac's `KEYCLOAK_*` variables to it.

```yaml
keycloak:
  enabled: true
  host: auth.mycompany.com    # REQUIRED — browser-facing auth hostname
  admin:
    username: admin@mycompany.com
  certManager:
    issuer: letsencrypt       # selfSigned | letsencrypt | letsencrypt-staging | "" (BYO / pre-created)
    email: admin@mycompany.com
  # certManagerClusterIssuer: my-issuer   # BYO issuer (when certManager.issuer is "")
  database:
    dedicated: false
```

- **Browser-facing:** unlike Synqly, Keycloak needs an externally reachable URL for SSO login redirects, so the chart creates its **own ingress** at `keycloak.host` with a `keycloak-tls` secret. `keycloak.host` is required — the chart fails fast without it.
- **DNS:** `keycloak.host` must resolve to the **same ingress endpoint as the main app host** (on single-node k3s, the node's IP). The ingress-nginx controller routes to Keycloak by `Host` header — traffic does not pass through the app's `plextracnginx`. If you use cert-manager with an ACME (letsencrypt) issuer, this DNS record must exist and be publicly resolvable *before* install, or the HTTP-01 challenge for `keycloak-tls` will fail.
- **TLS:** three ways to provide `keycloak-tls` — cert-manager (`certManager.issuer`), bring-your-own issuer (`certManagerClusterIssuer`), or a pre-created secret (leave both blank).
- **Realm/OIDC provisioning is external:** the chart does **not** create realms/clients. It generates `keycloak-oidc-secret` (broker client secret, tenant-realm-admin secret, RSA key); your **realm-provisioning migration Job** consumes it to configure the Keycloak clients, and the PlexTrac app reads the same secret — so all three stay in sync.
- **Database:** `dedicated: false` creates a `keycloak` DB + `keycloak_admin` user in the bundled Postgres; `dedicated: true` deploys a separate `keycloak-postgres`.
- **Secrets:** in `manual` mode the chart generates `keycloak-db-secret`, `keycloak-admin-secret`, and `keycloak-oidc-secret`, preserved across upgrades. In `externalSecrets`/`csi` modes, provide them yourself.
- **Images:** `images.keycloak` (the Keycloak server); the one-shot realm-setup Job uses `images.keycloakSetup` if set, otherwise falls back to `images.backend` (which already contains the CLI) — set `keycloakSetup` only to point at a dedicated lean build. All registry-agnostic (override `.registry` for your mirror); pulls use `global.imagePullSecrets` (add `keycloak.imagePullSecrets` for keycloak-only secrets — the two are merged and deduped).

---

## Reference: MCP (optional)

MCP is an optional in-cluster **Model Context Protocol server**, disabled by default. It **requires Keycloak** — it authenticates via Keycloak and reuses the tenant-realm-admin client credential — so the chart fails fast if `mcp.enabled: true` while `keycloak.enabled: false`.

```yaml
mcp:
  enabled: true
otel:
  enabled: false             # on-prem default; set true + exporterEndpoint for an OTLP collector
keycloak:
  enabled: true              # required
  host: auth.mycompany.com
```

- **Requires Keycloak:** MCP consumes `keycloak-oidc-secret` (the `tenantRealmAdminClientSecret`) and the `KEYCLOAK_*_BASE_URL` values, so `keycloak.enabled` must be `true`. The chart fails fast otherwise.
- **Routing:** unlike Keycloak, MCP is **not** a separate hostname — it's served at the path **`/mcp`** on your main app host (`global.ingress.host`) and shares that host's TLS certificate (provided by the app's ingress). No extra DNS record or cert is needed.
- **Networking:** ClusterIP `mcp` on port 8000; the ingress adds CORS and long-lived-connection timeouts for MCP clients, and blocks the `/mcp/metrics` path from the public route.
- **OpenTelemetry:** off by default (an on-prem cluster has no collector). To enable tracing, set `mcp.otel.enabled: true` and `mcp.otel.exporterEndpoint` to your OTLP gRPC receiver.
- **Secrets:** reuses existing chart secrets — `JWT_KEY` (`application-secrets`), `LAUNCH_DARKLY_SDK_KEY` (`shared-secrets`), and the Keycloak client secret (`keycloak-oidc-secret`). Nothing new to provide.
- **Images:** `images.mcp` (registry-agnostic, override `.registry` for your mirror); pulls use `global.imagePullSecrets` (add `mcp.imagePullSecrets` for mcp-only secrets — the two are merged and deduped).

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

By default K3s writes `/etc/rancher/k3s/k3s.yaml` as root-only (mode 0600), so a non-root user cannot read it. Install K3s with `--write-kubeconfig-mode 644` (see [Step 1.1](#step-11--provision-a-kubernetes-cluster)) so it is created readable, then point `KUBECONFIG` at it — no `sudo` needed:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
```

If you already installed without that flag, either reinstall, or copy it once with `sudo`: `sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown $(id -u):$(id -g) ~/.kube/config`, then `export KUBECONFIG=$HOME/.kube/config`.

### Node never becomes `Ready` / does not register

K3s derives the node name from the host's hostname; a long or non-RFC-1123 cloud hostname can exceed the 63-character limit and block registration. Pin an explicit `node-name` rather than relying on the hostname. On a fresh single-node box the simplest fix is a clean reinstall with a valid node name (see [Step 1.1](#step-11--provision-a-kubernetes-cluster)):

```bash
/usr/local/bin/k3s-uninstall.sh
# then re-run the Step 1.1 install, which passes --node-name to the installer
```

Changing `node-name` on an already-registered node triggers a `Node password rejected` error and leaves a stale node object behind, which is why a clean reinstall is simplest before any workloads exist.

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
- Confirm the secret named in `global.imagePullSecrets` exists in the namespace and matches the name you created. The setup script creates `internal-registry-creds`; the name in your values file must match it exactly:
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
