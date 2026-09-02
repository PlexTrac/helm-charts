# PlexTrac K3s Installation Guide

## Prerequisites

Update your system packages:

```shell
sudo apt update
```

## 1. Install K3s

Install K3s with Traefik disabled (PlexTrac uses NGINX) and make kubeconfig readable without sudo:

```shell
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644" sh -
```

Configure kubectl to use the kubeconfig without sudo:

```shell
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc
```

## 2. Install Helm

Install Helm from the official script:

```shell
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

Verify the installation:

```shell
helm version
```

## 3. Install NGINX Ingress Controller

Add the NGINX Helm repository and install the ingress controller:

```shell
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace --wait
```

Get the ingress IP (create a DNS record or `/etc/hosts` entry with this IP):

```shell
kubectl -n ingress-nginx get svc ingress-nginx-controller
```

## 4. Clone PlexTrac Helm Charts

```shell
git clone https://github.com/PlexTrac/helm-charts.git
cd helm-charts
```

## 5. Configure Registry Credentials

Copy the example environment file:

```shell
cp .env.example .env.local
```

Edit `.env.local` and set the following required variables: 

- `DOCKER_REGISTRY`
- `DOCKER_USERNAME`
- `DOCKER_PASSWORD`
- `CKEDITOR_DOCKER_SERVER`
- `CKEDITOR_DOCKER_USERNAME`
- `CKEDITOR_DOCKER_PASSWORD`

Create Kubernetes registry secrets:

```shell
./scripts/setup-registry-credentials.sh
```

This will output a `my-values.yaml` snippet that you'll use in the next step.

## 6. Configure Values File

Copy the example values file:

```shell
cp charts/plextrac/examples/values-self-hosted.yaml my-values.yaml
```

Edit `my-values.yaml` and set the following, ensuring you uncomment the `imagePullSecrets` on lines 10-12, set the domain on line 16, and input the CKE License Key on line 35:

```yaml
# Self-hosted PlexTrac deployment using manual secrets (recommended for most customers)
# Secrets are auto-generated on first install and preserved on upgrade.
# Set global.ingress.host to your domain before installing.

global:
  namespace: plextrac
  createNamespace: true
  # Run scripts/setup-registry-credentials.sh to create the image pull secret, then
  # reference it here. Leave empty only if all images are from public registries.
  imagePullSecrets:
    - name: plextrac-registry-creds
    - name: ckeditor-registry-creds   # uncomment if CKEditor credentials were provided
  image:
      registry: "registry.mycompany.com"   # set to your registry/mirror to re-home all images except ckeditor
  ingress:
    host: plextrac.local   # Required: set to your actual domain
    tlsSecretName: plextrac-com-tls
    # TLS via cert-manager (cert-manager must be installed). Pick an issuer:
    #   letsencrypt / letsencrypt-staging = public-facing (also set email); selfSigned = local/dev
    certManager:
      issuer: ""     # "letsencrypt" | "letsencrypt-staging" | "selfSigned" | "" (none / bring-your-own)
      email: ""      # required for letsencrypt / letsencrypt-staging
    certManagerClusterIssuer: ""   # used only when certManager.issuer is "" (your own issuer's name)

secrets:
  mode: manual
  manual:
    createKubernetesSecrets: true
    generatedSecrets:
      application:
        stringData:
          ADMIN_EMAIL: ""   # Optional: admin notification email
      shared:
        stringData:
          CKEDITOR_SERVER_LICENSE_KEY: "Add Key"   # Required if using CKEditor; leave empty to disable
          LAUNCH_DARKLY_SDK_KEY: ""
          PENDO_API_KEY: ""
          SENTRY_DSN_BACKEND: ""
      tls:
        enabled: false   # Set to true and provide crt/key to manage TLS via Helm
        # crt: |
        #   -----BEGIN CERTIFICATE-----
        #   ...
        # key: |
        #   -----BEGIN PRIVATE KEY-----
        #   ...

