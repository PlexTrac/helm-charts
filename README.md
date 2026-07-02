# PlexTrac Helm Charts

Helm chart for deploying the PlexTrac platform on Kubernetes. Supports self-hosted and on-premises deployments.

## Before you install

A successful install requires three things to be in place **before** running `helm upgrade --install`:

1. **A running Kubernetes cluster** with NGINX Ingress Controller installed
2. **A DNS record** pointing your hostname to the ingress LoadBalancer IP
3. **Your credentials gathered** — at minimum a domain name

See [docs/user-guide.md](docs/user-guide.md) for the full phased installation guide.

## Quick start (K3s)

> Prerequisites on the host you run this from: **Helm 3.10+** and **`jq`** (required by the registry script in step 4 — `apt install jq` / `dnf install jq` / `brew install jq`). `kubectl` is bundled with K3s.

```bash
# 1. Install K3s (disable Traefik — PlexTrac uses NGINX; write a non-root-readable kubeconfig)
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 644" sh -
# kubeconfig is now readable without sudo — point kubectl/helm at it directly:
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> ~/.bashrc

# 2. Install NGINX Ingress Controller
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx && helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace --wait

# 3. Get the ingress IP and create your DNS record (or /etc/hosts entry)
kubectl -n ingress-nginx get svc ingress-nginx-controller

# 4. Fill in credentials and create registry pull secrets
cp .env.example .env.local
# Edit .env.local — set DOCKER_REGISTRY, DOCKER_USERNAME, DOCKER_PASSWORD at minimum
./scripts/setup-registry-credentials.sh   # creates k8s secret + prints my-values.yaml snippet

# 5. Configure your values file
cp charts/plextrac/examples/values-self-hosted.yaml my-values.yaml
# Edit my-values.yaml — paste the snippet from step 4, set global.ingress.host

# 6. Install (namespace was created by setup-registry-credentials.sh in step 4)
helm upgrade --install plextrac ./charts/plextrac \
  --namespace plextrac \
  -f my-values.yaml \
  --wait --timeout 15m   # first install runs DB migrations inline; allow time

# 7. Verify
curl -I https://plextrac.mycompany.com/api/v2/health/full
```

> **If `--wait` does not complete:** the `migrations-and-etl` Job migrates the database on first install, and `plextracapi` will not become Ready until it finishes. Check `kubectl -n plextrac logs job/migrations-and-etl-<revision>` and `kubectl -n plextrac get pods` — a failing migration or an unpullable image (wrong registry/pull-secret name) is the usual cause. See [Troubleshooting](docs/user-guide.md#troubleshooting).

## Uninstalling

```bash
helm uninstall plextrac --namespace plextrac
# PVCs are not deleted automatically — remove manually if you want full cleanup:
kubectl -n plextrac delete pvc --all
```

## Repository layout

| Path | Purpose |
|---|---|
| `charts/plextrac/` | The PlexTrac Helm chart |
| `charts/plextrac/values.yaml` | Default values |
| `charts/plextrac/examples/` | Ready-to-use configuration examples |
| `.env.example` | Registry credentials — copy to `.env.local`, fill in, then run `scripts/setup-registry-credentials.sh` |
| `scripts/` | Helper scripts — registry credential setup and other pre-install tasks |
| `docs/user-guide.md` | Full phased installation and configuration guide |
| `docs/runbooks/secrets-modes.md` | Detailed secrets configuration reference |
| `docs/migration/` | Kustomize → Helm migration guides |
| `.github/workflows/` | CI and release automation |

## Examples at a glance

| File | Use case |
|---|---|
| `examples/values-self-hosted.yaml` | Manual secrets — recommended default |
| `examples/values-external-secrets.yaml` | External Secrets Operator |
| `examples/values-csi-aws.yaml` | CSI driver with AWS Secrets Manager |
| `examples/values-csi-gcp.yaml` | CSI driver with GCP Secret Manager |
| `examples/values-override-template.yaml` | Blank template — copy and uncomment what you need |

> All files under `charts/plextrac/examples/` are **overlays**: apply them with `-f` on top of the chart (which loads its own `values.yaml` first), and they override only the keys they contain. Layer multiple `-f` files if needed — later files win. Don't rely on an example as your only configuration if it omits keys the chart requires.

## Versioning

`Chart.yaml` `version` follows SemVer. `appVersion` tracks the PlexTrac application release.

## CI and release

- PR/main validation: `.github/workflows/chart-ci.yml`
- Release pipeline: `.github/workflows/chart-release.yml`
- Releases publish to OCI (`ghcr.io/<org>/charts/plextrac`) and GitHub Pages (`gh-pages` branch)