images:
  backend:
    repository: plextrac/plextracapi
    tag: stable
  nginx:
    repository: plextrac/plextracnginx
    tag: stable
  ckeditor:
    # CKEditor carries its own registry, so global.image.registry does not apply.
    # Point this at your pull-through proxy if you mirror it.
    registry: docker.cke-cs.com
    repository: cs
    tag: latest
  plextracdb:
    repository: plextrac/plextracdb
    tag: 7.2.0
  postgres:
    repository: plextrac/plextracpostgres
    tag: stable
  redis:
    repository: redis
    tag: 8.4.0-alpine
  redisExporter:
    repository: oliver006/redis_exporter
    tag: latest
  minio:
    repository: plextrac/minio
    tag: latest
  minioBootstrap:
    repository: plextrac/plextrac-minio-bootstrap
    tag: stable
  synqly:
    # On quay.io by default — set registry to your quay proxy/mirror to override.
    registry: quay.io
    repository: synqly/embedded
    tag: embedded-2026.06.19
  keycloak:
    repository: plextrac/plextrac-keycloak
    tag: stable
  # keycloakSetup:                            # optional; defaults to the backend image (contains the CLI). Set for a lean build.
  #   repository: plextrac/plextracapi-keycloak-setup
  #   tag: stable
  mcp:
    repository: plextrac/mcp
    tag: stable

replicaCounts:
  plextracapi: 3
  ckeditor: 3
  eventOrchestrator: 1
  notificationEngine: 1
  notificationSender: 1
  integrationWorker: 1
  contextualScoringService: 1
  datalakeMaintainer: 0   # Disabled by default; set to 1 to enable

# Optional in-cluster Synqly integration service (disabled by default).
# Runs internal-only; PlexTrac is wired to it automatically. See docs/user-guide.md.
# synqly:
#   enabled: true
#   database:
#     dedicated: false   # reuse bundled Postgres; true = chart deploys a dedicated one

# Optional in-cluster Keycloak OIDC/SSO broker (disabled by default). Browser-facing: needs its own
# hostname + TLS, and a custom backend image with the on-prem realm migration. See docs/user-guide.md.
# keycloak:
#   enabled: true
#   host: auth.mycompany.com          # REQUIRED — browser-facing auth hostname
#   certManager:
#     issuer: letsencrypt             # selfSigned | letsencrypt | letsencrypt-staging | "" (BYO / pre-created)
#     email: admin@mycompany.com
#   database:
#     dedicated: false                # reuse bundled Postgres; true = chart deploys a dedicated one

# Optional in-cluster MCP (Model Context Protocol) server (disabled by default).
# REQUIRES keycloak.enabled. Served at /mcp on the app host. See docs/user-guide.md.
# mcp:
#   enabled: true
#   otel:
#     enabled: false          # set true + exporterEndpoint for your OTLP collector

# Extra non-secret env vars injected into the env-config ConfigMap (see the chart's values.yaml).
# extraEnv:
#   SOME_FEATURE_FLAG: "true"
#   CUSTOM_TIMEOUT_MS: "30000"
```

Paste the registry credentials snippet from step 5 into this file.

## 7. Install PlexTrac

Install the PlexTrac Helm chart:

```shell
helm upgrade --install plextrac ./charts/plextrac \
  --namespace plextrac \
  --create-namespace \
  -f my-values.yaml \
  --wait --timeout 15m
```

Note:

First installation runs database migrations inline; allow time for completion. Depending on the hardware, the install may seem like it times out, but watching the pods come online with `kubectl -n plextrac get pods -w` will allow you to see when complete. 

## 8. Verify Installation

Check the API health endpoint:

```shell
curl -I https://[your_plextrac_domain]/api/v2/health/full
```

Note:

If migrating from a Docker Compose environment, you can proceed to do that from here, there is no need to complete Step 9 or 10 as the credentials will come from your backup.

## 9. Retrieve Global Admin Credentials

Get the global admin token from logs:

```shell
kubectl logs deployment/plextracapi -n plextrac | grep 'password'
```

If the above does not work (link in the log has expired or the token itself has expired), please contact support for assistance in setting the password directly.

---

**Key Points:**

- Traefik is disabled; NGINX Ingress Controller is used instead
- Kubeconfig is readable without sudo (`--write-kubeconfig-mode 644`)
- First Helm installation requires extra time for database migrations (`--timeout 15m`)
- All registry credentials must be set before installation
